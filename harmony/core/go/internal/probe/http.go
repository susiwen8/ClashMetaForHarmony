package probe

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const maxResponseBodyBytes int64 = 1 << 20
const holdOpenHeader = "X-CMFA-Hold-Open"
const holdOpenValue = "tracker"

type Protocol string

const (
	ProtocolHTTPConnect Protocol = "HTTP_CONNECT"
	ProtocolSOCKS5      Protocol = "SOCKS5"
)

type HTTPSRequest struct {
	ProbeRunID         string
	Protocol           Protocol
	ListenerAddress    string
	OriginURL          string
	CAPEM              []byte
	ExpectedBodySHA256 string
	Timeout            time.Duration
	AwaitTracker       func(context.Context, FlowObservation) (TrackerRecord, error)
}

type HTTPSResult struct {
	ProbeRunID          string
	Protocol            Protocol
	OriginID            string
	RequestIDEcho       string
	HTTPStatus          int
	ResponseSHA256      string
	TLSPeerSHA256       string
	BodyBytes           int64
	StartedAt           time.Time
	CompletedAt         time.Time
	ClientLocalAddress  string
	ClientRemoteAddress string
	Tracker             TrackerRecord
}

type Error struct {
	Code   string
	Stage  string
	Detail string
}

func (e *Error) Error() string {
	if e == nil {
		return ""
	}
	return fmt.Sprintf("%s (%s): %s", e.Code, e.Stage, e.Detail)
}

type FlowObservation struct {
	ProbeRunID          string
	Protocol            Protocol
	TargetAddress       string
	ClientLocalAddress  string
	ClientRemoteAddress string
	OriginURL           string
}

type TrackerRecord struct {
	ConnectionID       string
	SourceAddress      string
	DestinationAddress string
	InboundType        string
	OpenedAt           time.Time
}

var (
	probeURLUserInfoPattern = regexp.MustCompile(`://[^/@\s]+@`)
	probeSecretQueryPattern = regexp.MustCompile(`(?i)(token|password|secret)=([^&\s]+)`)
)

