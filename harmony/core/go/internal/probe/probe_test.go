package probe

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	configpkg "github.com/clashmetaforandroid/harmony/core/go/internal/config"
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
)

const (
	testProbeTimeout = 10 * time.Second
)

type originProcess struct {
	cmd      *exec.Cmd
	info     originInfo
	stderr   strings.Builder
	bodyHash string
}

type originInfo struct {
	OriginID   string `json:"originId"`
	OriginURL  string `json:"originUrl"`
	Address    string `json:"address"`
	CAPEM      string `json:"caPem"`
	BodySHA256 string `json:"bodySha256"`
}

func TestHTTPSProbeThroughHTTPConnectAndSOCKS5(t *testing.T) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), testProbeTimeout)
	defer cancel()

	origin := startOriginProcess(t)
	defer origin.stop(t)

	httpProxy := startHTTPConnectProxy(t)
	defer httpProxy.Close()

	socksProxy := startSOCKS5Proxy(t)
	defer socksProxy.Close()

	for _, testCase := range []struct {
		name     string
		protocol Protocol
		listener string
	}{
		{
			name:     "http_connect",
			protocol: ProtocolHTTPConnect,
			listener: httpProxy.Addr().String(),
		},
		{
			name:     "socks5",
			protocol: ProtocolSOCKS5,
			listener: socksProxy.Addr().String(),
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			runID := fmt.Sprintf("task11-%s", testCase.name)
			result, err := HTTPS(ctx, HTTPSRequest{
				ProbeRunID:         runID,
				Protocol:           testCase.protocol,
				ListenerAddress:    testCase.listener,
				OriginURL:          origin.info.OriginURL,
				CAPEM:              []byte(origin.info.CAPEM),
				ExpectedBodySHA256: origin.bodyHash,
				AwaitTracker: func(context.Context, FlowObservation) (TrackerRecord, error) {
					return TrackerRecord{}, nil
				},
			})
			if err != nil {
				t.Fatalf("HTTPS(...) returned error: %v", err)
			}

			if result.ProbeRunID != runID {
				t.Fatalf("ProbeRunID = %q, want %q", result.ProbeRunID, runID)
			}
			if result.Protocol != testCase.protocol {
				t.Fatalf("Protocol = %q, want %q", result.Protocol, testCase.protocol)
			}
			if result.RequestIDEcho != runID {
				t.Fatalf("RequestIDEcho = %q, want %q", result.RequestIDEcho, runID)
			}
			if result.OriginID != origin.info.OriginID {
				t.Fatalf("OriginID = %q, want %q", result.OriginID, origin.info.OriginID)
			}
			if result.HTTPStatus != 200 {
				t.Fatalf("HTTPStatus = %d, want 200", result.HTTPStatus)
			}
			if result.ResponseSHA256 != origin.bodyHash {
				t.Fatalf("ResponseSHA256 = %q, want %q", result.ResponseSHA256, origin.bodyHash)
			}
			if result.TLSPeerSHA256 == "" {
				t.Fatal("TLSPeerSHA256 must not be empty")
			}
			if result.BodyBytes == 0 {
				t.Fatal("BodyBytes must be non-zero")
			}
			if result.StartedAt.IsZero() || result.CompletedAt.IsZero() {
				t.Fatal("StartedAt and CompletedAt must be populated")
			}
			if result.CompletedAt.Before(result.StartedAt) {
				t.Fatalf("CompletedAt %s before StartedAt %s", result.CompletedAt, result.StartedAt)
			}
			if result.ClientLocalAddress == "" || result.ClientRemoteAddress == "" {
				t.Fatal("Client socket endpoints must be populated")
			}
		})
	}
}

