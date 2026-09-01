package runtime

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type traceTunnel struct {
	tcpCalls atomic.Int32
	udpCalls atomic.Int32
}

func (t *traceTunnel) HandleTCPConn(conn net.Conn, _ *C.Metadata) {
	t.tcpCalls.Add(1)
	_, _ = io.Copy(io.Discard, conn)
	_ = conn.Close()
}

func (t *traceTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) {
	t.udpCalls.Add(1)
	packet.Drop()
}

func (t *traceTunnel) NatTable() C.NatTable { return fakeNatTable{} }

func (t *traceTunnel) tcpCallCount() int {
	return int(t.tcpCalls.Load())
}

func (t *traceTunnel) udpCallCount() int {
	return int(t.udpCalls.Load())
}

type asyncTraceTunnel struct {
	done chan struct{}
}

func (t *asyncTraceTunnel) HandleTCPConn(conn net.Conn, _ *C.Metadata) {
	go func() {
		defer close(t.done)
		_, _ = io.Copy(io.Discard, conn)
		_ = conn.Close()
	}()
}

func (t *asyncTraceTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) {
	packet.Drop()
}

func (t *asyncTraceTunnel) NatTable() C.NatTable { return fakeNatTable{} }

type blockingReadTraceTunnel struct {
	read    chan struct{}
	release chan struct{}
}

func (t *blockingReadTraceTunnel) HandleTCPConn(conn net.Conn, _ *C.Metadata) {
	buffer := make([]byte, 512)
	_, _ = conn.Read(buffer)
	close(t.read)
	<-t.release
	_ = conn.Close()
}

func (t *blockingReadTraceTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) {
	packet.Drop()
}

func (t *blockingReadTraceTunnel) NatTable() C.NatTable { return fakeNatTable{} }

type tracePacket struct {
	payload []byte
	dropped bool
}

func (p *tracePacket) Data() []byte { return p.payload }
func (p *tracePacket) Drop()        { p.dropped = true }
func (p *tracePacket) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: net.IPv4(10, 0, 0, 2), Port: 5353}
}
func (p *tracePacket) WriteBack([]byte, net.Addr) (int, error) { return 0, nil }

type noReadTraceTunnel struct {
	tcpCalls int
}

func (t *noReadTraceTunnel) HandleTCPConn(conn net.Conn, _ *C.Metadata) {
	t.tcpCalls += 1
	_ = conn.Close()
}

func (t *noReadTraceTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) {
	packet.Drop()
}

func (t *noReadTraceTunnel) NatTable() C.NatTable { return fakeNatTable{} }

type orderingTraceTunnel struct {
	udpCalls       int
	delegateCalled *bool
}

func (t *orderingTraceTunnel) HandleTCPConn(conn net.Conn, _ *C.Metadata) {
	_ = conn.Close()
}

func (t *orderingTraceTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) {
	t.udpCalls += 1
	if t.delegateCalled != nil {
		*t.delegateCalled = true
	}
	packet.Drop()
}

func (t *orderingTraceTunnel) NatTable() C.NatTable { return fakeNatTable{} }

type stubTracker struct {
	id    string
	info  *statistic.TrackerInfo
	close bool
}

func (t *stubTracker) ID() string                    { return t.id }
func (t *stubTracker) Close() error                  { t.close = true; return nil }
func (t *stubTracker) Info() *statistic.TrackerInfo  { return t.info }
func (t *stubTracker) Chains() C.Chain               { return t.info.Chain }
func (t *stubTracker) ProviderChains() C.Chain       { return nil }
func (t *stubTracker) AppendToChains(C.ProxyAdapter) {}
func (t *stubTracker) RemoteDestination() string     { return "" }

func withTunTraceTrackerRangeForTest(t *testing.T, trackers ...statistic.Tracker) {
	t.Helper()
	previous := tunTraceTrackerRange
	tunTraceTrackerRange = func(yield func(statistic.Tracker) bool) {
		for _, tracker := range trackers {
			if !yield(tracker) {
				return
			}
		}
	}
	t.Cleanup(func() {
		tunTraceTrackerRange = previous
	})
}

func makeTracker(metadata *C.Metadata, chain []string) statistic.Tracker {
	cloned := *metadata
	return &stubTracker{
		id: "tracker-id-redacted",
		info: &statistic.TrackerInfo{
			Metadata: &cloned,
			Chain:    append(C.Chain(nil), chain...),
		},
	}
}

func makeInvalidUTF8ChainElement() string {
	return string([]byte{0xff, 0xfe, 0xfd})
}

func buildDNSQueryPayload(label string) []byte {
	header := []byte{
		0x12, 0x34,
		0x01, 0x00,
		0x00, 0x01,
		0x00, 0x00,
		0x00, 0x00,
		0x00, 0x00,
	}
	payload := append([]byte(nil), header...)
	for _, part := range strings.Split(label, ".") {
		payload = append(payload, byte(len(part)))
		payload = append(payload, []byte(part)...)
	}
	payload = append(payload, 0x00, 0x00, 0x01, 0x00, 0x01)
	return payload
}

type channelEventSink struct {
	events chan RuntimeEvent
}

func (s *channelEventSink) Publish(event RuntimeEvent) {
	s.events <- event
}

func waitForValue[T any](t *testing.T, ch <-chan T, label string) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", label)
		var zero T
		return zero
	}
}

func waitForSignal(t *testing.T, ch <-chan struct{}, label string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", label)
	}
}

func withTunTraceOutboundProofLookupForTest(t *testing.T, lookup func(*C.Metadata) tunOutboundProof) {
	t.Helper()
	previous := tunTraceOutboundProofLookup
	tunTraceOutboundProofLookup = lookup
	t.Cleanup(func() {
		tunTraceOutboundProofLookup = previous
	})
}

func withTunTraceResolverHooksForTest(
	t *testing.T,
	now func() time.Time,
	wait func(context.Context) bool,
	timeout time.Duration,
) {
	t.Helper()
	previousNow := tunTraceResolverNow
	previousWait := tunTraceResolverWait
	previousTimeout := tunTraceResolverTimeout
	tunTraceResolverNow = now
	tunTraceResolverWait = wait
	tunTraceResolverTimeout = timeout
	t.Cleanup(func() {
		tunTraceResolverNow = previousNow
		tunTraceResolverWait = previousWait
		tunTraceResolverTimeout = previousTimeout
	})
}

func withTunTraceResolverMaxConcurrentForTest(t *testing.T, limit int) {
	t.Helper()
	previous := tunTraceResolverMaxConcurrent
	tunTraceResolverMaxConcurrent = limit
	t.Cleanup(func() {
		tunTraceResolverMaxConcurrent = previous
	})
}

func withTunTraceResolverLifecycleHooksForTest(
	t *testing.T,
	onStart func(),
	onDone func(),
) {
	t.Helper()
	previousStart := tunTraceResolverOnStart
	previousDone := tunTraceResolverOnDone
	tunTraceResolverOnStart = onStart
	tunTraceResolverOnDone = onDone
	t.Cleanup(func() {
		tunTraceResolverOnStart = previousStart
		tunTraceResolverOnDone = previousDone
	})
}