func HTTPS(ctx context.Context, request HTTPSRequest) (result HTTPSResult, err error) {
	startedAt := time.Now().UTC()
	result = HTTPSResult{
		ProbeRunID: request.ProbeRunID,
		Protocol:   request.Protocol,
		StartedAt:  startedAt,
	}
	defer func() {
		if result.CompletedAt.IsZero() {
			result.CompletedAt = time.Now().UTC()
		}
	}()

	if strings.TrimSpace(request.ProbeRunID) == "" {
		return result, &Error{Code: "INVALID_ARGUMENT", Stage: "request", Detail: "probeRunID must not be empty"}
	}
	if strings.TrimSpace(request.ListenerAddress) == "" {
		return result, &Error{Code: "INVALID_ARGUMENT", Stage: "request", Detail: "listenerAddress must not be empty"}
	}
	if strings.TrimSpace(request.OriginURL) == "" {
		return result, &Error{Code: "INVALID_ARGUMENT", Stage: "request", Detail: "originURL must not be empty"}
	}
	if len(request.CAPEM) == 0 {
		return result, &Error{Code: "INVALID_ARGUMENT", Stage: "request", Detail: "caPem must not be empty"}
	}

	ctx, releaseProbeRun, err := manageProbeRun(ctx, request.ProbeRunID, request.Timeout)
	if err != nil {
		return result, err
	}
	defer releaseProbeRun()

	originURL, err := url.Parse(request.OriginURL)
	if err != nil {
		return result, &Error{Code: "INVALID_ORIGIN_URL", Stage: "request", Detail: sanitizeProbeDetail(err.Error())}
	}
	if originURL.Scheme != "https" {
		return result, &Error{Code: "INVALID_ORIGIN_URL", Stage: "request", Detail: "originURL must use https"}
	}
	targetAddress := originURL.Host
	if !strings.Contains(targetAddress, ":") {
		targetAddress = net.JoinHostPort(originURL.Hostname(), "443")
	}

	proxyConn, buffered, err := dialTunnel(ctx, request.Protocol, request.ListenerAddress, targetAddress)
	if err != nil {
		return result, err
	}
	defer proxyConn.Close()

	result.ClientLocalAddress = proxyConn.LocalAddr().String()
	result.ClientRemoteAddress = proxyConn.RemoteAddr().String()

	rootCAs := x509.NewCertPool()
	if !rootCAs.AppendCertsFromPEM(request.CAPEM) {
		return result, &Error{Code: "CA_PEM_INVALID", Stage: "tls", Detail: "failed to append PEM certificate authority"}
	}

	tlsConn := tls.Client(proxyConn, &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    rootCAs,
		ServerName: originURL.Hostname(),
	})
	defer tlsConn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = tlsConn.SetDeadline(deadline)
	}
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		return result, &Error{Code: "TLS_HANDSHAKE_FAILED", Stage: "tls", Detail: err.Error()}
	}

	state := tlsConn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return result, &Error{Code: "TLS_PEER_CERT_MISSING", Stage: "tls", Detail: "peer certificate chain was empty"}
	}
	peerDigest := sha256.Sum256(state.PeerCertificates[0].Raw)
	result.TLSPeerSHA256 = hex.EncodeToString(peerDigest[:])

	requestPath := originURL.RequestURI()
	if requestPath == "" {
		requestPath = "/"
	}
	requestBodyReader, requestBodyWriter := io.Pipe()
	defer requestBodyWriter.Close()

	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, request.OriginURL, requestBodyReader)
	if err != nil {
		return result, &Error{Code: "REQUEST_BUILD_FAILED", Stage: "request", Detail: err.Error()}
	}
	httpRequest.Host = originURL.Host
	httpRequest.Header.Set("X-CMFA-Request-ID", request.ProbeRunID)
	httpRequest.Header.Set(holdOpenHeader, holdOpenValue)
	requestWriteDone := make(chan error, 1)
	go func() {
		requestWriteDone <- httpRequest.Write(tlsConn)
	}()

	responseReader := bufio.NewReader(tlsConn)
	if request.Protocol == ProtocolHTTPConnect && buffered != nil && buffered.Buffered() > 0 {
		responseReader = bufio.NewReader(io.MultiReader(buffered, tlsConn))
	}
	response, err := http.ReadResponse(responseReader, httpRequest)
	if err != nil {
		return result, newOperationError(ctx, "response", "RESPONSE_READ_FAILED", err)
	}
	defer response.Body.Close()

	awaitTracker := request.AwaitTracker
	if awaitTracker == nil {
		awaitTracker = AwaitRealTracker
	}
	trackerRecord, err := awaitTracker(ctx, FlowObservation{
		ProbeRunID:          request.ProbeRunID,
		Protocol:            request.Protocol,
		TargetAddress:       targetAddress,
		ClientLocalAddress:  result.ClientLocalAddress,
		ClientRemoteAddress: result.ClientRemoteAddress,
		OriginURL:           request.OriginURL,
	})
	if err != nil {
		_ = requestBodyWriter.CloseWithError(err)
		<-requestWriteDone
		return result, classifyProbeError(ctx, "tracker", err)
	}
	if err := requestBodyWriter.Close(); err != nil {
		return result, newOperationError(ctx, "request", "REQUEST_RELEASE_FAILED", err)
	}
	if err := <-requestWriteDone; err != nil {
		return result, newOperationError(ctx, "request", "REQUEST_WRITE_FAILED", err)
	}
	result.Tracker = trackerRecord
	result.RequestIDEcho = response.Header.Get("X-CMFA-Request-ID")
	result.OriginID = response.Header.Get("X-CMFA-Origin-ID")
	result.HTTPStatus = response.StatusCode

	bodyReader := io.LimitReader(response.Body, maxResponseBodyBytes+1)
	bodyHasher := sha256.New()
	bodyBytes, err := io.Copy(bodyHasher, bodyReader)
	if err != nil {
		return result, newOperationError(ctx, "response", "RESPONSE_BODY_READ_FAILED", err)
	}
	if bodyBytes > maxResponseBodyBytes {
		return result, &Error{Code: "RESPONSE_BODY_TOO_LARGE", Stage: "response", Detail: fmt.Sprintf("response exceeded %d bytes", maxResponseBodyBytes)}
	}

	result.BodyBytes = bodyBytes
	result.ResponseSHA256 = hex.EncodeToString(bodyHasher.Sum(nil))
	result.CompletedAt = time.Now().UTC()

	if response.StatusCode != http.StatusOK {
		return result, &Error{Code: "HTTP_STATUS_UNEXPECTED", Stage: "response", Detail: fmt.Sprintf("unexpected HTTP status %d", response.StatusCode)}
	}
	if result.RequestIDEcho != request.ProbeRunID {
		return result, &Error{Code: "REQUEST_ID_ECHO_MISMATCH", Stage: "response", Detail: fmt.Sprintf("expected echoed request ID %q, got %q", request.ProbeRunID, result.RequestIDEcho)}
	}
	if !strings.EqualFold(result.ResponseSHA256, request.ExpectedBodySHA256) {
		return result, &Error{Code: "RESPONSE_HASH_MISMATCH", Stage: "response", Detail: fmt.Sprintf("expected body SHA-256 %q, got %q", request.ExpectedBodySHA256, result.ResponseSHA256)}
	}

	return result, nil
}