func TestHTTPSProbeReturnsStructuredErrors(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), testProbeTimeout)
	defer cancel()

	origin := startOriginProcess(t)
	defer origin.stop(t)

	httpProxy := startHTTPConnectProxy(t)
	defer httpProxy.Close()

	_, err := HTTPS(ctx, HTTPSRequest{
		ProbeRunID:         "task11-hash-mismatch",
		Protocol:           ProtocolHTTPConnect,
		ListenerAddress:    httpProxy.Addr().String(),
		OriginURL:          origin.info.OriginURL,
		CAPEM:              []byte(origin.info.CAPEM),
		ExpectedBodySHA256: strings.Repeat("0", 64),
		AwaitTracker: func(context.Context, FlowObservation) (TrackerRecord, error) {
			return TrackerRecord{}, nil
		},
	})

	var probeErr *Error
	if !errors.As(err, &probeErr) {
		t.Fatalf("HTTPS(...) error = %T, want *Error", err)
	}
	if probeErr.Code != "RESPONSE_HASH_MISMATCH" {
		t.Fatalf("probe error code = %q, want RESPONSE_HASH_MISMATCH", probeErr.Code)
	}
	if probeErr.Stage == "" {
		t.Fatal("probe error stage must be populated")
	}
	if probeErr.Detail == "" {
		t.Fatal("probe error detail must be populated")
	}
}

func TestHTTPSProbeTimesOutWhenProxyDoesNotReply(t *testing.T) {
	listener := startBlackholeListener(t)
	defer listener.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	done := make(chan error, 1)
	go func() {
		_, err := HTTPS(ctx, HTTPSRequest{
			ProbeRunID:         "task11-blackhole-proxy",
			Protocol:           ProtocolHTTPConnect,
			ListenerAddress:    listener.Addr().String(),
			OriginURL:          "https://127.0.0.1:9443/",
			CAPEM:              []byte(testCAPEM),
			ExpectedBodySHA256: strings.Repeat("a", 64),
			Timeout:            150 * time.Millisecond,
		})
		done <- err
	}()

	select {
	case err := <-done:
		var probeErr *Error
		if !errors.As(err, &probeErr) {
			t.Fatalf("HTTPS(...) error = %T, want *Error", err)
		}
		if probeErr.Code != "PROBE_TIMEOUT" {
			t.Fatalf("probe error code = %q, want PROBE_TIMEOUT", probeErr.Code)
		}
		if probeErr.Stage != "dial" {
			t.Fatalf("probe error stage = %q, want dial", probeErr.Stage)
		}
	case <-time.After(750 * time.Millisecond):
		t.Fatal("HTTPS(...) did not return within the bounded timeout")
	}
}

func TestHTTPSProbeMapsTrackerContextCancellationToStructuredError(t *testing.T) {
	origin := startOriginProcess(t)
	defer origin.stop(t)

	httpProxy := startHTTPConnectProxy(t)
	defer httpProxy.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	_, err := HTTPS(ctx, HTTPSRequest{
		ProbeRunID:         "task11-tracker-timeout",
		Protocol:           ProtocolHTTPConnect,
		ListenerAddress:    httpProxy.Addr().String(),
		OriginURL:          origin.info.OriginURL,
		CAPEM:              []byte(origin.info.CAPEM),
		ExpectedBodySHA256: origin.bodyHash,
		Timeout:            150 * time.Millisecond,
		AwaitTracker: func(ctx context.Context, _ FlowObservation) (TrackerRecord, error) {
			<-ctx.Done()
			return TrackerRecord{}, ctx.Err()
		},
	})

	var probeErr *Error
	if !errors.As(err, &probeErr) {
		t.Fatalf("HTTPS(...) error = %T, want *Error", err)
	}
	if probeErr.Code != "TRACKER_TIMEOUT" {
		t.Fatalf("probe error code = %q, want TRACKER_TIMEOUT", probeErr.Code)
	}
	if probeErr.Stage != "tracker" {
		t.Fatalf("probe error stage = %q, want tracker", probeErr.Stage)
	}
}

