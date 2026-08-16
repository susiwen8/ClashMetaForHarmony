package runtime

import (
	"bytes"
	"io"
	"net"
	"net/netip"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

type traceTunnel struct {
	tcpCalls int
	udpCalls int
}

func (t *traceTunnel) HandleTCPConn(conn net.Conn, _ *C.Metadata) {
	t.tcpCalls += 1
	_, _ = io.Copy(io.Discard, conn)
	_ = conn.Close()
}

func (t *traceTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) {
	t.udpCalls += 1
	packet.Drop()
}

func (t *traceTunnel) NatTable() C.NatTable { return fakeNatTable{} }

type tracePacket struct {
	payload []byte
	dropped bool
}

func (p *tracePacket) Data() []byte                           { return p.payload }
func (p *tracePacket) Drop()                                  { p.dropped = true }
func (p *tracePacket) LocalAddr() net.Addr                    { return &net.UDPAddr{IP: net.IPv4(10, 0, 0, 2), Port: 5353} }
func (p *tracePacket) WriteBack([]byte, net.Addr) (int, error) { return 0, nil }

func TestIngressTraceWrapsTunBoundaryOnly(t *testing.T) {
	delegate := &traceTunnel{}
	events := &recordingSink{}
	recorder := newTunTraceRecorder("session-1", events, 256)
	wrapped := recorder.Wrap(delegate)

	left, right := net.Pipe()
	go func() {
		_, _ = right.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-1\r\n\r\n"))
		_ = right.Close()
	}()

	wrapped.HandleTCPConn(left, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("172.19.0.2"),
		SrcPort: 42424,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "controlled.invalid",
	})

	packet := &tracePacket{payload: []byte("query cmfa-flow-udp")}
	wrapped.HandleUDPPacket(packet, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.UDP,
		SrcIP:   netip.MustParseAddr("172.19.0.2"),
		SrcPort: 53000,
		DstIP:   netip.MustParseAddr("8.8.8.8"),
		DstPort: 53,
	})

	if delegate.tcpCalls != 1 || delegate.udpCalls != 1 {
		t.Fatalf("delegate calls = tcp:%d udp:%d want 1/1", delegate.tcpCalls, delegate.udpCalls)
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
	recorder := newTunTraceRecorder("session-1", &recordingSink{}, 8)
	delegate := &traceTunnel{}
	wrapped := recorder.Wrap(delegate)

	leftA, rightA := net.Pipe()
	go func() {
		_, _ = rightA.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-a\r\n\r\n"))
		_ = rightA.Close()
	}()
	wrapped.HandleTCPConn(leftA, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "controlled.invalid",
	})

	leftB, rightB := net.Pipe()
	go func() {
		_, _ = rightB.Write([]byte("GET / HTTP/1.1\r\nHost: another.invalid\r\nX-CMFA-Flow: cmfa-flow-b\r\n\r\n"))
		_ = rightB.Close()
	}()
	wrapped.HandleTCPConn(leftB, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41000,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "another.invalid",
	})

	leftC, rightC := net.Pipe()
	go func() {
		_, _ = rightC.Write([]byte("GET / HTTP/1.1\r\nHost: controlled.invalid\r\nX-CMFA-Flow: cmfa-flow-c\r\n\r\n"))
		_ = rightC.Close()
	}()
	wrapped.HandleTCPConn(leftC, &C.Metadata{
		Type:    C.TUN,
		NetWork: C.TCP,
		SrcIP:   netip.MustParseAddr("10.111.222.2"),
		SrcPort: 41001,
		DstIP:   netip.MustParseAddr("1.1.1.1"),
		DstPort: 443,
		Host:    "controlled.invalid",
	})

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