type scriptedTraceConn struct {
	mu     sync.Mutex
	reads  [][]byte
	closed bool
}

func (c *scriptedTraceConn) Read(target []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.reads) == 0 {
		return 0, io.EOF
	}
	next := c.reads[0]
	c.reads = c.reads[1:]
	n := copy(target, next)
	return n, nil
}

func (c *scriptedTraceConn) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
func (c *scriptedTraceConn) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	return nil
}
func (c *scriptedTraceConn) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (c *scriptedTraceConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (c *scriptedTraceConn) SetDeadline(time.Time) error      { return nil }
func (c *scriptedTraceConn) SetReadDeadline(time.Time) error  { return nil }
func (c *scriptedTraceConn) SetWriteDeadline(time.Time) error { return nil }

type twoReadTraceTunnel struct {
	afterFirstRead  func()
	afterSecondRead func()
}

func (t *twoReadTraceTunnel) HandleTCPConn(conn net.Conn, _ *C.Metadata) {
	buffer := make([]byte, 256)
	if _, err := conn.Read(buffer); err == nil && t.afterFirstRead != nil {
		t.afterFirstRead()
	}
	if _, err := conn.Read(buffer); err == nil && t.afterSecondRead != nil {
		t.afterSecondRead()
	}
	_ = conn.Close()
}

func (t *twoReadTraceTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) {
	packet.Drop()
}

func (t *twoReadTraceTunnel) NatTable() C.NatTable { return fakeNatTable{} }

func TestIngressTraceWrapsTunBoundaryOnly(t *testing.T) {
	tcpMetadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("172.19.0.2"),
		SrcPort: 42424,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "controlled.invalid",
	}
	withTunTraceTrackerRangeForTest(t, makeTracker(tcpMetadata, []string{"member-wrap"}))
	delegate := &traceTunnel{}
	events := &recordingSink{}
	recorder := newTunTraceRecorder("session-1", events, 256)
	wrapped := recorder.Wrap(delegate)

	left, right := net.Pipe()
	go func() {
		_, _ = right.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-1\r\n\r\n"))
		_ = right.Close()
	}()

	wrapped.HandleTCPConn(left, tcpMetadata)

	packet := &tracePacket{payload: []byte("query cmfa-flow-udp")}
	wrapped.HandleUDPPacket(packet, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.UDP,
		SrcIP:   netip.MustParseAddr("172.19.0.2"),
		SrcPort: 53000,
		DstIP:   netip.MustParseAddr("8.8.8.8"),
		DstPort: 53,
	})

	if delegate.tcpCallCount() != 1 || delegate.udpCallCount() != 1 {
		t.Fatalf("delegate calls = tcp:%d udp:%d want 1/1", delegate.tcpCallCount(), delegate.udpCallCount())
	}
	traces := recorder.Traces(16)
	if len(traces) != 2 {
		t.Fatalf("trace count = %d want 2", len(traces))
	}
	for _, trace := range traces {
		if trace.Ingress != "tun" {
			t.Fatalf("ingress = %q want tun", trace.Ingress)
		}
		if len(trace.TraceID) != 64 {
			t.Fatalf("trace id = %q want 64 lowercase hex", trace.TraceID)
		}
		if len(trace.HashedTuple) != 64 {
			t.Fatalf("tuple hash = %q want 64 lowercase hex", trace.HashedTuple)
		}
		if trace.SourceAddress != "" || trace.DestinationAddress != "" {
			t.Fatalf("trace leaked addresses: %#v", trace)
		}
	}
	if traces[1].CorrelationHash == "" {
		t.Fatal("dns trace should carry a query hash")
	}
	if packet.dropped != true {
		t.Fatal("delegate should still own the UDP packet lifecycle")
	}
	gotEvents := events.Events()
	if len(gotEvents) == 0 || gotEvents[0].TraceID == "" {
		t.Fatalf("events = %#v want trace-linked runtime event", gotEvents)
	}
	if gotEvents[0].TraceID != traces[0].TraceID {
		t.Fatalf("event trace = %q want %q", gotEvents[0].TraceID, traces[0].TraceID)
	}
}

func TestIngressTraceRingDropsOldestAndNeverStoresPayload(t *testing.T) {
	recorder := newTunTraceRecorder("session-1", &recordingSink{}, 2)
	delegate := &traceTunnel{}
	wrapped := recorder.Wrap(delegate)

	for index, payload := range [][]byte{
		[]byte("cmfa-oldest"),
		[]byte("cmfa-middle"),
		[]byte("cmfa-newest"),
	} {
		wrapped.HandleUDPPacket(&tracePacket{payload: payload}, &C.Metadata{
			Type:    C.TUN,
			NetWork: C.UDP,
			SrcIP:   netip.MustParseAddr("172.19.0.2"),
			SrcPort: uint16(53000 + index),
			DstIP:   netip.MustParseAddr("8.8.8.8"),
			DstPort: 53,
		})
	}

	traces := recorder.Traces(16)
	if len(traces) != 2 {
		t.Fatalf("trace count = %d want 2", len(traces))
	}
	for _, trace := range traces {
		if bytes.Contains([]byte(trace.CorrelationHash), []byte("cmfa-")) {
			t.Fatalf("trace leaked marker text: %#v", trace)
		}
	}
	counters := recorder.Counters()
	if counters.RXPackets != 3 {
		t.Fatalf("rx packets = %d want 3", counters.RXPackets)
	}
	if counters.RXBytes == 0 {
		t.Fatal("rx bytes should be monotonic and non-zero")
	}
}

func TestIngressTupleHashUsesPortsAndNotHost(t *testing.T) {
	metadataA := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "controlled.invalid",
	}
	metadataB := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "another.invalid",
	}
	metadataC := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41001,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "controlled.invalid",
	}
	withTunTraceTrackerRangeForTest(
		t,
		makeTracker(metadataA, []string{"member-a"}),
		makeTracker(metadataC, []string{"member-c"}),
	)
	recorder := newTunTraceRecorder("session-1", &recordingSink{}, 8)
	delegate := &traceTunnel{}
	wrapped := recorder.Wrap(delegate)

	leftA, rightA := net.Pipe()
	go func() {
		_, _ = rightA.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-a\r\n\r\n"))
		_ = rightA.Close()
	}()
	wrapped.HandleTCPConn(leftA, metadataA)

	leftB, rightB := net.Pipe()
	go func() {
		_, _ = rightB.Write([]byte("GET / HTTP/1.1\r\nHost: another.invalid\r\nX-CMFA-Flow: cmfa-flow-b\r\n\r\n"))
		_ = rightB.Close()
	}()
	wrapped.HandleTCPConn(leftB, metadataB)

	leftC, rightC := net.Pipe()
	go func() {
		_, _ = rightC.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-c\r\n\r\n"))
		_ = rightC.Close()
	}()
	wrapped.HandleTCPConn(leftC, metadataC)

	traces := recorder.Traces(8)
	if len(traces) != 3 {
		t.Fatalf("trace count = %d want 3", len(traces))
	}
	if traces[0].HashedTuple != traces[1].HashedTuple {
		t.Fatalf("host should not affect tuple hash: %q vs %q", traces[0].HashedTuple, traces[1].HashedTuple)
	}
	if traces[0].HashedTuple == traces[2].HashedTuple {
		t.Fatalf("port change should affect tuple hash: %q", traces[0].HashedTuple)
	}
}

