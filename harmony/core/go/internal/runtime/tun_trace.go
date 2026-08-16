package runtime

import (
	"crypto/sha256"
	"encoding/hex"
	"net"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

var flowMarkerPattern = regexp.MustCompile(`cmfa-[A-Za-z0-9._:-]+`)
const controlledProbeHost = "controlled.invalid"

type tunTraceRecorder struct {
	sessionID string
	events    EventSink

	mu       sync.Mutex
	traces   []TunTrace
	next     int
	full     bool
	sequence uint64
	counters TunCounters
}

func newTunTraceRecorder(sessionID string, events EventSink, capacity int) *tunTraceRecorder {
	if capacity <= 0 {
		capacity = 1
	}
	if events == nil {
		events = DiscardEvents{}
	}
	return &tunTraceRecorder{
		sessionID: sessionID,
		events:    events,
		traces:    make([]TunTrace, capacity),
	}
}

func (r *tunTraceRecorder) Wrap(delegate C.Tunnel) C.Tunnel {
	wrapped := tracedTunTunnel{
		delegate: delegate,
		recorder: r,
	}
	if providerTunnel, ok := delegate.(P.Tunnel); ok {
		return tracedProviderTunnel{
			tracedTunTunnel: wrapped,
			providerTunnel:  providerTunnel,
		}
	}
	return wrapped
}

func (r *tunTraceRecorder) Traces(limit int) []TunTrace {
	r.mu.Lock()
	defer r.mu.Unlock()

	total := r.lenLocked()
	if limit <= 0 || limit > total {
		limit = total
	}
	if limit == 0 {
		return nil
	}
	start := total - limit
	cloned := make([]TunTrace, 0, limit)
	for index := start; index < total; index += 1 {
		cloned = append(cloned, r.atLocked(index))
	}
	return cloned
}

func (r *tunTraceRecorder) Counters() TunCounters {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.counters
}

func (r *tunTraceRecorder) lenLocked() int {
	if r.full {
		return len(r.traces)
	}
	return r.next
}

func (r *tunTraceRecorder) atLocked(index int) TunTrace {
	if !r.full {
		return r.traces[index]
	}
	return r.traces[(r.next+index)%len(r.traces)]
}

func (r *tunTraceRecorder) appendTrace(protocol string, metadata *C.Metadata, bytes uint64, correlationHash string) TunTrace {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.sequence += 1
	r.counters.RXPackets += 1
	r.counters.RXBytes += bytes

	trace := TunTrace{
		SessionID:       r.sessionID,
		Ingress:         "tun",
		Protocol:        protocol,
		HashedTuple:     hashHex(tupleFingerprint(protocol, metadata)),
		CorrelationHash: correlationHash,
	}
	trace.TraceID = hashHex(strings.Join([]string{
		r.sessionID,
		trace.Protocol,
		trace.HashedTuple,
		correlationHash,
		strconv.FormatUint(r.sequence, 10),
	}, "|"))

	r.traces[r.next] = trace
	r.next = (r.next + 1) % len(r.traces)
	if r.next == 0 {
		r.full = true
	}

	r.events.Publish(RuntimeEvent{
		Kind:      "tun.ingress",
		State:     RuntimeRunning,
		Message:   protocol,
		TraceID:   trace.TraceID,
		SessionID: trace.SessionID,
		Ingress:   trace.Ingress,
		Protocol:  trace.Protocol,
	})
	return trace
}

func tupleFingerprint(protocol string, metadata *C.Metadata) string {
	if metadata == nil {
		return protocol
	}
	parts := []string{
		protocol,
		metadata.SrcIP.String(),
		strconv.FormatUint(uint64(metadata.SrcPort), 10),
		metadata.DstIP.String(),
		strconv.FormatUint(uint64(metadata.DstPort), 10),
	}
	return strings.Join(parts, "|")
}

func hashHex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func hashBytesHex(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

type tracedTunTunnel struct {
	delegate C.Tunnel
	recorder *tunTraceRecorder
}

func (t tracedTunTunnel) HandleTCPConn(conn net.Conn, metadata *C.Metadata) {
	tapped := &tapConn{Conn: conn}
	t.delegate.HandleTCPConn(tapped, metadata)
	protocol := "tcp"
	correlationHash := markerHash(metadata, tapped.peek())
	if isDNSMetadata(metadata) {
		protocol = "dns"
		correlationHash = hashBytesHex(tapped.peek())
	}
	t.recorder.appendTrace(protocol, metadata, tapped.bytesRead, correlationHash)
}

func (t tracedTunTunnel) HandleUDPPacket(packet C.UDPPacket, metadata *C.Metadata) {
	payload := packet.Data()
	protocol := "udp"
	correlationHash := markerHash(metadata, payload)
	if isDNSMetadata(metadata) {
		protocol = "dns"
		correlationHash = hashBytesHex(payload)
	}
	t.recorder.appendTrace(protocol, metadata, uint64(len(payload)), correlationHash)
	t.delegate.HandleUDPPacket(packet, metadata)
}

func (t tracedTunTunnel) NatTable() C.NatTable {
	return t.delegate.NatTable()
}

type tracedProviderTunnel struct {
	tracedTunTunnel
	providerTunnel P.Tunnel
}

func (t tracedProviderTunnel) Providers() map[string]P.ProxyProvider {
	return t.providerTunnel.Providers()
}

func (t tracedProviderTunnel) RuleProviders() map[string]P.RuleProvider {
	return t.providerTunnel.RuleProviders()
}

func (t tracedProviderTunnel) RuleUpdateCallback() *utils.Callback[P.RuleProvider] {
	return t.providerTunnel.RuleUpdateCallback()
}

type tapConn struct {
	net.Conn
	bytesRead uint64
	buffer    []byte
}

func (c *tapConn) Read(target []byte) (int, error) {
	n, err := c.Conn.Read(target)
	if n > 0 {
		c.bytesRead += uint64(n)
		if len(c.buffer) < 4096 {
			remaining := 4096 - len(c.buffer)
			if remaining > n {
				remaining = n
			}
			c.buffer = append(c.buffer, target[:remaining]...)
		}
	}
	return n, err
}

func (c *tapConn) peek() []byte {
	return append([]byte(nil), c.buffer...)
}

func markerHash(metadata *C.Metadata, payload []byte) string {
	if metadata == nil || !strings.EqualFold(strings.TrimSpace(metadata.Host), controlledProbeHost) {
		return ""
	}
	marker := flowMarkerPattern.Find(payload)
	if len(marker) == 0 {
		return ""
	}
	return hashBytesHex(marker)
}

func isDNSMetadata(metadata *C.Metadata) bool {
	return metadata != nil && metadata.DstPort == 53
}
