//go:build with_gvisor

package runtime

import (
	"bytes"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing"
	mihomosingtun "github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
	stun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

type capturedNetworkPacket struct {
	protocol tcpip.NetworkProtocolNumber
	payload  []byte
}

type captureNetworkDispatcher struct {
	packets chan capturedNetworkPacket
}

func (d *captureNetworkDispatcher) DeliverNetworkPacket(protocol tcpip.NetworkProtocolNumber, packet *stack.PacketBuffer) {
	var payload []byte
	for _, view := range packet.AsSlices() {
		payload = append(payload, view...)
	}
	d.packets <- capturedNetworkPacket{protocol: protocol, payload: payload}
}

func (*captureNetworkDispatcher) DeliverLinkPacket(tcpip.NetworkProtocolNumber, *stack.PacketBuffer) {
}

func TestHarmonyGVisorTunBridgesPacketsWithoutFdMetadataInspection(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatalf("Socketpair error: %v", err)
	}
	peerFD := fds[0]
	if err := unix.SetNonblock(fds[1], true); err != nil {
		t.Fatalf("SetNonblock TUN endpoint: %v", err)
	}
	tunFile := os.NewFile(uintptr(fds[1]), "test-harmony-tun")
	defer unix.Close(peerFD)

	bridge := newHarmonyGVisorTun(tunFile, 1500)
	defer bridge.Close()
	endpoint, _, err := bridge.NewEndpoint()
	if err != nil {
		t.Fatalf("NewEndpoint error: %v", err)
	}
	dispatcher := &captureNetworkDispatcher{packets: make(chan capturedNetworkPacket, 1)}
	endpoint.Attach(dispatcher)

	inbound := make([]byte, header.IPv4MinimumSize)
	inbound[0] = 0x45
	if _, err := unix.Write(peerFD, inbound); err != nil {
		t.Fatalf("write inbound packet: %v", err)
	}
	select {
	case captured := <-dispatcher.packets:
		if captured.protocol != header.IPv4ProtocolNumber {
			t.Fatalf("inbound protocol = %v want IPv4", captured.protocol)
		}
		if !bytes.Equal(captured.payload, inbound) {
			t.Fatalf("inbound payload = %x want %x", captured.payload, inbound)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for inbound packet")
	}

	outbound := make([]byte, header.IPv6MinimumSize)
	outbound[0] = 0x60
	packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(outbound)})
	var packets stack.PacketBufferList
	packets.PushBack(packet)
	if written, writeErr := endpoint.WritePackets(packets); writeErr != nil || written != 1 {
		t.Fatalf("WritePackets = (%d, %v) want (1, nil)", written, writeErr)
	}
	packet.DecRef()
	if err := unix.SetNonblock(peerFD, true); err != nil {
		t.Fatalf("SetNonblock peer: %v", err)
	}
	deadline := time.Now().Add(time.Second)
	buffer := make([]byte, 2048)
	for {
		n, readErr := unix.Read(peerFD, buffer)
		if readErr == nil {
			if !bytes.Equal(buffer[:n], outbound) {
				t.Fatalf("outbound payload = %x want %x", buffer[:n], outbound)
			}
			break
		}
		if readErr != unix.EAGAIN && readErr != unix.EWOULDBLOCK {
			t.Fatalf("read outbound packet: %v", readErr)
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for outbound packet")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestProductionTunFactoryDefaultsToDirectUnixFDIO(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatalf("Socketpair error: %v", err)
	}
	peerFD := fds[0]
	tunFD := fds[1]
	defer unix.Close(peerFD)

	deps := defaultProductionTunFactoryDeps()
	tunDevice, err := deps.newTun(stun.Options{FileDescriptor: tunFD})
	if err != nil {
		t.Fatalf("default newTun error: %v", err)
	}
	if _, ok := tunDevice.(*harmonyFDTun); !ok {
		t.Fatalf("default newTun type = %T want *harmonyFDTun", tunDevice)
	}

	inbound := []byte{0x45, 0x00, 0x00, 0x14}
	if _, err := unix.Write(peerFD, inbound); err != nil {
		t.Fatalf("write inbound packet: %v", err)
	}
	readBuffer := make([]byte, 64)
	n, err := tunDevice.Read(readBuffer)
	if err != nil {
		t.Fatalf("direct fd read: %v", err)
	}
	if !bytes.Equal(readBuffer[:n], inbound) {
		t.Fatalf("direct fd read = %x want %x", readBuffer[:n], inbound)
	}

	outbound := []byte{0x60, 0x00, 0x00, 0x00}
	if _, err := tunDevice.Write(outbound); err != nil {
		t.Fatalf("direct fd write: %v", err)
	}
	n, err = unix.Read(peerFD, readBuffer)
	if err != nil {
		t.Fatalf("read outbound packet: %v", err)
	}
	if !bytes.Equal(readBuffer[:n], outbound) {
		t.Fatalf("direct fd write = %x want %x", readBuffer[:n], outbound)
	}

	if err := tunDevice.Close(); err != nil {
		t.Fatalf("direct fd close: %v", err)
	}
	assertFDClosed(t, tunFD)
}