func TestHTTPSProbeRunningCancelInterruptsTrackerWait(t *testing.T) {
	origin := startOriginProcess(t)
	defer origin.stop(t)

	httpProxy := startHTTPConnectProxy(t)
	defer httpProxy.Close()

	started := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, err := HTTPS(context.Background(), HTTPSRequest{
			ProbeRunID:         "task11-running-cancel",
			Protocol:           ProtocolHTTPConnect,
			ListenerAddress:    httpProxy.Addr().String(),
			OriginURL:          origin.info.OriginURL,
			CAPEM:              []byte(origin.info.CAPEM),
			ExpectedBodySHA256: origin.bodyHash,
			Timeout:            2 * time.Second,
			AwaitTracker: func(ctx context.Context, _ FlowObservation) (TrackerRecord, error) {
				close(started)
				<-ctx.Done()
				return TrackerRecord{}, ctx.Err()
			},
		})
		done <- err
	}()

	select {
	case <-started:
	case <-time.After(750 * time.Millisecond):
		t.Fatal("probe never reached tracker wait before cancellation")
	}

	if status := CancelProbeRun("task11-running-cancel"); status == CancelRunInvalid {
		t.Fatal("CancelProbeRun should accept a live probe run id")
	}

	select {
	case err := <-done:
		var probeErr *Error
		if !errors.As(err, &probeErr) {
			t.Fatalf("HTTPS(...) error = %T, want *Error", err)
		}
		if probeErr.Code != "PROBE_CANCELLED" {
			t.Fatalf("probe error code = %q, want PROBE_CANCELLED", probeErr.Code)
		}
		if probeErr.Stage != "tracker" {
			t.Fatalf("probe error stage = %q, want tracker", probeErr.Stage)
		}
	case <-time.After(750 * time.Millisecond):
		t.Fatal("running probe cancellation did not unblock tracker wait")
	}
}

func TestHTTPSProbeStartBeforeCancelReturnsStructuredError(t *testing.T) {
	listener := startBlackholeListener(t)
	defer listener.Close()

	if status := CancelProbeRun("task11-pre-cancel"); status == CancelRunInvalid {
		t.Fatal("CancelProbeRun should accept a non-empty pending probeRunID")
	}

	_, err := HTTPS(context.Background(), HTTPSRequest{
		ProbeRunID:         "task11-pre-cancel",
		Protocol:           ProtocolHTTPConnect,
		ListenerAddress:    listener.Addr().String(),
		OriginURL:          "https://127.0.0.1:9443/",
		CAPEM:              []byte(testCAPEM),
		ExpectedBodySHA256: strings.Repeat("a", 64),
		Timeout:            2 * time.Second,
	})

	var probeErr *Error
	if !errors.As(err, &probeErr) {
		t.Fatalf("HTTPS(...) error = %T, want *Error", err)
	}
	if probeErr.Code != "PROBE_CANCELLED" {
		t.Fatalf("probe error code = %q, want PROBE_CANCELLED", probeErr.Code)
	}
	if probeErr.Stage != "dial" {
		t.Fatalf("probe error stage = %q, want dial", probeErr.Stage)
	}
}