func TestMarkerHashUsesPayloadMarkerEvenWhenDestinationIsLanIP(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("192.168.1.50"),
		DstPort: 443,
		Host:    "192.168.1.50",
	}
	withTunTraceTrackerRangeForTest(t, makeTracker(metadata, []string{"member-lan"}))
	recorder := newTunTraceRecorder("session-lan", &recordingSink{}, 8)
	delegate := &traceTunnel{}
	wrapped := recorder.Wrap(delegate)

	left, right := net.Pipe()
	go func() {
		_, _ = right.Write([]byte("TCP|run|session|flow|cmfa-flow-lan"))
		_ = right.Close()
	}()

	wrapped.HandleTCPConn(left, metadata)

	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	if traces[0].CorrelationHash != hashBytesHex([]byte("cmfa-flow-lan")) {
		t.Fatalf("correlation hash = %q want marker hash", traces[0].CorrelationHash)
	}
}

func TestMarkerHashReturnsEmptyWithoutMarkerOnLanPayloadWhenOutboundProofExists(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("192.168.1.50"),
		DstPort: 443,
		Host:    "192.168.1.50",
	}
	withTunTraceTrackerRangeForTest(t, makeTracker(metadata, []string{"member-no-marker"}))
	recorder := newTunTraceRecorder("session-empty", &recordingSink{}, 8)
	delegate := &traceTunnel{}
	wrapped := recorder.Wrap(delegate)

	left, right := net.Pipe()
	go func() {
		_, _ = right.Write([]byte("TCP|run|session|flow"))
		_ = right.Close()
	}()

	wrapped.HandleTCPConn(left, metadata)

	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	if traces[0].CorrelationHash != "" {
		t.Fatalf("correlation hash = %q want empty without marker", traces[0].CorrelationHash)
	}
	if traces[0].OutboundTerminalHash != hashHex("member-no-marker") {
		t.Fatalf("terminal hash = %q want outbound proof hash", traces[0].OutboundTerminalHash)
	}
}

func TestTunTraceTCPFirstReadCapturesDestinationAndOutboundHashes(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "controlled.invalid",
	}
	withTunTraceTrackerRangeForTest(t, makeTracker(metadata, []string{"member-a", "member-b"}))

	recorder := newTunTraceRecorder("session-proof", &recordingSink{}, 8)
	wrapped := recorder.Wrap(&traceTunnel{})

	left, right := net.Pipe()
	go func() {
		_, _ = right.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-proof\r\n\r\n"))
		_ = right.Close()
	}()

	wrapped.HandleTCPConn(left, metadata)

	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	if len(recorder.resolverSlots) != 0 {
		t.Fatalf("resolver slots = %d want 0 after commit", len(recorder.resolverSlots))
	}
	trace := traces[0]
	if trace.DestinationHash != hashHex("tcp|1.1.1.1|443") {
		t.Fatalf("destination hash = %q want hashed canonical destination", trace.DestinationHash)
	}
	if trace.OutboundTerminalHash != hashHex("member-a") {
		t.Fatalf("terminal hash = %q want first-chain-member hash", trace.OutboundTerminalHash)
	}
	if trace.OutboundChainHash != hashHex(strings.Join([]string{"member-a", "member-b"}, "\x1f")) {
		t.Fatalf("chain hash = %q want chain hash", trace.OutboundChainHash)
	}
	if trace.OutboundChainLength != 2 {
		t.Fatalf("chain length = %d want 2", trace.OutboundChainLength)
	}
}

func TestTunTraceTCPAsyncDelegateCapturesFirstPayloadAndOutboundProof(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("192.0.2.2"),
		DstPort: 443,
	}
	withTunTraceTrackerRangeForTest(t, makeTracker(metadata, []string{"member-a"}))

	events := make(chan RuntimeEvent, 1)
	recorder := newTunTraceRecorder("session-async", &channelEventSink{events: events}, 8)
	delegate := &asyncTraceTunnel{done: make(chan struct{})}
	wrapped := recorder.Wrap(delegate)
	left, right := net.Pipe()
	go func() {
		_, _ = right.Write([]byte("TCP|run|session|flow|cmfa-flow-async"))
		_ = right.Close()
	}()

	wrapped.HandleTCPConn(left, metadata)
	waitForSignal(t, delegate.done, "async delegate completion")
	waitForValue(t, events, "async trace event")

	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	trace := traces[0]
	if trace.CorrelationHash != hashBytesHex([]byte("cmfa-flow-async")) {
		t.Fatalf("correlation hash = %q want marker hash", trace.CorrelationHash)
	}
	if trace.DestinationHash != hashHex("tcp|192.0.2.2|443") {
		t.Fatalf("destination hash = %q want destination hash", trace.DestinationHash)
	}
	if trace.OutboundTerminalHash != hashHex("member-a") || trace.OutboundChainLength != 1 {
		t.Fatalf("outbound proof = %#v want one member", trace)
	}
}

func TestTunTraceTCPStartsOutboundResolverWhileDelegateAndTrackerAreLive(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41010,
		DstIP:   netip.MustParseAddr("192.0.2.10"),
		DstPort: 443,
	}
	withTunTraceOutboundProofLookupForTest(t, func(got *C.Metadata) tunOutboundProof {
		if !sameTunTraceMetadata(metadata, got) {
			t.Fatalf("lookup metadata mismatch: %#v", got)
		}
		return tunOutboundProof{
			terminalHash: hashHex("member-live"),
			chainHash:    hashHex("member-live"),
			chainLength:  1,
		}
	})

	events := make(chan RuntimeEvent, 1)
	recorder := newTunTraceRecorder("session-live", &channelEventSink{events: events}, 8)
	delegate := &blockingReadTraceTunnel{read: make(chan struct{}), release: make(chan struct{})}
	wrapped := recorder.Wrap(delegate)
	left, right := net.Pipe()
	done := make(chan struct{})
	go func() {
		wrapped.HandleTCPConn(left, metadata)
		close(done)
	}()
	go func() {
		_, _ = right.Write([]byte("TCP|run|session|flow|cmfa-flow-live"))
	}()

	waitForSignal(t, delegate.read, "delegate first payload read")
	select {
	case <-events:
		traces := recorder.Traces(8)
		if len(traces) != 1 || traces[0].CorrelationHash != hashBytesHex([]byte("cmfa-flow-live")) {
			t.Fatalf("traces = %#v want one live marker trace", traces)
		}
	case <-time.After(500 * time.Millisecond):
		close(delegate.release)
		_ = right.Close()
		<-done
		t.Fatal("TCP trace resolver did not publish while delegate and tracker were live")
	}
	close(delegate.release)
	_ = right.Close()
	<-done
}