func TestHarmonyGVisorTunContinuesAfterTransientReadError(t *testing.T) {
	inbound := make([]byte, header.IPv4MinimumSize)
	inbound[0] = 0x45
	tunDevice := &transientReadTun{
		packet: inbound,
		closed: make(chan struct{}),
	}
	bridge := newHarmonyGVisorTun(tunDevice, 1500)
	events := &recordingSink{}
	bridge.reporter = newTunTraceRecorder("session-transient", events, 8)
	defer bridge.Close()
	endpoint, _, err := bridge.NewEndpoint()
	if err != nil {
		t.Fatalf("NewEndpoint error: %v", err)
	}
	dispatcher := &captureNetworkDispatcher{packets: make(chan capturedNetworkPacket, 1)}
	endpoint.Attach(dispatcher)

	select {
	case captured := <-dispatcher.packets:
		if captured.protocol != header.IPv4ProtocolNumber {
			t.Fatalf("inbound protocol = %v want IPv4", captured.protocol)
		}
		if !bytes.Equal(captured.payload, inbound) {
			t.Fatalf("inbound payload = %x want %x", captured.payload, inbound)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for inbound packet after transient read error")
	}

	waitForDiagnosticEventCount(t, events, 4)
	gotStages := []string{}
	for _, event := range events.Events() {
		gotStages = append(gotStages, event.Protocol)
	}
	wantStages := []string{
		"tun.packet.read-loop-enter",
		"tun.packet.read-would-block",
		"tun.packet.raw-read",
		"tun.packet.gvisor-inject",
	}
	if !slices.Equal(gotStages, wantStages) {
		t.Fatalf("diagnostic stages = %v want %v", gotStages, wantStages)
	}
}

func TestHarmonyGVisorTunReportsEndpointEntrySynchronously(t *testing.T) {
	tunDevice := &closeUnblocksReadTun{closed: make(chan struct{})}
	events := &recordingSink{}
	recorder := newTunTraceRecorder("session-endpoint", events, 8)
	stages := make(chan string, 2)
	recorder.packetDiagnosticSink = func(stage string) {
		stages <- stage
	}
	bridge := newHarmonyGVisorTun(tunDevice, 1500)
	bridge.reporter = recorder
	defer bridge.Close()

	if _, _, err := bridge.NewEndpoint(); err != nil {
		t.Fatalf("NewEndpoint error: %v", err)
	}
	select {
	case stage := <-stages:
		if stage != "tun.listener.endpoint-enter" {
			t.Fatalf("first synchronous endpoint stage = %q want tun.listener.endpoint-enter", stage)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for synchronous endpoint stage")
	}
}

func TestHarmonyGVisorTunReportsFatalReadWithoutDynamicErrorDetail(t *testing.T) {
	tunDevice := &fatalReadTun{err: unix.EIO}
	events := &recordingSink{}
	bridge := newHarmonyGVisorTun(tunDevice, 1500)
	bridge.reporter = newTunTraceRecorder("session-fatal", events, 8)
	defer bridge.Close()
	if _, _, err := bridge.NewEndpoint(); err != nil {
		t.Fatalf("NewEndpoint error: %v", err)
	}

	waitForDiagnosticEventCount(t, events, 2)
	gotEvents := events.Events()
	wantStages := []string{
		"tun.packet.read-loop-enter",
		"tun.packet.read-failed",
	}
	for index, wantStage := range wantStages {
		if gotEvents[index].Protocol != wantStage || gotEvents[index].Message != wantStage {
			t.Fatalf("event[%d] = %#v want fixed stage %q", index, gotEvents[index], wantStage)
		}
	}
}

func TestHarmonyGVisorTunRetriesInterruptedReadWithoutFailureDiagnostic(t *testing.T) {
	inbound := make([]byte, header.IPv4MinimumSize)
	inbound[0] = 0x45
	tunDevice := &interruptedReadTun{
		packet: inbound,
		closed: make(chan struct{}),
	}
	events := &recordingSink{}
	bridge := newHarmonyGVisorTun(tunDevice, 1500)
	bridge.reporter = newTunTraceRecorder("session-interrupted", events, 8)
	defer bridge.Close()
	endpoint, _, err := bridge.NewEndpoint()
	if err != nil {
		t.Fatalf("NewEndpoint error: %v", err)
	}
	dispatcher := &captureNetworkDispatcher{packets: make(chan capturedNetworkPacket, 1)}
	endpoint.Attach(dispatcher)

	select {
	case <-dispatcher.packets:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for inbound packet after interrupted read")
	}
	waitForDiagnosticEventCount(t, events, 3)
	gotStages := []string{}
	for _, event := range events.Events() {
		gotStages = append(gotStages, event.Protocol)
	}
	wantStages := []string{
		"tun.packet.read-loop-enter",
		"tun.packet.raw-read",
		"tun.packet.gvisor-inject",
	}
	if !slices.Equal(gotStages, wantStages) {
		t.Fatalf("diagnostic stages = %v want %v", gotStages, wantStages)
	}
}

func TestHarmonyGVisorTunCloseDoesNotReportFatalRead(t *testing.T) {
	tunDevice := &closeUnblocksReadTun{closed: make(chan struct{})}
	events := &recordingSink{}
	bridge := newHarmonyGVisorTun(tunDevice, 1500)
	bridge.reporter = newTunTraceRecorder("session-close", events, 8)
	if _, _, err := bridge.NewEndpoint(); err != nil {
		t.Fatalf("NewEndpoint error: %v", err)
	}
	waitForDiagnosticEventCount(t, events, 1)

	if err := bridge.Close(); err != nil {
		t.Fatalf("Close error: %v", err)
	}
	gotEvents := events.Events()
	if len(gotEvents) != 1 || gotEvents[0].Protocol != "tun.packet.read-loop-enter" {
		t.Fatalf("close diagnostics = %#v want read-loop-enter only", gotEvents)
	}
}

func TestProductionTunFactoryPublishesPacketDiagnosticsOnceWithoutTouchingTraceState(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatalf("Socketpair error: %v", err)
	}
	peerFD := fds[0]
	abiFD := fds[1]
	defer unix.Close(peerFD)
	defer unix.Close(abiFD)

	events := &recordingSink{}
	recorder := newTunTraceRecorder("session-diag", events, 8)
	wrappedTunnel := recorder.Wrap(tunnel.Tunnel)
	stackRecorder := &productionTunFactoryRecorder{}
	var bridge *harmonyGVisorTun
	listener, err := productionTunListenerFactoryWithDeps(productionTunFactoryDeps{
		setNonblock: unix.SetNonblock,
		dupFD:       unix.Dup,
		closeFD:     unix.Close,
		newTun: func(options stun.Options) (stun.Tun, error) {
			return os.NewFile(uintptr(options.FileDescriptor), "diag-harmony-tun"), nil
		},
		newBridge: func(tunDevice stun.Tun, mtu uint32) *harmonyGVisorTun {
			bridge = newHarmonyGVisorTun(tunDevice, mtu)
			return bridge
		},
		newGVisor: func(options stun.StackOptions) (stun.Stack, error) {
			return &recordingStack{recorder: stackRecorder}, nil
		},
		addDNS:    func(...string) {},
		removeDNS: func(...string) {},
	}, buildTunConfig(abiFD), wrappedTunnel)
	if err != nil {
		t.Fatalf("productionTunListenerFactoryWithDeps error: %v", err)
	}
	defer listener.Close()
	if bridge == nil {
		t.Fatal("bridge should not be nil")
	}

	endpoint, _, err := bridge.NewEndpoint()
	if err != nil {
		t.Fatalf("NewEndpoint error: %v", err)
	}
	dispatcher := &captureNetworkDispatcher{packets: make(chan capturedNetworkPacket, 4)}
	endpoint.Attach(dispatcher)

	invalid := []byte{0x10, 0x00, 0x00, 0x00}
	validV4 := make([]byte, header.IPv4MinimumSize)
	validV4[0] = 0x45
	validV6 := make([]byte, header.IPv6MinimumSize)
	validV6[0] = 0x60
	for _, packet := range [][]byte{invalid, validV4, validV6} {
		if _, err := unix.Write(peerFD, packet); err != nil {
			t.Fatalf("write inbound packet %x: %v", packet, err)
		}
	}

	for index, wantProtocol := range []tcpip.NetworkProtocolNumber{
		header.IPv4ProtocolNumber,
		header.IPv6ProtocolNumber,
	} {
		select {
		case captured := <-dispatcher.packets:
			if captured.protocol != wantProtocol {
				t.Fatalf("captured protocol[%d] = %v want %v", index, captured.protocol, wantProtocol)
			}
		case <-time.After(time.Second):
			t.Fatalf("timed out waiting for injected packet %d", index)
		}
	}

	waitForDiagnosticEventCount(t, events, 3)
	gotEvents := events.Events()
	if len(gotEvents) != 3 {
		t.Fatalf("diagnostic event count = %d want 3; events=%#v", len(gotEvents), gotEvents)
	}
	if gotEvents[0].Kind != "tun.diagnostic" || gotEvents[0].Message != "tun.packet.read-loop-enter" || gotEvents[0].Protocol != "tun.packet.read-loop-enter" {
		t.Fatalf("first event = %#v want read-loop-enter diagnostic", gotEvents[0])
	}
	if gotEvents[1].Kind != "tun.diagnostic" || gotEvents[1].Message != "tun.packet.raw-read" || gotEvents[1].Protocol != "tun.packet.raw-read" {
		t.Fatalf("second event = %#v want raw-read diagnostic", gotEvents[1])
	}
	if gotEvents[2].Kind != "tun.diagnostic" || gotEvents[2].Message != "tun.packet.gvisor-inject" || gotEvents[2].Protocol != "tun.packet.gvisor-inject" {
		t.Fatalf("third event = %#v want gvisor-inject diagnostic", gotEvents[2])
	}
	for index, event := range gotEvents {
		if event.State != RuntimeRunning {
			t.Fatalf("event[%d].State = %v want %v", index, event.State, RuntimeRunning)
		}
		if event.SessionID != "session-diag" {
			t.Fatalf("event[%d].SessionID = %q want session-diag", index, event.SessionID)
		}
		if event.Ingress != "diagnostic" {
			t.Fatalf("event[%d].Ingress = %q want diagnostic", index, event.Ingress)
		}
		if len(event.TraceID) != 64 {
			t.Fatalf("event[%d].TraceID = %q want 64 lowercase hex", index, event.TraceID)
		}
	}
	if gotEvents[0].TraceID != hashHex("session-diag|tun.packet.read-loop-enter") {
		t.Fatalf("read-loop-enter TraceID = %q want session+stage hash", gotEvents[0].TraceID)
	}
	if gotEvents[1].TraceID != hashHex("session-diag|tun.packet.raw-read") {
		t.Fatalf("raw-read TraceID = %q want session+stage hash", gotEvents[1].TraceID)
	}
	if gotEvents[2].TraceID != hashHex("session-diag|tun.packet.gvisor-inject") {
		t.Fatalf("gvisor-inject TraceID = %q want session+stage hash", gotEvents[2].TraceID)
	}

	if traces := recorder.Traces(8); len(traces) != 0 {
		t.Fatalf("diagnostics should not append tun traces: %#v", traces)
	}
	if counters := recorder.Counters(); counters != (TunCounters{}) {
		t.Fatalf("diagnostics should not mutate counters: %#v", counters)
	}
}

func TestProductionTunFactoryDuplicatesABIFDAndClosesOnlyGoOwnedCopy(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatalf("Socketpair error: %v", err)
	}
	peerFD := fds[0]
	abiFD := fds[1]
	defer unix.Close(peerFD)
	defer unix.Close(abiFD)
	t.Cleanup(func() {
		resolver.RemoveSystemDnsBlacklist("10.111.222.2", "fd00:111:222::2")
	})

	recorder := &productionTunFactoryRecorder{
		tunCloseFn: unix.Close,
	}
	options := buildTunConfig(abiFD)

	listener, err := productionTunListenerFactoryWithDeps(recorder.realOwnershipDeps(), options, tunnel.Tunnel)
	if err != nil {
		t.Fatalf("productionTunListenerFactoryWithDeps error: %v", err)
	}
	goOwnedFD := recorder.tunOptions.FileDescriptor
	if goOwnedFD == abiFD {
		t.Fatalf("newTun fd = %d want duplicated fd distinct from ABI input %d", goOwnedFD, abiFD)
	}
	if !slices.Equal(recorder.dupInputs, []int{abiFD}) {
		t.Fatalf("dup inputs = %v want [%d]", recorder.dupInputs, abiFD)
	}
	if recorder.setNonblockFD != abiFD || !recorder.setNonblockValue {
		t.Fatalf("SetNonblock = (%d, %v) want (%d, true)", recorder.setNonblockFD, recorder.setNonblockValue, abiFD)
	}
	flags, err := unix.FcntlInt(uintptr(goOwnedFD), unix.F_GETFL, 0)
	if err != nil {
		t.Fatalf("F_GETFL duplicated fd: %v", err)
	}
	if flags&unix.O_NONBLOCK == 0 {
		t.Fatalf("duplicated fd flags = %#x want O_NONBLOCK set", flags)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("listener Close error: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("listener Close second error: %v", err)
	}
	if !slices.Equal(recorder.closedTunFDs, []int{goOwnedFD}) {
		t.Fatalf("closed tun fds = %v want [%d]", recorder.closedTunFDs, goOwnedFD)
	}
	assertFDOpen(t, abiFD)
	assertFDClosed(t, goOwnedFD)
}

func TestHarmonyGVisorTunListenerCloseUsesCapturedRemoveDNS(t *testing.T) {
	var removed []string
	listener := &harmonyTunListener{
		dnsServerIP: []string{"10.111.222.2", "fd00:111:222::2"},
		removeDNS: func(names ...string) {
			removed = append(removed, names...)
		},
	}

	if err := listener.Close(); err != nil {
		t.Fatalf("listener Close error: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("listener Close second error: %v", err)
	}
	if !slices.Equal(removed, []string{"10.111.222.2", "fd00:111:222::2"}) {
		t.Fatalf("removed dns = %v want %v", removed, []string{"10.111.222.2", "fd00:111:222::2"})
	}
}

func TestProductionTunFactoryUsesHarmonyPacketBridge(t *testing.T) {
	t.Cleanup(func() {
		resolver.RemoveSystemDnsBlacklist("10.111.222.2", "fd00:111:222::2")
	})
	recorder := &productionTunFactoryRecorder{
		nextDupFD: 601,
	}
	options := buildTunConfig(101)
	options.Device = "test-utun0"
	options.DNSHijack = []string{"any:53", "[fd00:111:222::9]:53"}
	additions := []adapterinbound.Addition{
		adapterinbound.WithInName("HARMONY-TUN"),
		adapterinbound.WithSpecialRules("rule-a"),
	}

	listener, err := productionTunListenerFactoryWithDeps(recorder.fakeDeps(), options, tunnel.Tunnel, additions...)
	if err != nil {
		t.Fatalf("productionTunListenerFactoryWithDeps error: %v", err)
	}
	harmonyListener, ok := listener.(*harmonyTunListener)
	if !ok {
		t.Fatalf("listener type = %T want *harmonyTunListener", listener)
	}
	if harmonyListener.bridge == nil {
		t.Fatal("listener bridge should not be nil")
	}
	if recorder.tunOptions.FileDescriptor == options.FileDescriptor {
		t.Fatalf("tun FileDescriptor = %d want duplicated fd distinct from ABI input %d", recorder.tunOptions.FileDescriptor, options.FileDescriptor)
	}
	if recorder.bridgeInputTun != recorder.tunDevice {
		t.Fatal("bridge should wrap tun returned by newTun")
	}
	if recorder.bridgeMTU != options.MTU {
		t.Fatalf("bridge MTU = %d want %d", recorder.bridgeMTU, options.MTU)
	}
	if recorder.stackOptions.Tun != harmonyListener.bridge {
		t.Fatalf("stack Tun = %T want harmony bridge", recorder.stackOptions.Tun)
	}
	handler, ok := recorder.stackOptions.Handler.(*mihomosingtun.ListenerHandler)
	if !ok {
		t.Fatalf("stack handler type = %T want *sing_tun.ListenerHandler", recorder.stackOptions.Handler)
	}
	wantDNS := []netip.AddrPort{
		netip.MustParseAddrPort("0.0.0.0:53"),
		netip.MustParseAddrPort("[fd00:111:222::9]:53"),
		netip.MustParseAddrPort("10.111.222.2:53"),
		netip.MustParseAddrPort("[fd00:111:222::2]:53"),
	}
	if !slices.Equal(handler.DnsAddrPorts, wantDNS) {
		t.Fatalf("DnsAddrPorts = %v want %v", handler.DnsAddrPorts, wantDNS)
	}
	if !slices.Equal(handler.Inet4Address, options.Inet4Address) {
		t.Fatalf("Inet4Address = %v want %v", handler.Inet4Address, options.Inet4Address)
	}
	if !slices.Equal(handler.Inet6Address, options.Inet6Address) {
		t.Fatalf("Inet6Address = %v want %v", handler.Inet6Address, options.Inet6Address)
	}
	metadata := &C.Metadata{}
	adapterinbound.ApplyAdditions(metadata, handler.Additions...)
	if metadata.InName != "HARMONY-TUN" || metadata.SpecialRules != "rule-a" {
		t.Fatalf("Additions mutated metadata = (%q, %q) want (%q, %q)", metadata.InName, metadata.SpecialRules, "HARMONY-TUN", "rule-a")
	}
	if recorder.stackOptions.UDPTimeout != sing.UDPTimeout {
		t.Fatalf("UDPTimeout = %v want %v", recorder.stackOptions.UDPTimeout, sing.UDPTimeout)
	}
	if recorder.stackOptions.ICMPTimeout != sing.ICMPTimeout {
		t.Fatalf("ICMPTimeout = %v want %v", recorder.stackOptions.ICMPTimeout, sing.ICMPTimeout)
	}
	if !resolver.IsSystemDnsBlacklisted("10.111.222.2", "fd00:111:222::2") {
		t.Fatal("expected dns blacklist to be installed")
	}
	if got := listener.Address(); got != harmonyTunListenerAddress {
		t.Fatalf("Address = %q want %q", got, harmonyTunListenerAddress)
	}
	for _, forbidden := range []string{
		fmt.Sprint(options.FileDescriptor),
		options.Inet4Address[0].Addr().String(),
		options.Inet6Address[0].Addr().String(),
		"session",
		"profile",
	} {
		if strings.Contains(listener.Address(), forbidden) {
			t.Fatalf("Address should not contain %q: %q", forbidden, listener.Address())
		}
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("listener Close error: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("listener Close second error: %v", err)
	}
	wantEvents := []string{"dns-add", "stack-start", "stack-close", "tun-close", "dns-remove"}
	if !slices.Equal(recorder.events, wantEvents) {
		t.Fatalf("events = %v want %v", recorder.events, wantEvents)
	}
	if resolver.IsSystemDnsBlacklisted("10.111.222.2", "fd00:111:222::2") {
		t.Fatal("expected dns blacklist to be removed")
	}
}

func TestProductionTunFactoryReturnsFixedErrorWhenDupFails(t *testing.T) {
	recorder := &productionTunFactoryRecorder{
		dupErr: errors.New("dup failed"),
	}
	_, err := productionTunListenerFactoryWithDeps(recorder.fakeDeps(), buildTunConfig(102), tunnel.Tunnel)
	if !errors.Is(err, errTunFDDuplicate) {
		t.Fatalf("productionTunListenerFactoryWithDeps error = %v want %v", err, errTunFDDuplicate)
	}
	if len(recorder.closeFDCalls) != 0 || len(recorder.closedTunFDs) != 0 {
		t.Fatalf("unexpected closes after dup failure: closeFD=%v tunClose=%v", recorder.closeFDCalls, recorder.closedTunFDs)
	}
}

func TestProductionTunFactoryClosesOnlyDuplicatedFDWhenNewTunFails(t *testing.T) {
	recorder := &productionTunFactoryRecorder{
		nextDupFD: 777,
		newTunErr: errors.New("new tun failed"),
	}
	_, err := productionTunListenerFactoryWithDeps(recorder.fakeDeps(), buildTunConfig(103), tunnel.Tunnel)
	if !errors.Is(err, recorder.newTunErr) {
		t.Fatalf("productionTunListenerFactoryWithDeps error = %v want %v", err, recorder.newTunErr)
	}
	if !slices.Equal(recorder.closeFDCalls, []int{777}) {
		t.Fatalf("closeFD calls = %v want [777]", recorder.closeFDCalls)
	}
	if len(recorder.closedTunFDs) != 0 {
		t.Fatalf("unexpected tun closes = %v", recorder.closedTunFDs)
	}
}

func TestProductionTunFactoryNewGVisorFailureClosesBridgeOnce(t *testing.T) {
	t.Cleanup(func() {
		resolver.RemoveSystemDnsBlacklist("10.111.222.2", "fd00:111:222::2")
	})
	recorder := &productionTunFactoryRecorder{
		nextDupFD:    701,
		newGVisorErr: errors.New("new-gvisor-failed"),
	}
	_, err := productionTunListenerFactoryWithDeps(recorder.fakeDeps(), buildTunConfig(104), tunnel.Tunnel)
	if !errors.Is(err, recorder.newGVisorErr) {
		t.Fatalf("productionTunListenerFactoryWithDeps error = %v want %v", err, recorder.newGVisorErr)
	}
	wantEvents := []string{"dns-add", "tun-close", "dns-remove"}
	if !slices.Equal(recorder.events, wantEvents) {
		t.Fatalf("events = %v want %v", recorder.events, wantEvents)
	}
	if !slices.Equal(recorder.closedTunFDs, []int{701}) {
		t.Fatalf("closed tun fds = %v want [701]", recorder.closedTunFDs)
	}
}

func TestProductionTunFactoryStartFailureClosesStackBeforeBridge(t *testing.T) {
	t.Cleanup(func() {
		resolver.RemoveSystemDnsBlacklist("10.111.222.2", "fd00:111:222::2")
	})
	recorder := &productionTunFactoryRecorder{
		nextDupFD: 702,
		startErr:  errors.New("stack-start-failed"),
	}
	_, err := productionTunListenerFactoryWithDeps(recorder.fakeDeps(), buildTunConfig(105), tunnel.Tunnel)
	if !errors.Is(err, recorder.startErr) {
		t.Fatalf("productionTunListenerFactoryWithDeps error = %v want %v", err, recorder.startErr)
	}
	wantEvents := []string{"dns-add", "stack-start", "stack-close", "tun-close", "dns-remove"}
	if !slices.Equal(recorder.events, wantEvents) {
		t.Fatalf("events = %v want %v", recorder.events, wantEvents)
	}
}

type productionTunFactoryRecorder struct {
	events           []string
	setNonblockFD    int
	setNonblockValue bool
	dupInputs        []int
	dupOutputs       []int
	closeFDCalls     []int
	closedTunFDs     []int
	tunOptions       stun.Options
	tunDevice        *recordingTun
	bridgeInputTun   stun.Tun
	bridgeMTU        uint32
	stackOptions     stun.StackOptions
	nextDupFD        int
	dupErr           error
	newTunErr        error
	newGVisorErr     error
	startErr         error
	tunCloseFn       func(int) error
}

type recordingTun struct {
	fd       int
	recorder *productionTunFactoryRecorder
	closeFn  func(int) error
}

type transientReadTun struct {
	mu        sync.Mutex
	readCount int
	packet    []byte
	closed    chan struct{}
	closeOnce sync.Once
}

type fatalReadTun struct {
	err error
}

type interruptedReadTun struct {
	mu        sync.Mutex
	readCount int
	packet    []byte
	closed    chan struct{}
	closeOnce sync.Once
}

type closeUnblocksReadTun struct {
	closed    chan struct{}
	closeOnce sync.Once
}

func (t *fatalReadTun) Read([]byte) (int, error) {
	return 0, t.err
}

func (*fatalReadTun) Write(packet []byte) (int, error) {
	return len(packet), nil
}

func (*fatalReadTun) Close() error {
	return nil
}

func (t *interruptedReadTun) Read(packet []byte) (int, error) {
	t.mu.Lock()
	t.readCount++
	readCount := t.readCount
	t.mu.Unlock()
	if readCount == 1 {
		return 0, unix.EINTR
	}
	if readCount == 2 {
		return copy(packet, t.packet), nil
	}
	<-t.closed
	return 0, os.ErrClosed
}

func (*interruptedReadTun) Write(packet []byte) (int, error) {
	return len(packet), nil
}

func (t *interruptedReadTun) Close() error {
	t.closeOnce.Do(func() {
		close(t.closed)
	})
	return nil
}

func (t *closeUnblocksReadTun) Read([]byte) (int, error) {
	<-t.closed
	return 0, os.ErrClosed
}

func (*closeUnblocksReadTun) Write(packet []byte) (int, error) {
	return len(packet), nil
}

func (t *closeUnblocksReadTun) Close() error {
	t.closeOnce.Do(func() {
		close(t.closed)
	})
	return nil
}

func waitForDiagnosticEventCount(t *testing.T, events *recordingSink, want int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for len(events.Events()) < want {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %d diagnostic events; got %#v", want, events.Events())
		}
		time.Sleep(time.Millisecond)
	}
}

func (t *transientReadTun) Read(packet []byte) (int, error) {
	t.mu.Lock()
	t.readCount++
	readCount := t.readCount
	t.mu.Unlock()
	if readCount == 1 {
		return 0, unix.EAGAIN
	}
	if readCount == 2 {
		return copy(packet, t.packet), nil
	}
	<-t.closed
	return 0, os.ErrClosed
}

func (t *transientReadTun) Write(packet []byte) (int, error) {
	return len(packet), nil
}

func (t *transientReadTun) Close() error {
	t.closeOnce.Do(func() {
		close(t.closed)
	})
	return nil
}

func (t *recordingTun) Read(packet []byte) (int, error) {
	return 0, os.ErrClosed
}

func (t *recordingTun) Write(packet []byte) (int, error) {
	return len(packet), nil
}

func (t *recordingTun) Close() error {
	t.recorder.events = append(t.recorder.events, "tun-close")
	t.recorder.closedTunFDs = append(t.recorder.closedTunFDs, t.fd)
	if t.closeFn != nil {
		return t.closeFn(t.fd)
	}
	return nil
}

type recordingStack struct {
	recorder *productionTunFactoryRecorder
	startErr error
}

func (s *recordingStack) Start() error {
	s.recorder.events = append(s.recorder.events, "stack-start")
	return s.startErr
}

func (s *recordingStack) Close() error {
	s.recorder.events = append(s.recorder.events, "stack-close")
	return nil
}

func (r *productionTunFactoryRecorder) fakeDeps() productionTunFactoryDeps {
	return productionTunFactoryDeps{
		setNonblock: r.recordSetNonblock,
		dupFD:       r.recordDup,
		closeFD:     r.recordCloseFD,
		newTun:      r.recordNewTun,
		newBridge:   r.recordNewBridge,
		newGVisor:   r.recordNewGVisor,
		addDNS:      r.recordAddDNS,
		removeDNS:   r.recordRemoveDNS,
	}
}

func (r *productionTunFactoryRecorder) realOwnershipDeps() productionTunFactoryDeps {
	deps := r.fakeDeps()
	deps.setNonblock = func(fd int, value bool) error {
		if err := r.recordSetNonblock(fd, value); err != nil {
			return err
		}
		return unix.SetNonblock(fd, value)
	}
	deps.dupFD = func(fd int) (int, error) {
		r.dupInputs = append(r.dupInputs, fd)
		dupFD, err := unix.Dup(fd)
		if err == nil {
			r.dupOutputs = append(r.dupOutputs, dupFD)
		}
		return dupFD, err
	}
	return deps
}

func (r *productionTunFactoryRecorder) recordSetNonblock(fd int, value bool) error {
	r.setNonblockFD = fd
	r.setNonblockValue = value
	return nil
}

func (r *productionTunFactoryRecorder) recordDup(fd int) (int, error) {
	r.dupInputs = append(r.dupInputs, fd)
	if r.dupErr != nil {
		return -1, r.dupErr
	}
	dupFD := r.nextDupFD
	if dupFD == 0 {
		dupFD = fd + 1000
	}
	r.dupOutputs = append(r.dupOutputs, dupFD)
	return dupFD, nil
}

func (r *productionTunFactoryRecorder) recordCloseFD(fd int) error {
	r.closeFDCalls = append(r.closeFDCalls, fd)
	return nil
}

func (r *productionTunFactoryRecorder) recordNewTun(options stun.Options) (stun.Tun, error) {
	r.tunOptions = options
	if r.newTunErr != nil {
		return nil, r.newTunErr
	}
	r.tunDevice = &recordingTun{
		fd:       options.FileDescriptor,
		recorder: r,
		closeFn:  r.tunCloseFn,
	}
	return r.tunDevice, nil
}

func (r *productionTunFactoryRecorder) recordNewBridge(tunDevice stun.Tun, mtu uint32) *harmonyGVisorTun {
	r.bridgeInputTun = tunDevice
	r.bridgeMTU = mtu
	return newHarmonyGVisorTun(tunDevice, mtu)
}

func (r *productionTunFactoryRecorder) recordNewGVisor(options stun.StackOptions) (stun.Stack, error) {
	r.stackOptions = options
	if r.newGVisorErr != nil {
		return nil, r.newGVisorErr
	}
	return &recordingStack{recorder: r, startErr: r.startErr}, nil
}

func (r *productionTunFactoryRecorder) recordAddDNS(names ...string) {
	r.events = append(r.events, "dns-add")
	resolver.AddSystemDnsBlacklist(names...)
}

func (r *productionTunFactoryRecorder) recordRemoveDNS(names ...string) {
	r.events = append(r.events, "dns-remove")
	resolver.RemoveSystemDnsBlacklist(names...)
}

func assertFDOpen(t *testing.T, fd int) {
	t.Helper()
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
		t.Fatalf("fd %d should remain open: %v", fd, err)
	}
}

func assertFDClosed(t *testing.T, fd int) {
	t.Helper()
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err == nil {
		t.Fatalf("fd %d should be closed", fd)
	}
}