func TestHTTPSProbeRejectsDuplicateRunID(t *testing.T) {
	origin := startOriginProcess(t)
	defer origin.stop(t)

	httpProxy := startHTTPConnectProxy(t)
	defer httpProxy.Close()

	started := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, err := HTTPS(context.Background(), HTTPSRequest{
			ProbeRunID:         "task11-duplicate",
			Protocol:           ProtocolHTTPConnect,
			ListenerAddress:    httpProxy.Addr().String(),
			OriginURL:          origin.info.OriginURL,
			CAPEM:              []byte(origin.info.CAPEM),
			ExpectedBodySHA256: origin.bodyHash,
			Timeout:            2 * time.Second,
			AwaitTracker: func(ctx context.Context, _ FlowObservation) (TrackerRecord, error) {
				close(started)
				<-ctx.Done()
				return TrackerRecord{}, ctx.Err()
			},
		})
		done <- err
	}()

	select {
	case <-started:
	case <-time.After(750 * time.Millisecond):
		t.Fatal("first probe never reached tracker wait")
	}

	_, err := HTTPS(context.Background(), HTTPSRequest{
		ProbeRunID:         "task11-duplicate",
		Protocol:           ProtocolHTTPConnect,
		ListenerAddress:    httpProxy.Addr().String(),
		OriginURL:          origin.info.OriginURL,
		CAPEM:              []byte(origin.info.CAPEM),
		ExpectedBodySHA256: origin.bodyHash,
		Timeout:            2 * time.Second,
		AwaitTracker: func(context.Context, FlowObservation) (TrackerRecord, error) {
			return TrackerRecord{}, nil
		},
	})

	var probeErr *Error
	if !errors.As(err, &probeErr) {
		t.Fatalf("duplicate HTTPS(...) error = %T, want *Error", err)
	}
	if probeErr.Code != "PROBE_RUN_ID_IN_USE" {
		t.Fatalf("duplicate probe error code = %q, want PROBE_RUN_ID_IN_USE", probeErr.Code)
	}
	if probeErr.Stage != "request" {
		t.Fatalf("duplicate probe error stage = %q, want request", probeErr.Stage)
	}

	_ = CancelProbeRun("task11-duplicate")
	select {
	case <-done:
	case <-time.After(750 * time.Millisecond):
		t.Fatal("cleanup cancel did not release the first duplicate probe")
	}
}

func TestHTTPSProbeThroughRealMihomoListenersIncludesTracker(t *testing.T) {
	origin := startOriginProcess(t)
	defer origin.stop(t)

	proxy := startLocalProxy(t)
	defer stopLocalProxy(t, proxy)

	for _, testCase := range []struct {
		name                string
		protocol            Protocol
		listenerAddress     string
		expectedInboundType string
	}{
		{
			name:                "http_connect",
			protocol:            ProtocolHTTPConnect,
			listenerAddress:     proxy.Snapshot().HTTPAddress,
			expectedInboundType: "HTTPS",
		},
		{
			name:                "socks5",
			protocol:            ProtocolSOCKS5,
			listenerAddress:     proxy.Snapshot().SOCKSAddress,
			expectedInboundType: "Socks5",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()

			result, err := HTTPS(ctx, HTTPSRequest{
				ProbeRunID:         fmt.Sprintf("mihomo-%s", testCase.name),
				Protocol:           testCase.protocol,
				ListenerAddress:    testCase.listenerAddress,
				OriginURL:          origin.info.OriginURL,
				CAPEM:              []byte(origin.info.CAPEM),
				ExpectedBodySHA256: origin.bodyHash,
			})
			if err != nil {
				t.Fatalf("HTTPS(...) through mihomo returned error: %v", err)
			}
			if result.Tracker.ConnectionID == "" {
				t.Fatal("Tracker.ConnectionID must be populated")
			}
			if result.Tracker.SourceAddress == "" {
				t.Fatal("Tracker.SourceAddress must be populated")
			}
			if result.Tracker.DestinationAddress != origin.info.Address {
				t.Fatalf("Tracker.DestinationAddress = %q, want %q", result.Tracker.DestinationAddress, origin.info.Address)
			}
			if result.Tracker.InboundType != testCase.expectedInboundType {
				t.Fatalf("Tracker.InboundType = %q, want %q", result.Tracker.InboundType, testCase.expectedInboundType)
			}
			if result.Tracker.OpenedAt.IsZero() {
				t.Fatal("Tracker.OpenedAt must be populated")
			}
		})
	}
}