func TestTunTraceTCPResolverOwnershipKeepsHandleBlockedUntilTraceCommits(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41011,
		DstIP:   netip.MustParseAddr("192.0.2.11"),
		DstPort: 443,
	}
	delegate := &blockingReadTraceTunnel{read: make(chan struct{}), release: make(chan struct{})}
	resolverStarted := make(chan struct{}, 1)
	resolverWaitEntered := make(chan struct{}, 1)
	resolverRelease := make(chan struct{})
	events := make(chan RuntimeEvent, 1)
	var proofMu sync.Mutex
	proofReady := false

	withTunTraceResolverLifecycleHooksForTest(
		t,
		func() {
			resolverStarted <- struct{}{}
		},
		func() {},
	)
	withTunTraceResolverHooksForTest(
		t,
		func() time.Time { return time.Unix(0, 0) },
		func(context.Context) bool {
			select {
			case resolverWaitEntered <- struct{}{}:
			default:
			}
			<-resolverRelease
			return true
		},
		time.Second,
	)
	withTunTraceOutboundProofLookupForTest(t, func(got *C.Metadata) tunOutboundProof {
		if !sameTunTraceMetadata(metadata, got) {
			t.Fatalf("lookup metadata mismatch: %#v", got)
		}
		proofMu.Lock()
		ready := proofReady
		proofMu.Unlock()
		if !ready {
			return tunOutboundProof{}
		}
		return tunOutboundProof{
			terminalHash: hashHex("member-owned"),
			chainHash:    hashHex("member-owned"),
			chainLength:  1,
		}
	})

	recorder := newTunTraceRecorder("session-owned", &channelEventSink{events: events}, 8)
	wrapped := recorder.Wrap(delegate)
	left, right := net.Pipe()
	handleReturned := make(chan struct{})
	go func() {
		defer close(handleReturned)
		wrapped.HandleTCPConn(left, metadata)
	}()
	go func() {
		_, _ = right.Write([]byte("TCP|run|session|flow|cmfa-flow-owned"))
	}()

	waitForSignal(t, delegate.read, "delegate first payload read")
	waitForSignal(t, resolverStarted, "resolver start")
	waitForSignal(t, resolverWaitEntered, "resolver wait entry")

	close(delegate.release)
	select {
	case <-handleReturned:
		if traces := recorder.Traces(8); len(traces) == 0 {
			t.Fatal("HandleTCPConn returned before resolver-owned trace committed")
		}
	case <-time.After(100 * time.Millisecond):
	}

	proofMu.Lock()
	proofReady = true
	proofMu.Unlock()
	close(resolverRelease)

	event := waitForValue(t, events, "resolver-owned trace event")
	waitForSignal(t, handleReturned, "resolver-owned HandleTCPConn return")
	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	if event.TraceID != traces[0].TraceID {
		t.Fatalf("event trace = %q want %q", event.TraceID, traces[0].TraceID)
	}
	_ = right.Close()
}

