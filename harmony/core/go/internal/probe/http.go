package probe

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const maxResponseBodyBytes int64 = 1 << 20

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
}

type HTTPSResult struct {
	ProbeRunID         string
	Protocol           Protocol
	OriginID           string
	RequestIDEcho      string
	HTTPStatus         int
	ResponseSHA256     string
	TLSPeerSHA256      string
	BodyBytes          int64
	StartedAt          time.Time
	CompletedAt        time.Time
	ClientLocalAddress string
	ClientRemoteAddress string
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

func HTTPS(ctx context.Context, request HTTPSRequest) (HTTPSResult, error) {
	startedAt := time.Now().UTC()
	result := HTTPSResult{
		ProbeRunID: request.ProbeRunID,
		Protocol:   request.Protocol,
		StartedAt:  startedAt,
	}

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

	originURL, err := url.Parse(request.OriginURL)
	if err != nil {
		return result, &Error{Code: "INVALID_ORIGIN_URL", Stage: "request", Detail: err.Error()}
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
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, request.OriginURL, nil)
	if err != nil {
		return result, &Error{Code: "REQUEST_BUILD_FAILED", Stage: "request", Detail: err.Error()}
	}
	httpRequest.Host = originURL.Host
	httpRequest.Header.Set("X-CMFA-Request-ID", request.ProbeRunID)
	if err := httpRequest.Write(tlsConn); err != nil {
		return result, &Error{Code: "REQUEST_WRITE_FAILED", Stage: "request", Detail: err.Error()}
	}

	responseReader := bufio.NewReader(tlsConn)
	if request.Protocol == ProtocolHTTPConnect && buffered != nil && buffered.Buffered() > 0 {
		responseReader = bufio.NewReader(io.MultiReader(buffered, tlsConn))
	}
	response, err := http.ReadResponse(responseReader, httpRequest)
	if err != nil {
		return result, &Error{Code: "RESPONSE_READ_FAILED", Stage: "response", Detail: err.Error()}
	}
	defer response.Body.Close()

	bodyReader := io.LimitReader(response.Body, maxResponseBodyBytes+1)
	bodyHasher := sha256.New()
	bodyBytes, err := io.Copy(bodyHasher, bodyReader)
	if err != nil {
		return result, &Error{Code: "RESPONSE_BODY_READ_FAILED", Stage: "response", Detail: err.Error()}
	}
	if bodyBytes > maxResponseBodyBytes {
		return result, &Error{Code: "RESPONSE_BODY_TOO_LARGE", Stage: "response", Detail: fmt.Sprintf("response exceeded %d bytes", maxResponseBodyBytes)}
	}

	result.RequestIDEcho = response.Header.Get("X-CMFA-Request-ID")
	result.OriginID = response.Header.Get("X-CMFA-Origin-ID")
	result.HTTPStatus = response.StatusCode
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
		return nil, nil, &Error{Code: "PROXY_DIAL_FAILED", Stage: "dial", Detail: err.Error()}
	}

	switch protocol {
	case ProtocolHTTPConnect:
		buffered, err := establishHTTPConnectTunnel(conn, targetAddress)
		if err != nil {
			_ = conn.Close()
			return nil, nil, err
		}
		return conn, buffered, nil
	case ProtocolSOCKS5:
		if err := establishSOCKS5Tunnel(conn, targetAddress); err != nil {
			_ = conn.Close()
			return nil, nil, err
		}
		return conn, nil, nil
	default:
		_ = conn.Close()
		return nil, nil, &Error{Code: "PROTOCOL_UNSUPPORTED", Stage: "dial", Detail: fmt.Sprintf("unsupported protocol %q", protocol)}
	}
}

func establishHTTPConnectTunnel(conn net.Conn, targetAddress string) (*bufio.Reader, error) {
	request, err := http.NewRequest(http.MethodConnect, "http://"+targetAddress, nil)
	if err != nil {
		return nil, &Error{Code: "CONNECT_REQUEST_INVALID", Stage: "dial", Detail: err.Error()}
	}
	request.Host = targetAddress
	if err := request.Write(conn); err != nil {
		return nil, &Error{Code: "CONNECT_WRITE_FAILED", Stage: "dial", Detail: err.Error()}
	}

	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, request)
	if err != nil {
		return nil, &Error{Code: "CONNECT_RESPONSE_INVALID", Stage: "dial", Detail: err.Error()}
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, &Error{Code: "CONNECT_STATUS_UNEXPECTED", Stage: "dial", Detail: fmt.Sprintf("unexpected CONNECT status %d", response.StatusCode)}
	}
	return reader, nil
}
