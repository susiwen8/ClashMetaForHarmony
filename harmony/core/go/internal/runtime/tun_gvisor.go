//go:build with_gvisor

package runtime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	adapterinbound "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing"
	mihomosingtun "github.com/metacubex/mihomo/listener/sing_tun"
	stun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

const harmonyTunPacketCapacity = 65535
const harmonyTunListenerAddress = "harmony-gvisor-tun"
const harmonyTunEndpointEnterStage = "tun.listener.endpoint-enter"
const harmonyTunPacketReadLoopEnterStage = "tun.packet.read-loop-enter"
const harmonyTunPacketReadWouldBlockStage = "tun.packet.read-would-block"
const harmonyTunPacketReadFailedStage = "tun.packet.read-failed"
const harmonyTunPacketRawReadStage = "tun.packet.raw-read"
const harmonyTunPacketGVisorInjectStage = "tun.packet.gvisor-inject"

var errTunFDDuplicate = errors.New("tun fd duplicate failed")

type productionTunFactoryDeps struct {
	setNonblock func(fd int, nonblocking bool) error
	dupFD       func(fd int) (int, error)
	closeFD     func(fd int) error
	newTun      func(options stun.Options) (stun.Tun, error)
	newBridge   func(tunDevice stun.Tun, mtu uint32) *harmonyGVisorTun
	newGVisor   func(options stun.StackOptions) (stun.Stack, error)
	addDNS      func(...string)
	removeDNS   func(...string)
}

type harmonyGVisorTun struct {
	tun        stun.Tun
	mtu        uint32
	ctx        context.Context
	cancel     context.CancelFunc
	mu         sync.Mutex
	endpoint   *channel.Endpoint
	reporter   tunPacketDiagnosticReporter
	readLoop   sync.Once
	wouldBlock sync.Once
	readFailed sync.Once
	rawRead    sync.Once
	inject     sync.Once
	closeOnce  sync.Once
	wg         sync.WaitGroup
	closeErr   error
}

type harmonyFDTun struct {
	fd        int
	closeOnce sync.Once
	closeErr  error
}

type harmonyTunListener struct {
	stack       stun.Stack
	bridge      *harmonyGVisorTun
	dnsServerIP []string
	removeDNS   func(...string)
	closeOnce   sync.Once
	closeErr    error
}

func newHarmonyGVisorTun(tunDevice stun.Tun, mtu uint32) *harmonyGVisorTun {
	ctx, cancel := context.WithCancel(context.Background())
	return &harmonyGVisorTun{
		tun:    tunDevice,
		mtu:    mtu,
		ctx:    ctx,
		cancel: cancel,
	}
}

func newHarmonyFDTun(options stun.Options) (stun.Tun, error) {
	if options.FileDescriptor <= 0 {
		return nil, errTunFDRequired
	}
	return &harmonyFDTun{fd: options.FileDescriptor}, nil
}

func (t *harmonyFDTun) Read(packet []byte) (int, error) {
	return unix.Read(t.fd, packet)
}

func (t *harmonyFDTun) Write(packet []byte) (int, error) {
	return unix.Write(t.fd, packet)
}

func (t *harmonyFDTun) Close() error {
	t.closeOnce.Do(func() {
		t.closeErr = unix.Close(t.fd)
	})
	return t.closeErr
}

func (t *harmonyGVisorTun) Read(packet []byte) (int, error) {
	return t.tun.Read(packet)
}

func (t *harmonyGVisorTun) Write(packet []byte) (int, error) {
	return t.tun.Write(packet)
}

func (t *harmonyGVisorTun) WritePacket(packet *stack.PacketBuffer) (int, error) {
	views := packet.AsSlices()
	total := 0
	for _, view := range views {
		total += len(view)
	}
	payload := make([]byte, total)
	offset := 0
	for _, view := range views {
		offset += copy(payload[offset:], view)
	}
	written, err := t.tun.Write(payload)
	if err == nil && written != len(payload) {
		err = io.ErrShortWrite
	}
	return written, err
}

func (t *harmonyGVisorTun) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.endpoint != nil {
		return nil, stack.NICOptions{}, errors.New("HarmonyOS TUN endpoint already created")
	}
	t.reportLifecycleDiagnostic(harmonyTunEndpointEnterStage)
	endpoint := channel.New(1024, t.mtu, "")
	t.endpoint = endpoint
	t.wg.Add(2)
	go t.readInbound(endpoint)
	go t.writeOutbound(endpoint)
	return endpoint, stack.NICOptions{}, nil
}

func (t *harmonyGVisorTun) reportLifecycleDiagnostic(stage string) {
	if t.reporter != nil {
		t.reporter.reportTunLifecycleDiagnostic(stage)
	}
}