func startOriginProcess(t *testing.T) *originProcess {
	t.Helper()

	repoRoot := repoRootFromTestFile(t)
	bodyBytes, err := os.ReadFile(filepath.Join(repoRoot, "harmony", "tests", "fixtures", "origin-body.txt"))
	if err != nil {
		t.Fatalf("read origin body fixture: %v", err)
	}

	scriptPath := filepath.Join(repoRoot, "harmony", "tests", "bin", "phase2-origin.mjs")
	bodyPath := filepath.Join(repoRoot, "harmony", "tests", "fixtures", "origin-body.txt")
	cmd := exec.Command("node", scriptPath, "--bind", "127.0.0.1:0", "--body-file", bodyPath)
	cmd.Dir = repoRoot
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start origin process: %v", err)
	}

	reader := bufio.NewReader(stdout)
	line, err := reader.ReadString('\n')
	if err != nil {
		_ = cmd.Process.Kill()
		t.Fatalf("read origin process handshake line: %v", err)
	}

	var info originInfo
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &info); err != nil {
		_ = cmd.Process.Kill()
		t.Fatalf("decode origin process handshake: %v\nline=%s", err, line)
	}

	sum := sha256.Sum256(bodyBytes)
	return &originProcess{
		cmd:      cmd,
		info:     info,
		stderr:   stderr,
		bodyHash: hex.EncodeToString(sum[:]),
	}
}

func startLocalProxy(t *testing.T) *runtimepkg.LocalProxy {
	t.Helper()

	repoRoot := repoRootFromTestFile(t)
	configPath := filepath.Join(repoRoot, "harmony", "tests", "fixtures", "phase2-match-direct.yaml")
	proxy := runtimepkg.NewLocalProxyWithDeps(runtimepkg.LocalProxyDeps{
		Prepare: func(path string) error {
			sandboxRoot := filepath.Dir(path)
			candidate := filepath.Base(path)
			return configpkg.NewLoader(sandboxRoot).Load(candidate)
		},
	})
	snapshot, err := proxy.Start(runtimepkg.StartOptions{
		ConfigPath:         configPath,
		HTTPListenAddress:  "127.0.0.1:0",
		SOCKSListenAddress: "127.0.0.1:0",
	})
	if err != nil {
		t.Fatalf("start local proxy: %v (snapshot=%+v)", err, snapshot)
	}
	if snapshot.HTTPAddress == "" || snapshot.SOCKSAddress == "" {
		t.Fatalf("proxy snapshot missing listener addresses: %+v", snapshot)
	}
	return proxy
}

func stopLocalProxy(t *testing.T, proxy *runtimepkg.LocalProxy) {
	t.Helper()
	if proxy == nil {
		return
	}
	if _, err := proxy.Stop(); err != nil {
		t.Fatalf("stop local proxy: %v", err)
	}
}

func (origin *originProcess) stop(t *testing.T) {
	t.Helper()
	if origin == nil || origin.cmd == nil || origin.cmd.Process == nil {
		return
	}
	_ = origin.cmd.Process.Kill()
	_ = origin.cmd.Wait()
}

func startHTTPConnectProxy(t *testing.T) net.Listener {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen HTTP CONNECT proxy: %v", err)
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go handleHTTPConnectProxyConn(conn)
		}
	}()
	return listener
}

func startSOCKS5Proxy(t *testing.T) net.Listener {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen SOCKS5 proxy: %v", err)
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go handleSOCKS5ProxyConn(conn)
		}
	}()
	return listener
}

const testCAPEM = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIUeXx4fQjD2H6wY2R1Qx3BIfA+1wkwCgYIKoZIzj0EAwIw\nEjEQMA4GA1UEAwwHY21mYS10ZXN0MB4XDTI2MDgwNjA2MDAwMFoXDTM2MDgwMzA2\nMDAwMFowEjEQMA4GA1UEAwwHY21mYS10ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0D\nAQcDQgAEdZ0YAK8xjM1S+4oeYhTjU4G9f8O7Pp3yG7v3TQh9M0Aq3Qx6xjHq4RSt\nGepE8bJ1xLQ7fFx7nDk2Tq6d6d3E2aNTMFEwHQYDVR0OBBYEFM8tWvTWh6r4r6Vf\nwAqCv1L0M3gXMB8GA1UdIwQYMBaAFM8tWvTWh6r4r6VfwAqCv1L0M3gXMA8GA1Ud\nEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIhAKu+rdUQ1Ew1D9+GZGm4l4mQ\nu3Y9cBLlH+F6Vw+Z0y4EAiEAu6W5i2NlXIBlz2N2V0s0+2B3Jm3P5gXwhXl6aWcS\nBHI=\n-----END CERTIFICATE-----\n"