func TestTunTraceTCPDelegateReturnCommitsWithoutResolverSlotWhenProofBecomesReady(t *testing.T) {
	withTunTraceResolverMaxConcurrentForTest(t, 1)
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41012,
		DstIP:   netip.MustParseAddr("192.0.2.12"),
		DstPort: 443,
	}
	delegate := &blockingReadTraceTunnel{read: make(chan struct{}), release: make(chan struct{})}
	firstResolverRelease := make(chan struct{})
	firstResolverWaitEntered := make(chan struct{}, 1)
	resolverStarted := make(chan struct{}, 2)
	var proofMu sync.Mutex
	proofReady := false

	withTunTraceResolverLifecycleHooksForTest(
		t,
		func() {
			resolverStarted <- struct{}{}
		},
		func() {},
	)
	withTunTraceResolverHooksForTest(
		t,
		func() time.Time { return time.Unix(0, 0) },
		func(context.Context) bool {
			select {
			case firstResolverWaitEntered <- struct{}{}:
			default:
			}
			<-firstResolverRelease
			return false
		},
		time.Second,
	)
	withTunTraceOutboundProofLookupForTest(t, func(got *C.Metadata) tunOutboundProof {
		if !sameTunTraceMetadata(metadata, got) {
			return tunOutboundProof{}
		}
		proofMu.Lock()
		ready := proofReady
		proofMu.Unlock()
		if !ready {
			return tunOutboundProof{}
		}
		return tunOutboundProof{
			terminalHash: hashHex("member-sync"),
			chainHash:    hashHex("member-sync"),
			chainLength:  1,
		}
	})

	recorder := newTunTraceRecorder("session-sync-commit", &recordingSink{}, 8)
	slotHolder := recorder.Wrap(&traceTunnel{})
	firstCandidate := &scriptedTraceConn{reads: [][]byte{[]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-slot-holder\r\n\r\n")}}
	go func() {
		slotHolder.HandleTCPConn(firstCandidate, &C.Metadata{
			Type:    C.TUN,
			NetWork: C.TCP,
			SrcIP:   netip.MustParseAddr("10.111.222.2"),
			SrcPort: 41013,
			DstIP:   netip.MustParseAddr("192.0.2.13"),
			DstPort: 443,
		})
	}()

	waitForSignal(t, resolverStarted, "slot-holder resolver start")
	waitForSignal(t, firstResolverWaitEntered, "slot-holder resolver wait")

	wrapped := recorder.Wrap(delegate)
	conn := &scriptedTraceConn{reads: [][]byte{[]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-sync\r\n\r\n")}}
	handleReturned := make(chan struct{})
	go func() {
		defer close(handleReturned)
		wrapped.HandleTCPConn(conn, metadata)
	}()

	waitForSignal(t, delegate.read, "delegate payload read without slot")
	proofMu.Lock()
	proofReady = true
	proofMu.Unlock()
	close(delegate.release)
	waitForSignal(t, handleReturned, "sync commit HandleTCPConn return")

	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	if traces[0].CorrelationHash != hashBytesHex([]byte("cmfa-flow-sync")) {
		t.Fatalf("correlation hash = %q want sync marker hash", traces[0].CorrelationHash)
	}
	select {
	case <-resolverStarted:
		t.Fatal("unexpected resolver start for slot-starved delegate return commit")
	default:
	}

	close(firstResolverRelease)
}

func TestTunTraceTCPImmediateResolverCommitReleasesSlotAndClosesDone(t *testing.T) {
	withTunTraceResolverMaxConcurrentForTest(t, 1)
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41014,
		DstIP:   netip.MustParseAddr("192.0.2.14"),
		DstPort: 443,
	}
	withTunTraceOutboundProofLookupForTest(t, func(got *C.Metadata) tunOutboundProof {
		if !sameTunTraceMetadata(metadata, got) {
			t.Fatalf("lookup metadata mismatch: %#v", got)
		}
		return tunOutboundProof{
			terminalHash: hashHex("member-immediate"),
			chainHash:    hashHex("member-immediate"),
			chainLength:  1,
		}
	})

	recorder := newTunTraceRecorder("session-immediate", &recordingSink{}, 8)
	candidate := &tcpTraceCandidate{
		recorder: recorder,
		metadata: metadata,
		tapped: &tapConn{
			Conn:      &scriptedTraceConn{},
			bytesRead: uint64(len([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-immediate\r\n\r\n"))),
			buffer:    []byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-immediate\r\n\r\n"),
		},
		state: tcpTraceCandidateCollecting,
		done:  make(chan struct{}),
	}

	if !candidate.tryStartResolver() {
		t.Fatal("expected immediate-proof candidate to acquire resolver slot")
	}
	waitForSignal(t, candidate.done, "immediate-proof resolver completion")

	if len(recorder.resolverSlots) != 0 {
		t.Fatalf("resolver slots = %d want 0 after immediate-proof commit", len(recorder.resolverSlots))
	}
	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	if traces[0].CorrelationHash != hashBytesHex([]byte("cmfa-flow-immediate")) {
		t.Fatalf("correlation hash = %q want immediate marker hash", traces[0].CorrelationHash)
	}
}

func TestTunTraceTCPFragmentedProbeMarkerWaitsForProofAndCommitsOnce(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("192.0.2.2"),
		DstPort: 443,
	}
	const marker = "cmfa-11111111-1111-4111-8111-111111111111"
	const firstChunk = "TCP|run|session|flow|cmfa-"
	const secondChunk = "11111111-1111-4111-8111-111111111111"
	conn := &scriptedTraceConn{reads: [][]byte{[]byte(firstChunk), []byte(secondChunk)}}
	lookupCalls := make(chan int, 4)
	signals := make(chan struct{}, 4)
	waitEntered := make(chan struct{}, 1)
	fakeNow := time.Unix(0, 0)
	var nowMu sync.Mutex
	var proofMu sync.Mutex
	proofReady := false
	withTunTraceResolverHooksForTest(
		t,
		func() time.Time {
			nowMu.Lock()
			defer nowMu.Unlock()
			return fakeNow
		},
		func(ctx context.Context) bool {
			select {
			case <-ctx.Done():
				return false
			case <-signals:
				select {
				case waitEntered <- struct{}{}:
				default:
				}
				nowMu.Lock()
				fakeNow = fakeNow.Add(5 * time.Millisecond)
				nowMu.Unlock()
				return true
			}
		},
		time.Second,
	)
	withTunTraceOutboundProofLookupForTest(t, func(got *C.Metadata) tunOutboundProof {
		if !sameTunTraceMetadata(metadata, got) {
			t.Fatalf("lookup metadata mismatch: %#v", got)
		}
		lookupCalls <- 1
		proofMu.Lock()
		ready := proofReady
		proofMu.Unlock()
		if !ready {
			return tunOutboundProof{}
		}
		return tunOutboundProof{
			terminalHash: hashHex("member-a"),
			chainHash:    hashHex("member-a\x1fmember-b"),
			chainLength:  2,
		}
	})

	events := make(chan RuntimeEvent, 1)
	recorder := newTunTraceRecorder("session-fragment", &channelEventSink{events: events}, 8)
	wrapped := recorder.Wrap(&twoReadTraceTunnel{})
	handleReturned := make(chan struct{})
	go func() {
		defer close(handleReturned)
		wrapped.HandleTCPConn(conn, metadata)
	}()

	signals <- struct{}{}
	waitForSignal(t, waitEntered, "fragmented resolver wait entry")
	select {
	case <-handleReturned:
		t.Fatal("HandleTCPConn returned before fragmented resolver finished")
	case <-time.After(100 * time.Millisecond):
	}
	proofMu.Lock()
	proofReady = true
	proofMu.Unlock()
	signals <- struct{}{}
	waitForValue(t, lookupCalls, "fragmented proof lookup")
	event := waitForValue(t, events, "fragmented trace event")
	waitForSignal(t, handleReturned, "fragmented HandleTCPConn return")

	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	trace := traces[0]
	if event.TraceID != trace.TraceID {
		t.Fatalf("event trace = %q want %q", event.TraceID, trace.TraceID)
	}
	select {
	case extra := <-events:
		t.Fatalf("unexpected extra event %#v", extra)
	default:
	}
	if trace.CorrelationHash != hashBytesHex([]byte(marker)) {
		t.Fatalf("correlation hash = %q want full marker hash", trace.CorrelationHash)
	}
	if trace.DestinationHash != hashHex("tcp|192.0.2.2|443") {
		t.Fatalf("destination hash = %q want destination hash", trace.DestinationHash)
	}
	if trace.OutboundTerminalHash != hashHex("member-a") {
		t.Fatalf("terminal hash = %q want outbound proof hash", trace.OutboundTerminalHash)
	}
	if trace.OutboundChainHash != hashHex("member-a\x1fmember-b") || trace.OutboundChainLength != 2 {
		t.Fatalf("outbound proof = %#v want full chain proof", trace)
	}
}

func TestTunTraceTCPNoMarkerCommitsWithOutboundProofOnly(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("192.0.2.10"),
		DstPort: 443,
	}
	withTunTraceOutboundProofLookupForTest(t, func(*C.Metadata) tunOutboundProof {
		return tunOutboundProof{
			terminalHash: hashHex("member-tls"),
			chainHash:    hashHex("member-tls"),
			chainLength:  1,
		}
	})
	recorder := newTunTraceRecorder("session-tls", &recordingSink{}, 8)
	wrapped := recorder.Wrap(&traceTunnel{})
	conn := &scriptedTraceConn{reads: [][]byte{[]byte{0x16, 0x03, 0x01, 0x02, 0x00}}}

	wrapped.HandleTCPConn(conn, metadata)

	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	if traces[0].CorrelationHash != "" {
		t.Fatalf("correlation hash = %q want empty without marker", traces[0].CorrelationHash)
	}
	if traces[0].OutboundTerminalHash != hashHex("member-tls") || traces[0].OutboundChainLength != 1 {
		t.Fatalf("outbound proof = %#v want proof-only commit", traces[0])
	}
}

func TestTunTraceTCPWithoutPayloadProofOrCompleteProbeMarkerDoesNotCommit(t *testing.T) {
	testCases := []struct {
		name  string
		conn  net.Conn
		proof tunOutboundProof
	}{
		{
			name:  "no-payload",
			conn:  &scriptedTraceConn{},
			proof: tunOutboundProof{terminalHash: hashHex("member-a"), chainHash: hashHex("member-a"), chainLength: 1},
		},
		{
			name:  "no-proof",
			conn:  &scriptedTraceConn{reads: [][]byte{[]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\n\r\n")}},
			proof: tunOutboundProof{},
		},
		{
			name:  "truncated-probe-marker",
			conn:  &scriptedTraceConn{reads: [][]byte{[]byte("TCP|run|session|flow|cmfa-11111111-1111-4111-8111")}},
			proof: tunOutboundProof{terminalHash: hashHex("member-a"), chainHash: hashHex("member-a"), chainLength: 1},
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			metadata := &C.Metadata{
				Type:    C.TUN,
				NetWork: C.TCP,
				SrcIP:   netip.MustParseAddr("10.111.222.2"),
				SrcPort: 41000,
				DstIP:   netip.MustParseAddr("192.0.2.20"),
				DstPort: 443,
			}
			resolverExited := make(chan struct{}, 1)
			withTunTraceResolverHooksForTest(
				t,
				func() time.Time { return time.Unix(0, 0).Add(2 * time.Second) },
				func(context.Context) bool {
					resolverExited <- struct{}{}
					return false
				},
				time.Second,
			)
			withTunTraceOutboundProofLookupForTest(t, func(*C.Metadata) tunOutboundProof {
				return testCase.proof
			})
			recorder := newTunTraceRecorder("session-negative", &recordingSink{}, 8)
			wrapped := recorder.Wrap(&traceTunnel{})

			wrapped.HandleTCPConn(testCase.conn, metadata)
			if testCase.name != "no-payload" {
				waitForSignal(t, resolverExited, testCase.name+" resolver exit")
			}

			traces := recorder.Traces(8)
			if len(traces) != 0 {
				t.Fatalf("trace count = %d want 0", len(traces))
			}
		})
	}
}

func TestTunTraceTCPTimeoutWithoutProofPublishesNoEventAndResolverExits(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("192.0.2.30"),
		DstPort: 443,
	}
	events := make(chan RuntimeEvent, 1)
	resolverDone := make(chan struct{}, 1)
	lookupCalls := make(chan struct{}, 4)
	fakeNow := time.Unix(0, 0)
	var nowMu sync.Mutex
	withTunTraceResolverLifecycleHooksForTest(
		t,
		func() {},
		func() {
			resolverDone <- struct{}{}
		},
	)
	withTunTraceResolverHooksForTest(
		t,
		func() time.Time {
			nowMu.Lock()
			defer nowMu.Unlock()
			return fakeNow
		},
		func(context.Context) bool {
			nowMu.Lock()
			fakeNow = fakeNow.Add(2 * time.Second)
			nowMu.Unlock()
			return false
		},
		time.Second,
	)
	withTunTraceOutboundProofLookupForTest(t, func(*C.Metadata) tunOutboundProof {
		lookupCalls <- struct{}{}
		return tunOutboundProof{}
	})

	recorder := newTunTraceRecorder("session-timeout", &channelEventSink{events: events}, 8)
	wrapped := recorder.Wrap(&traceTunnel{})
	conn := &scriptedTraceConn{reads: [][]byte{[]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-timeout\r\n\r\n")}}
	handleDone := make(chan struct{})
	go func() {
		defer close(handleDone)
		wrapped.HandleTCPConn(conn, metadata)
	}()
	waitForSignal(t, lookupCalls, "timeout first proof lookup")
	waitForSignal(t, resolverDone, "timeout resolver done")
	waitForSignal(t, handleDone, "timeout HandleTCPConn return")

	if traces := recorder.Traces(8); len(traces) != 0 {
		t.Fatalf("trace count = %d want 0", len(traces))
	}
	if len(recorder.resolverSlots) != 0 {
		t.Fatalf("resolver slots = %d want 0 after timeout", len(recorder.resolverSlots))
	}
	select {
	case event := <-events:
		t.Fatalf("unexpected event %#v", event)
	default:
	}
	select {
	case <-lookupCalls:
		t.Fatal("resolver continued after timeout exit")
	default:
	}
}

func TestTunTraceTCPDelegateReturnAfterTimeoutDoesNotRestartOwnedResolver(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("192.0.2.29"),
		DstPort: 443,
	}
	events := make(chan RuntimeEvent, 1)
	delegate := &blockingReadTraceTunnel{read: make(chan struct{}), release: make(chan struct{})}
	resolverStarted := make(chan struct{}, 2)
	resolverDone := make(chan struct{}, 2)
	lookupCalls := make(chan struct{}, 4)
	fakeNow := time.Unix(0, 0)
	var nowMu sync.Mutex

	withTunTraceResolverLifecycleHooksForTest(
		t,
		func() {
			resolverStarted <- struct{}{}
		},
		func() {
			resolverDone <- struct{}{}
		},
	)
	withTunTraceResolverHooksForTest(
		t,
		func() time.Time {
			nowMu.Lock()
			defer nowMu.Unlock()
			return fakeNow
		},
		func(context.Context) bool {
			nowMu.Lock()
			fakeNow = fakeNow.Add(2 * time.Second)
			nowMu.Unlock()
			return false
		},
		time.Second,
	)
	withTunTraceOutboundProofLookupForTest(t, func(*C.Metadata) tunOutboundProof {
		lookupCalls <- struct{}{}
		return tunOutboundProof{}
	})

	recorder := newTunTraceRecorder("session-delegate-timeout", &channelEventSink{events: events}, 8)
	wrapped := recorder.Wrap(delegate)
	conn := &scriptedTraceConn{reads: [][]byte{[]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-timeout\r\n\r\n")}}
	handleDone := make(chan struct{})
	go func() {
		defer close(handleDone)
		wrapped.HandleTCPConn(conn, metadata)
	}()

	waitForSignal(t, delegate.read, "delegate first payload read")
	waitForSignal(t, resolverStarted, "first resolver start")
	waitForSignal(t, lookupCalls, "initial proof lookup")
	waitForSignal(t, resolverDone, "first resolver done")

	close(delegate.release)
	waitForSignal(t, handleDone, "delegate return after timeout")

	select {
	case <-resolverStarted:
		t.Fatal("unexpected resolver restart after owned resolver timeout")
	case <-time.After(100 * time.Millisecond):
	}
	select {
	case <-lookupCalls:
		t.Fatal("unexpected proof lookup after owned resolver timeout")
	default:
	}
	if traces := recorder.Traces(8); len(traces) != 0 {
		t.Fatalf("trace count = %d want 0", len(traces))
	}
	if len(recorder.resolverSlots) != 0 {
		t.Fatalf("resolver slots = %d want 0 after delegate return", len(recorder.resolverSlots))
	}
	select {
	case event := <-events:
		t.Fatalf("unexpected event %#v", event)
	default:
	}
}

func TestTunTraceTCPResolverSlotBackpressureDoesNotSpawnPendingWaiters(t *testing.T) {
	withTunTraceResolverMaxConcurrentForTest(t, 1)
	firstWaitRelease := make(chan struct{})
	firstWaitEntered := make(chan struct{}, 1)
	firstResolverDone := make(chan struct{}, 1)
	waitCycle := 0
	var activeMu sync.Mutex
	started := 0
	active := 0
	withTunTraceResolverLifecycleHooksForTest(
		t,
		func() {
			activeMu.Lock()
			started += 1
			active += 1
			activeMu.Unlock()
		},
		func() {
			activeMu.Lock()
			active -= 1
			activeMu.Unlock()
		},
	)
	withTunTraceResolverHooksForTest(
		t,
		func() time.Time { return time.Unix(0, 0) },
		func(context.Context) bool {
			select {
			case firstWaitEntered <- struct{}{}:
			default:
			}
			select {
			case <-firstWaitRelease:
				waitCycle += 1
				firstResolverDone <- struct{}{}
				return false
			case <-time.After(2 * time.Second):
				t.Fatal("timed out waiting to release first resolver")
				return false
			}
		},
		time.Second,
	)
	withTunTraceOutboundProofLookupForTest(t, func(*C.Metadata) tunOutboundProof {
		return tunOutboundProof{}
	})

	recorder := newTunTraceRecorder("session-fanout", &recordingSink{}, 8)
	wrapped := recorder.Wrap(&traceTunnel{})
	newCandidate := func(srcPort uint16, payload string) <-chan struct{} {
		done := make(chan struct{})
		conn := &scriptedTraceConn{reads: [][]byte{[]byte(payload)}}
		go func() {
			defer close(done)
			wrapped.HandleTCPConn(conn, &C.Metadata{
				Type:    C.TUN,
				NetWork: C.TCP,
				SrcIP:   netip.MustParseAddr("10.111.222.2"),
				SrcPort: srcPort,
				DstIP:   netip.MustParseAddr("192.0.2.40"),
				DstPort: 443,
			})
		}()
		return done
	}

	firstCandidateDone := newCandidate(41000, "GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-1\r\n\r\n")
	waitForSignal(t, firstWaitEntered, "first resolver wait entry")

	secondCandidateDone := newCandidate(41001, "GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-2\r\n\r\n")
	thirdCandidateDone := newCandidate(41002, "GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-3\r\n\r\n")

	activeMu.Lock()
	if started != 1 || active != 1 {
		activeMu.Unlock()
		t.Fatalf("resolver lifecycle counters = started:%d active:%d want 1/1 while slot occupied", started, active)
	}
	activeMu.Unlock()
	if len(recorder.Traces(8)) != 0 {
		t.Fatal("recorder should not emit traces before proof resolves")
	}
	waitForSignal(t, secondCandidateDone, "second candidate fail-closed return")
	waitForSignal(t, thirdCandidateDone, "third candidate fail-closed return")

	close(firstWaitRelease)
	waitForSignal(t, firstResolverDone, "first resolver completion")
	waitForSignal(t, firstCandidateDone, "first candidate completion")

	firstWaitRelease = make(chan struct{})
	fourthCandidateDone := newCandidate(41003, "GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-4\r\n\r\n")
	waitForSignal(t, firstWaitEntered, "reused resolver wait entry")

	activeMu.Lock()
	if started != 2 || active != 1 {
		activeMu.Unlock()
		t.Fatalf("resolver lifecycle counters after slot reuse = started:%d active:%d want 2/1", started, active)
	}
	activeMu.Unlock()
	if len(recorder.Traces(8)) != 0 {
		t.Fatal("recorder should still fail-closed without proof")
	}
	if waitCycle != 1 {
		t.Fatalf("resolver completion count before second release = %d want 1", waitCycle)
	}
	close(firstWaitRelease)
	waitForSignal(t, firstResolverDone, "second resolver completion")
	waitForSignal(t, fourthCandidateDone, "fourth candidate completion")
}

func TestTunTraceTCPNoReadDoesNotCreateUncorrelatedEvidence(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
	}
	withTunTraceTrackerRangeForTest(t, makeTracker(metadata, []string{"member-a"}))

	recorder := newTunTraceRecorder("session-proof", &recordingSink{}, 8)
	delegate := &noReadTraceTunnel{}
	wrapped := recorder.Wrap(delegate)

	left, right := net.Pipe()
	go func() {
		_, _ = right.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\n\r\n"))
		_ = right.Close()
	}()

	wrapped.HandleTCPConn(left, metadata)

	if delegate.tcpCalls != 1 {
		t.Fatalf("delegate tcp calls = %d want 1", delegate.tcpCalls)
	}
	traces := recorder.Traces(8)
	if len(traces) != 0 {
		t.Fatalf("trace count = %d want 0 without payload correlation", len(traces))
	}
}

func TestTunTraceUDPAppendsOutboundProofAfterDelegate(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.UDP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 53000,
		DstIP:   netip.MustParseAddr("8.8.8.8"),
		DstPort: 53,
	}
	delegateCalled := false
	rangedBeforeDelegate := false
	previous := tunTraceTrackerRange
	tunTraceTrackerRange = func(yield func(statistic.Tracker) bool) {
		if !delegateCalled {
			rangedBeforeDelegate = true
		}
		_ = yield(makeTracker(metadata, []string{"member-udp"}))
	}
	t.Cleanup(func() {
		tunTraceTrackerRange = previous
	})

	recorder := newTunTraceRecorder("session-proof", &recordingSink{}, 8)
	delegate := &orderingTraceTunnel{delegateCalled: &delegateCalled}
	wrapped := recorder.Wrap(delegate)
	packet := &tracePacket{payload: []byte("query cmfa-flow-udp-proof")}

	wrapped.HandleUDPPacket(packet, metadata)

	if delegate.udpCalls != 1 {
		t.Fatalf("delegate udp calls = %d want 1", delegate.udpCalls)
	}
	if rangedBeforeDelegate {
		t.Fatal("udp outbound proof must be captured after delegate joins tracker")
	}
	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	trace := traces[0]
	if trace.OutboundTerminalHash != hashHex("member-udp") {
		t.Fatalf("terminal hash = %q want udp outbound proof hash", trace.OutboundTerminalHash)
	}
	if trace.OutboundChainLength != 1 {
		t.Fatalf("chain length = %d want 1", trace.OutboundChainLength)
	}
}

func TestTunTraceUDPRecognizesStructuredDNSQueryOutsidePort53(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.UDP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 53000,
		DstIP:   netip.MustParseAddr("192.0.2.88"),
		DstPort: 45678,
	}
	payload := buildDNSQueryPayload("flow.example.invalid")
	recorder := newTunTraceRecorder("session-dns-udp", &recordingSink{}, 8)
	wrapped := recorder.Wrap(&traceTunnel{})

	wrapped.HandleUDPPacket(&tracePacket{payload: payload}, metadata)

	traces := recorder.Traces(8)
	if len(traces) != 1 {
		t.Fatalf("trace count = %d want 1", len(traces))
	}
	if traces[0].Protocol != "dns" {
		t.Fatalf("protocol = %q want dns", traces[0].Protocol)
	}
	if traces[0].CorrelationHash != hashBytesHex(payload) {
		t.Fatalf("correlation hash = %q want dns payload hash", traces[0].CorrelationHash)
	}
}

func TestTunTraceUDPDoesNotMisclassifyMarkerOrMalformedPayloadAsDNS(t *testing.T) {
	recorder := newTunTraceRecorder("session-udp-shape", &recordingSink{}, 8)
	wrapped := recorder.Wrap(&traceTunnel{})

	markerPayload := []byte("query cmfa-flow-udp-proof")
	wrapped.HandleUDPPacket(&tracePacket{payload: markerPayload}, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.UDP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 53000,
		DstIP:   netip.MustParseAddr("192.0.2.90"),
		DstPort: 45679,
	})

	malformedPayload := append([]byte(nil), buildDNSQueryPayload("bad.example.invalid")...)
	malformedPayload = malformedPayload[:len(malformedPayload)-1]
	wrapped.HandleUDPPacket(&tracePacket{payload: malformedPayload}, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.UDP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 53001,
		DstIP:   netip.MustParseAddr("192.0.2.91"),
		DstPort: 45680,
	})

	traces := recorder.Traces(8)
	if len(traces) != 2 {
		t.Fatalf("trace count = %d want 2", len(traces))
	}
	if traces[0].Protocol != "udp" {
		t.Fatalf("marker payload protocol = %q want udp", traces[0].Protocol)
	}
	if traces[0].CorrelationHash == "" {
		t.Fatal("marker payload should keep udp marker correlation")
	}
	if traces[1].Protocol != "udp" {
		t.Fatalf("malformed payload protocol = %q want udp", traces[1].Protocol)
	}
	if traces[1].CorrelationHash != "" {
		t.Fatalf("malformed payload correlation = %q want empty", traces[1].CorrelationHash)
	}
}

func TestTunTraceOutboundProofRequiresExactlyOneMatchingTracker(t *testing.T) {
	testCases := []struct {
		name     string
		trackers []statistic.Tracker
	}{
		{
			name:     "zero-match",
			trackers: nil,
		},
		{
			name: "multiple-match",
			trackers: []statistic.Tracker{
				makeTracker(&C.Metadata{
					Type: C.TUN, NetWork: C.TCP,
					SrcIP: netip.MustParseAddr("10.111.222.2"), SrcPort: 41000,
					DstIP: netip.MustParseAddr("1.1.1.1"), DstPort: 443,
				}, []string{"member-a"}),
				makeTracker(&C.Metadata{
					Type: C.TUN, NetWork: C.TCP,
					SrcIP: netip.MustParseAddr("10.111.222.2"), SrcPort: 41000,
					DstIP: netip.MustParseAddr("1.1.1.1"), DstPort: 443,
				}, []string{"member-b"}),
			},
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			metadata := &C.Metadata{
				Type:    C.TUN,
				NetWork: C.TCP,
				SrcIP:   netip.MustParseAddr("10.111.222.2"),
				SrcPort: 41000,
				DstIP:   netip.MustParseAddr("1.1.1.1"),
				DstPort: 443,
			}
			withTunTraceTrackerRangeForTest(t, testCase.trackers...)
			recorder := newTunTraceRecorder("session-proof", &recordingSink{}, 8)
			wrapped := recorder.Wrap(&traceTunnel{})

			left, right := net.Pipe()
			go func() {
				_, _ = right.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-proof\r\n\r\n"))
				_ = right.Close()
			}()

			wrapped.HandleTCPConn(left, metadata)

			traces := recorder.Traces(8)
			if len(traces) != 0 {
				t.Fatalf("trace count = %d want 0 on %s without unique outbound proof", len(traces), testCase.name)
			}
		})
	}
}