func (t *harmonyGVisorTun) readInbound(endpoint *channel.Endpoint) {
	defer t.wg.Done()
	t.reportPacketDiagnostic(&t.readLoop, harmonyTunPacketReadLoopEnterStage)
	packetBuffer := make([]byte, harmonyTunPacketCapacity)
	const transientReadRetryDelay = 5 * time.Millisecond
	for {
		n, err := t.tun.Read(packetBuffer)
		if err != nil {
			switch {
			case errors.Is(err, unix.EINTR):
				continue
			case errors.Is(err, unix.EAGAIN), errors.Is(err, unix.EWOULDBLOCK):
				t.reportPacketDiagnostic(&t.wouldBlock, harmonyTunPacketReadWouldBlockStage)
				select {
				case <-t.ctx.Done():
					return
				case <-time.After(transientReadRetryDelay):
				}
				continue
			default:
				select {
				case <-t.ctx.Done():
					return
				default:
					t.reportPacketDiagnostic(&t.readFailed, harmonyTunPacketReadFailedStage)
				}
				return
			}
		}
		if n == 0 {
			continue
		}
		t.reportPacketDiagnostic(&t.rawRead, harmonyTunPacketRawReadStage)
		var protocol tcpip.NetworkProtocolNumber
		switch packetBuffer[0] >> 4 {
		case header.IPv4Version:
			protocol = header.IPv4ProtocolNumber
		case header.IPv6Version:
			protocol = header.IPv6ProtocolNumber
		default:
			continue
		}
		payload := append([]byte(nil), packetBuffer[:n]...)
		packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(payload)})
		endpoint.InjectInbound(protocol, packet)
		t.reportPacketDiagnostic(&t.inject, harmonyTunPacketGVisorInjectStage)
		packet.DecRef()
	}
}

func (t *harmonyGVisorTun) reportPacketDiagnostic(once *sync.Once, stage string) {
	if t.reporter == nil {
		return
	}
	once.Do(func() {
		t.reporter.reportTunPacketDiagnostic(stage)
	})
}

func (t *harmonyGVisorTun) writeOutbound(endpoint *channel.Endpoint) {
	defer t.wg.Done()
	for {
		packet := endpoint.ReadContext(t.ctx)
		if packet == nil {
			return
		}
		_, _ = t.WritePacket(packet)
		packet.DecRef()
	}
}

func (t *harmonyGVisorTun) Close() error {
	t.closeOnce.Do(func() {
		t.cancel()
		t.mu.Lock()
		endpoint := t.endpoint
		t.mu.Unlock()
		if endpoint != nil {
			endpoint.Close()
		}
		t.closeErr = t.tun.Close()
		t.wg.Wait()
	})
	return t.closeErr
}

func productionTunListenerFactory(options LC.Tun, tunnel C.Tunnel, additions ...adapterinbound.Addition) (_ TunListenerHandle, err error) {
	return productionTunListenerFactoryWithDeps(defaultProductionTunFactoryDeps(), options, tunnel, additions...)
}

func defaultProductionTunFactoryDeps() productionTunFactoryDeps {
	return productionTunFactoryDeps{
		setNonblock: unix.SetNonblock,
		dupFD:       unix.Dup,
		closeFD:     unix.Close,
		newTun:      newHarmonyFDTun,
		newBridge:   newHarmonyGVisorTun,
		newGVisor:   stun.NewGVisor,
		addDNS:      resolver.AddSystemDnsBlacklist,
		removeDNS:   resolver.RemoveSystemDnsBlacklist,
	}
}