func startBlackholeListener(t *testing.T) net.Listener {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen blackhole proxy: %v", err)
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(client net.Conn) {
				defer client.Close()
				select {}
			}(conn)
		}
	}()
	return listener
}

func handleHTTPConnectProxyConn(client net.Conn) {
	defer client.Close()

	reader := bufio.NewReader(client)
	requestLine, err := reader.ReadString('\n')
	if err != nil {
		return
	}
	fields := strings.Fields(strings.TrimSpace(requestLine))
	if len(fields) < 3 || fields[0] != "CONNECT" {
		_, _ = io.WriteString(client, "HTTP/1.1 400 Bad Request\r\n\r\n")
		return
	}
	target := fields[1]
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		if line == "\r\n" {
			break
		}
	}

	upstream, err := net.Dial("tcp", target)
	if err != nil {
		_, _ = io.WriteString(client, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
		return
	}
	defer upstream.Close()
	_, _ = io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
	proxyStream(reader, client, upstream)
}

func handleSOCKS5ProxyConn(client net.Conn) {
	defer client.Close()

	header := make([]byte, 2)
	if _, err := io.ReadFull(client, header); err != nil {
		return
	}
	if header[0] != 0x05 {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(client, methods); err != nil {
		return
	}
	_, _ = client.Write([]byte{0x05, 0x00})

	requestHeader := make([]byte, 4)
	if _, err := io.ReadFull(client, requestHeader); err != nil {
		return
	}
	if requestHeader[0] != 0x05 || requestHeader[1] != 0x01 {
		return
	}

	targetHost, targetPort, err := readSOCKS5Target(client, requestHeader[3])
	if err != nil {
		return
	}
	upstream, err := net.Dial("tcp", net.JoinHostPort(targetHost, targetPort))
	if err != nil {
		_, _ = client.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer upstream.Close()

	bindAddr := upstream.LocalAddr().(*net.TCPAddr)
	replyAddr := bindAddr.IP.To4()
	if replyAddr == nil {
		replyAddr = net.IPv4zero
	}
	_, _ = client.Write([]byte{
		0x05, 0x00, 0x00, 0x01,
		replyAddr[0], replyAddr[1], replyAddr[2], replyAddr[3],
		byte(bindAddr.Port >> 8), byte(bindAddr.Port),
	})
	proxyStream(bufio.NewReader(client), client, upstream)
}

func readSOCKS5Target(client net.Conn, atyp byte) (string, string, error) {
	switch atyp {
	case 0x01:
		addr := make([]byte, 4)
		if _, err := io.ReadFull(client, addr); err != nil {
			return "", "", err
		}
		port := make([]byte, 2)
		if _, err := io.ReadFull(client, port); err != nil {
			return "", "", err
		}
		return net.IP(addr).String(), fmt.Sprintf("%d", int(port[0])<<8|int(port[1])), nil
	case 0x03:
		length := make([]byte, 1)
		if _, err := io.ReadFull(client, length); err != nil {
			return "", "", err
		}
		host := make([]byte, int(length[0]))
		if _, err := io.ReadFull(client, host); err != nil {
			return "", "", err
		}
		port := make([]byte, 2)
		if _, err := io.ReadFull(client, port); err != nil {
			return "", "", err
		}
		return string(host), fmt.Sprintf("%d", int(port[0])<<8|int(port[1])), nil
	default:
		return "", "", fmt.Errorf("unsupported ATYP %d", atyp)
	}
}

func proxyStream(buffered *bufio.Reader, client net.Conn, upstream net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, buffered)
		if tcpConn, ok := upstream.(*net.TCPConn); ok {
			_ = tcpConn.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, upstream)
		if tcpConn, ok := client.(*net.TCPConn); ok {
			_ = tcpConn.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	<-done
}

func repoRootFromTestFile(t *testing.T) string {
	t.Helper()
	_, filePath, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(filePath), "..", "..", "..", "..", ".."))
}