func TestTunTraceRejectsInvalidOutboundChains(t *testing.T) {
	longElement := strings.Repeat("a", 257)
	manyElements := make([]string, 17)
	for index := range manyElements {
		manyElements[index] = "x"
	}
	testCases := []struct {
		name  string
		chain []string
	}{
		{name: "empty-chain", chain: []string{}},
		{name: "too-many", chain: manyElements},
		{name: "empty-element", chain: []string{"member-a", ""}},
		{name: "oversized-element", chain: []string{longElement}},
		{name: "invalid-utf8", chain: []string{makeInvalidUTF8ChainElement()}},
		{name: "separator-control", chain: []string{"member\x1fshadow"}},
		{name: "newline-control", chain: []string{"member\nshadow"}},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			metadata := &C.Metadata{
				Type:    C.TUN,
				NetWork: C.TCP,
				SrcIP:   netip.MustParseAddr("10.111.222.2"),
				SrcPort: 41000,
				DstIP:   netip.MustParseAddr("1.1.1.1"),
				DstPort: 443,
			}
			withTunTraceTrackerRangeForTest(t, makeTracker(metadata, testCase.chain))
			recorder := newTunTraceRecorder("session-proof", &recordingSink{}, 8)
			wrapped := recorder.Wrap(&traceTunnel{})

			left, right := net.Pipe()
			go func() {
				_, _ = right.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-proof\r\n\r\n"))
				_ = right.Close()
			}()

			wrapped.HandleTCPConn(left, metadata)

			traces := recorder.Traces(8)
			if len(traces) != 0 {
				t.Fatalf("trace count = %d want 0 for invalid chain", len(traces))
			}
		})
	}
}