func productionTunListenerFactoryWithDeps(
	deps productionTunFactoryDeps,
	options LC.Tun,
	tunnel C.Tunnel,
	additions ...adapterinbound.Addition,
) (_ TunListenerHandle, err error) {
	if options.FileDescriptor <= 0 {
		return nil, errTunFDRequired
	}
	if err = deps.setNonblock(options.FileDescriptor, true); err != nil {
		return nil, fmt.Errorf("setnonblock: %w", err)
	}
	goOwnedFD, err := deps.dupFD(options.FileDescriptor)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errTunFDDuplicate, err)
	}

	tunMTU := options.MTU
	if tunMTU == 0 {
		tunMTU = 9000
	}

	tunOptions := stun.Options{
		Name:           options.Device,
		MTU:            tunMTU,
		GSO:            options.GSO,
		Inet4Address:   options.Inet4Address,
		Inet6Address:   options.Inet6Address,
		FileDescriptor: goOwnedFD,
		EXP_RecvMsgX:   options.RecvMsgX,
		EXP_SendMsgX:   options.SendMsgX,
	}
	tunIf, err := deps.newTun(tunOptions)
	if err != nil {
		_ = deps.closeFD(goOwnedFD)
		return nil, fmt.Errorf("configure tun interface: %w", err)
	}

	bridge := deps.newBridge(tunIf, tunMTU)
	if reporter, ok := tunnel.(tunPacketDiagnosticReporter); ok {
		bridge.reporter = reporter
	}
	listener := &harmonyTunListener{
		bridge:    bridge,
		removeDNS: deps.removeDNS,
	}
	defer func() {
		if err != nil {
			_ = listener.Close()
		}
	}()

	dnsAddrPorts, dnsServerIP, err := buildHarmonyDNSConfig(options)
	if err != nil {
		return nil, err
	}

	handler, err := newHarmonyGVisorHandler(options, tunnel, additions, dnsAddrPorts)
	if err != nil {
		return nil, err
	}

	listener.dnsServerIP = dnsServerIP
	deps.addDNS(dnsServerIP...)

	stackOptions := stun.StackOptions{
		Context:                context.TODO(),
		Tun:                    bridge,
		TunOptions:             tunOptions,
		EndpointIndependentNat: options.EndpointIndependentNat,
		UDPTimeout:             resolveHarmonyTunTimeout(options.UDPTimeout, sing.UDPTimeout),
		ICMPTimeout:            resolveHarmonyTunTimeout(options.ICMPTimeout, sing.ICMPTimeout),
		Handler:                handler,
	}
	listener.stack, err = deps.newGVisor(stackOptions)
	if err != nil {
		return nil, err
	}
	if err = listener.stack.Start(); err != nil {
		return nil, err
	}
	return listener, nil
}

func newHarmonyGVisorHandler(
	options LC.Tun,
	tunnel C.Tunnel,
	additions []adapterinbound.Addition,
	dnsAddrPorts []netip.AddrPort,
) (*mihomosingtun.ListenerHandler, error) {
	if len(additions) == 0 {
		additions = []adapterinbound.Addition{
			adapterinbound.WithInName("DEFAULT-TUN"),
			adapterinbound.WithSpecialRules(""),
		}
	}
	handler, err := sing.NewListenerHandler(sing.ListenerConfig{
		Tunnel:    tunnel,
		Type:      C.TUN,
		Additions: additions,
	})
	if err != nil {
		return nil, err
	}
	return &mihomosingtun.ListenerHandler{
		ListenerHandler:       handler,
		DnsAddrPorts:          dnsAddrPorts,
		Inet4Address:          options.Inet4Address,
		Inet6Address:          options.Inet6Address,
		DisableICMPForwarding: options.DisableICMPForwarding,
	}, nil
}

func buildHarmonyDNSConfig(options LC.Tun) ([]netip.AddrPort, []string, error) {
	var (
		dnsAddrPorts []netip.AddrPort
		dnsServerIP  []string
	)
	for _, raw := range options.DNSHijack {
		value := raw
		if _, after, ok := strings.Cut(value, "://"); ok {
			value = after
		}
		value = strings.Replace(value, "any", "0.0.0.0", 1)
		addrPort, err := netip.ParseAddrPort(value)
		if err != nil {
			return nil, nil, errors.New("parse dns-hijack")
		}
		dnsAddrPorts = append(dnsAddrPorts, addrPort)
	}
	for _, prefix := range options.Inet4Address {
		serverIP := prefix.Addr().Next()
		dnsServerIP = append(dnsServerIP, serverIP.String())
		dnsAddrPorts = append(dnsAddrPorts, netip.AddrPortFrom(serverIP, 53))
	}
	for _, prefix := range options.Inet6Address {
		serverIP := prefix.Addr().Next()
		dnsServerIP = append(dnsServerIP, serverIP.String())
		dnsAddrPorts = append(dnsAddrPorts, netip.AddrPortFrom(serverIP, 53))
	}
	return dnsAddrPorts, dnsServerIP, nil
}

func resolveHarmonyTunTimeout(value int64, fallback time.Duration) time.Duration {
	if value == 0 {
		return fallback
	}
	return time.Second * time.Duration(value)
}

func (l *harmonyTunListener) Close() error {
	l.closeOnce.Do(func() {
		if l.stack != nil {
			l.closeErr = l.stack.Close()
		}
		if l.bridge != nil {
			if err := l.bridge.Close(); l.closeErr == nil {
				l.closeErr = err
			}
		}
		if l.removeDNS != nil {
			l.removeDNS(l.dnsServerIP...)
		}
	})
	return l.closeErr
}

func (*harmonyTunListener) Address() string {
	return harmonyTunListenerAddress
}