func dialTunnel(ctx context.Context, protocol Protocol, listenerAddress string, targetAddress string) (net.Conn, *bufio.Reader, error) {
	dialer := &net.Dialer{}
	conn, err := dialer.DialContext(ctx, "tcp", listenerAddress)
	if err != nil {
		return nil, nil, newOperationError(ctx, "dial", "PROXY_DIAL_FAILED", err)
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}

	switch protocol {
	case ProtocolHTTPConnect:
		buffered, err := establishHTTPConnectTunnel(ctx, conn, targetAddress)
		if err != nil {
			_ = conn.Close()
			return nil, nil, err
		}
		return conn, buffered, nil
	case ProtocolSOCKS5:
		if err := establishSOCKS5Tunnel(ctx, conn, targetAddress); err != nil {
			_ = conn.Close()
			return nil, nil, err
		}
		return conn, nil, nil
	default:
		_ = conn.Close()
		return nil, nil, &Error{Code: "PROTOCOL_UNSUPPORTED", Stage: "dial", Detail: fmt.Sprintf("unsupported protocol %q", protocol)}
	}
}

func establishHTTPConnectTunnel(ctx context.Context, conn net.Conn, targetAddress string) (*bufio.Reader, error) {
	request, err := http.NewRequest(http.MethodConnect, "http://"+targetAddress, nil)
	if err != nil {
		return nil, &Error{Code: "CONNECT_REQUEST_INVALID", Stage: "dial", Detail: sanitizeProbeDetail(err.Error())}
	}
	request.Host = targetAddress
	if err := request.Write(conn); err != nil {
		return nil, newOperationError(ctx, "dial", "CONNECT_WRITE_FAILED", err)
	}

	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, request)
	if err != nil {
		return nil, newOperationError(ctx, "dial", "CONNECT_RESPONSE_INVALID", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, &Error{Code: "CONNECT_STATUS_UNEXPECTED", Stage: "dial", Detail: fmt.Sprintf("unexpected CONNECT status %d", response.StatusCode)}
	}
	return reader, nil
}

func sanitizeProbeDetail(detail string) string {
	redacted := probeURLUserInfoPattern.ReplaceAllString(detail, "://<redacted>@")
	redacted = probeSecretQueryPattern.ReplaceAllString(redacted, `$1=<redacted>`)
	return redacted
}

func classifyProbeError(ctx context.Context, stage string, err error) error {
	if err == nil {
		return nil
	}

	var probeErr *Error
	if errors.As(err, &probeErr) {
		probeErr.Detail = sanitizeProbeDetail(probeErr.Detail)
		if probeErr.Stage == "" {
			probeErr.Stage = stage
		}
		return probeErr
	}

	if ctxErr := contextErrorForStage(ctx, stage, err); ctxErr != nil {
		return ctxErr
	}
	return &Error{
		Code:   "BACKEND_ERROR",
		Stage:  stage,
		Detail: sanitizeProbeDetail(err.Error()),
	}
}

func newOperationError(ctx context.Context, stage string, code string, err error) error {
	if ctxErr := contextErrorForStage(ctx, stage, err); ctxErr != nil {
		return ctxErr
	}
	return &Error{
		Code:   code,
		Stage:  stage,
		Detail: sanitizeProbeDetail(err.Error()),
	}
}

func contextErrorForStage(ctx context.Context, stage string, err error) *Error {
	if err == nil {
		return nil
	}
	if errors.Is(context.Cause(ctx), errProbeCanceled) || errors.Is(err, context.Canceled) {
		return &Error{
			Code:   "PROBE_CANCELLED",
			Stage:  stage,
			Detail: fmt.Sprintf("probe canceled during %s", stage),
		}
	}
	if errors.Is(context.Cause(ctx), errProbeTimedOut) || errors.Is(err, context.DeadlineExceeded) {
		code := "PROBE_TIMEOUT"
		if stage == "tracker" {
			code = "TRACKER_TIMEOUT"
		}
		return &Error{
			Code:   code,
			Stage:  stage,
			Detail: fmt.Sprintf("probe exceeded the %s deadline", stage),
		}
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		code := "PROBE_TIMEOUT"
		if stage == "tracker" {
			code = "TRACKER_TIMEOUT"
		}
		return &Error{
			Code:   code,
			Stage:  stage,
			Detail: fmt.Sprintf("probe exceeded the %s deadline", stage),
		}
	}
	return nil
}