func TestTunTraceCloneAndRingKeepOutboundProofPrivacySafe(t *testing.T) {
	metadata := &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
	}
	withTunTraceTrackerRangeForTest(t, makeTracker(metadata, []string{"member-a", "member-b"}))
	recorder := newTunTraceRecorder("session-proof", &recordingSink{}, 2)
	wrapped := recorder.Wrap(&traceTunnel{})

	for index := 0; index < 2; index += 1 {
		left, right := net.Pipe()
		go func() {
			_, _ = right.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-proof\r\n\r\n"))
			_ = right.Close()
		}()
		wrapped.HandleTCPConn(left, metadata)
	}

	firstRead := recorder.Traces(2)
	if len(firstRead) != 2 {
		t.Fatalf("trace count = %d want 2", len(firstRead))
	}
	formatted := fmt.Sprintf("%#v", firstRead[0])
	if strings.Contains(formatted, "member-a") || strings.Contains(formatted, "member-b") {
		t.Fatalf("trace leaked raw outbound chain: %s", formatted)
	}
	firstRead[0].OutboundTerminalHash = "mutated"
	firstRead[0].OutboundChainLength = 99

	secondRead := recorder.Traces(2)
	if secondRead[0].OutboundTerminalHash != hashHex("member-a") {
		t.Fatalf("clone mutation leaked into recorder state: %q", secondRead[0].OutboundTerminalHash)
	}
	if secondRead[0].OutboundChainLength != 2 {
		t.Fatalf("clone mutation changed ring state: %d", secondRead[0].OutboundChainLength)
	}
}

func TestTapConnConcurrentReadAndPeek(t *testing.T) {
	left, right := net.Pipe()
	tapped := &tapConn{Conn: left}
	defer left.Close()
	defer right.Close()

	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		buffer := make([]byte, 1)
		for {
			if _, err := tapped.Read(buffer); err != nil {
				return
			}
		}
	}()

	const chunks = 256
	go func() {
		payload := []byte("cmfa-race-probe")
		for index := 0; index < chunks; index += 1 {
			_, _ = right.Write(payload)
		}
		_ = right.Close()
	}()

	for index := 0; index < chunks*4; index += 1 {
		_ = tapped.peek()
	}

	waitForSignal(t, readDone, "concurrent read completion")
	if len(tapped.peek()) == 0 {
		t.Fatal("peek should retain buffered payload after concurrent reads")
	}
}
