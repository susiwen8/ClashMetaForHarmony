package runtime

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var flowMarkerPattern = regexp.MustCompile(`cmfa-[A-Za-z0-9._:-]+`)
var probeUUIDMarkerPattern = regexp.MustCompile(`cmfa-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}`)

var tunTraceTrackerRange = func(yield func(statistic.Tracker) bool) {
	statistic.DefaultManager.Range(yield)
}

var tunTraceOutboundProofLookup func(*C.Metadata) tunOutboundProof
var tunTraceResolverNow = time.Now
var tunTraceResolverTimeout = 1500 * time.Millisecond
var tunTraceResolverWait = func(ctx context.Context) bool {
	timer := time.NewTimer(5 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
var tunTraceResolverMaxConcurrent = 16
var tunTraceResolverOnStart = func() {}
var tunTraceResolverOnDone = func() {}

const tunTraceMaxCandidateBytes = 4096

type tunPacketDiagnosticReporter interface {
	reportTunPacketDiagnostic(stage string)
	reportTunLifecycleDiagnostic(stage string)
}

type tunTraceRecorder struct {
	sessionID            string
	events               EventSink
	packetDiagnosticSink func(stage string)
	outboundLookup       func(*C.Metadata) tunOutboundProof
	resolverNow          func() time.Time
	resolverWait         func(context.Context) bool
	resolverTimeout      time.Duration
	resolverOnStart      func()
	resolverOnDone       func()

	mu            sync.Mutex
	traces        []TunTrace
	next          int
	full          bool
	sequence      uint64
	counters      TunCounters
	resolverSlots chan struct{}
}

type tunOutboundProof struct {
	terminalHash string
	chainHash    string
	chainLength  uint32
}

type tcpTraceCandidateState uint8

const (
	tcpTraceCandidateCollecting tcpTraceCandidateState = iota
	tcpTraceCandidateDelegateFinalizing
	tcpTraceCandidateResolving
	tcpTraceCandidateCommitted
	tcpTraceCandidateClosed
)

type tcpTraceCandidate struct {
	recorder *tunTraceRecorder
	metadata *C.Metadata
	tapped   *tapConn

	mu       sync.Mutex
	state    tcpTraceCandidateState
	done     chan struct{}
	doneOnce sync.Once
}

func newTunTraceRecorder(sessionID string, events EventSink, capacity int) *tunTraceRecorder {
	if capacity <= 0 {
		capacity = 1
	}
	if events == nil {
		events = DiscardEvents{}
	}
	outboundLookup := tunTraceOutboundProofLookup
	if outboundLookup == nil {
		outboundLookup = makeTunTraceOutboundProofLookup(tunTraceTrackerRange)
	}
	resolverNow := tunTraceResolverNow
	if resolverNow == nil {
		resolverNow = time.Now
	}
	resolverWait := tunTraceResolverWait
	if resolverWait == nil {
		resolverWait = func(ctx context.Context) bool {
			timer := time.NewTimer(5 * time.Millisecond)
			defer timer.Stop()
			select {
			case <-ctx.Done():
				return false
			case <-timer.C:
				return true
			}
		}
	}
	resolverTimeout := tunTraceResolverTimeout
	if resolverTimeout <= 0 {
		resolverTimeout = 1500 * time.Millisecond
	}
	resolverOnStart := tunTraceResolverOnStart
	if resolverOnStart == nil {
		resolverOnStart = func() {}
	}
	resolverOnDone := tunTraceResolverOnDone
	if resolverOnDone == nil {
		resolverOnDone = func() {}
	}
	resolverMaxConcurrent := tunTraceResolverMaxConcurrent
	if resolverMaxConcurrent <= 0 {
		resolverMaxConcurrent = 16
	}
	return &tunTraceRecorder{
		sessionID:       sessionID,
		events:          events,
		outboundLookup:  outboundLookup,
		resolverNow:     resolverNow,
		resolverWait:    resolverWait,
		resolverTimeout: resolverTimeout,
		resolverOnStart: resolverOnStart,
		resolverOnDone:  resolverOnDone,
		traces:          make([]TunTrace, capacity),
		resolverSlots:   make(chan struct{}, resolverMaxConcurrent),
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

func (r *tunTraceRecorder) appendTrace(
	protocol string,
	metadata *C.Metadata,
	bytes uint64,
	correlationHash string,
	outbound tunOutboundProof,
) TunTrace {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.sequence += 1
	r.counters.RXPackets += 1
	r.counters.RXBytes += bytes

	trace := TunTrace{
		SessionID:            r.sessionID,
		Ingress:              "tun",
		Protocol:             protocol,
		HashedTuple:          hashHex(tupleFingerprint(protocol, metadata)),
		CorrelationHash:      correlationHash,
		DestinationHash:      destinationHash(protocol, metadata),
		OutboundTerminalHash: outbound.terminalHash,
		OutboundChainHash:    outbound.chainHash,
		OutboundChainLength:  outbound.chainLength,
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

	r.publishTraceEvent(trace)
	return trace
}

func (r *tunTraceRecorder) publishTraceEvent(trace TunTrace) {
	r.events.Publish(RuntimeEvent{
		Kind:      "tun.ingress",
		State:     RuntimeRunning,
		Message:   trace.Protocol,
		TraceID:   trace.TraceID,
		SessionID: trace.SessionID,
		Ingress:   trace.Ingress,
		Protocol:  trace.Protocol,
	})
}

func (r *tunTraceRecorder) reportTunPacketDiagnostic(stage string) {
	if r.packetDiagnosticSink != nil {
		r.packetDiagnosticSink(stage)
	}
	r.events.Publish(RuntimeEvent{
		Kind:      "tun.diagnostic",
		State:     RuntimeRunning,
		Message:   stage,
		TraceID:   hashHex(strings.Join([]string{r.sessionID, stage}, "|")),
		SessionID: r.sessionID,
		Ingress:   "diagnostic",
		Protocol:  stage,
	})
}

func (r *tunTraceRecorder) reportTunLifecycleDiagnostic(stage string) {
	if r.packetDiagnosticSink != nil {
		r.packetDiagnosticSink(stage)
	}
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
	var capturedMetadata *C.Metadata
	if metadata != nil {
		cloned := *metadata
		capturedMetadata = &cloned
	}
	candidate := &tcpTraceCandidate{
		recorder: t.recorder,
		metadata: capturedMetadata,
		tapped:   tapped,
		state:    tcpTraceCandidateCollecting,
		done:     make(chan struct{}),
	}
	tapped.onFirstPayload = func(payload []byte) {
		candidate.notePayloadObserved(payload)
	}
	tapped.onClose = func(bytesRead uint64) {
		candidate.noteConnClosed(bytesRead)
	}
	t.delegate.HandleTCPConn(tapped, metadata)
	candidate.onDelegateReturn()
}

func (t tracedTunTunnel) HandleUDPPacket(packet C.UDPPacket, metadata *C.Metadata) {
	payload := append([]byte(nil), packet.Data()...)
	protocol := "udp"
	correlationHash := markerHash(metadata, payload)
	if isDNSMetadata(metadata) || isDNSQueryPayload(payload) {
		protocol = "dns"
		correlationHash = hashBytesHex(payload)
	}
	t.delegate.HandleUDPPacket(packet, metadata)
	t.recorder.appendTrace(protocol, metadata, uint64(len(payload)), correlationHash, t.recorder.outboundLookup(metadata))
}

func (t tracedTunTunnel) NatTable() C.NatTable {
	return t.delegate.NatTable()
}

func (t tracedTunTunnel) reportTunPacketDiagnostic(stage string) {
	t.recorder.reportTunPacketDiagnostic(stage)
}

func (t tracedTunTunnel) reportTunLifecycleDiagnostic(stage string) {
	t.recorder.reportTunLifecycleDiagnostic(stage)
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
	mu               sync.Mutex
	bytesRead        uint64
	buffer           []byte
	firstPayloadOnce sync.Once
	closeOnce        sync.Once
	onFirstPayload   func(payload []byte)
	onClose          func(bytesRead uint64)
}

func (c *tapConn) Read(target []byte) (int, error) {
	n, err := c.Conn.Read(target)
	if n > 0 {
		payload := append([]byte(nil), target[:n]...)
		c.mu.Lock()
		c.bytesRead += uint64(n)
		if len(c.buffer) < tunTraceMaxCandidateBytes {
			remaining := tunTraceMaxCandidateBytes - len(c.buffer)
			if remaining > n {
				remaining = n
			}
			c.buffer = append(c.buffer, target[:remaining]...)
		}
		onFirstPayload := c.onFirstPayload
		c.mu.Unlock()
		if onFirstPayload != nil {
			c.firstPayloadOnce.Do(func() {
				onFirstPayload(payload)
			})
		}
	}
	return n, err
}

func (c *tapConn) Close() error {
	err := c.Conn.Close()
	c.closeOnce.Do(func() {
		c.mu.Lock()
		bytesRead := c.bytesRead
		onClose := c.onClose
		c.mu.Unlock()
		if onClose != nil {
			onClose(bytesRead)
		}
	})
	return err
}

func (c *tcpTraceCandidate) notePayloadObserved(_ []byte) {
	if c.tryStartResolver() {
		return
	}
	c.tryCommitFromDelegate()
}

func (c *tcpTraceCandidate) noteConnClosed(bytesRead uint64) {
	if bytesRead != 0 {
		return
	}
	c.mu.Lock()
	if c.state != tcpTraceCandidateCollecting && c.state != tcpTraceCandidateDelegateFinalizing {
		c.mu.Unlock()
		return
	}
	c.state = tcpTraceCandidateClosed
	c.mu.Unlock()
	c.finishTerminal()
}

func (c *tcpTraceCandidate) onDelegateReturn() {
	bytesRead, _ := c.tapped.snapshot()
	waitDone := false

	c.mu.Lock()
	switch c.state {
	case tcpTraceCandidateCollecting:
		c.state = tcpTraceCandidateDelegateFinalizing
	case tcpTraceCandidateResolving:
		waitDone = true
	case tcpTraceCandidateCommitted, tcpTraceCandidateClosed:
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()

	if waitDone {
		c.waitDone()
		return
	}
	if bytesRead == 0 {
		return
	}
	if c.tryCommitFromDelegate() {
		return
	}
	if c.tryStartResolver() {
		c.waitDone()
		return
	}
	c.closeIfFinalizing()
}

func (c *tcpTraceCandidate) resolveLoop() {
	c.recorder.resolverOnStart()
	defer c.finishResolver()
	if c.tryCommitFromResolver() {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), c.recorder.resolverTimeout)
	defer cancel()
	deadline := c.recorder.resolverNow().Add(c.recorder.resolverTimeout)
	for {
		if !c.recorder.resolverNow().Before(deadline) {
			return
		}
		if !c.recorder.resolverWait(ctx) {
			return
		}
		if c.tryCommitFromResolver() {
			return
		}
	}
}

func (c *tcpTraceCandidate) tryCommit(protocol string, terminalState tcpTraceCandidateState, closeDone bool) bool {
	bytesRead, payload := c.tapped.snapshot()
	if bytesRead == 0 {
		return false
	}
	resolvedProtocol := protocol
	correlationHash, complete := resolveTCPTraceCorrelation(c.metadata, payload)
	if isDNSMetadata(c.metadata) {
		resolvedProtocol = "dns"
	}
	if !complete {
		return false
	}
	outbound := c.recorder.outboundLookup(c.metadata)
	if !hasTunOutboundProof(outbound) {
		return false
	}

	c.mu.Lock()
	if c.state == tcpTraceCandidateCommitted || c.state == tcpTraceCandidateClosed {
		c.mu.Unlock()
		return c.state == tcpTraceCandidateCommitted
	}
	switch terminalState {
	case tcpTraceCandidateCommitted:
		if c.state != tcpTraceCandidateCollecting &&
			c.state != tcpTraceCandidateDelegateFinalizing &&
			c.state != tcpTraceCandidateResolving {
			c.mu.Unlock()
			return false
		}
	case tcpTraceCandidateClosed:
		if c.state != tcpTraceCandidateCollecting && c.state != tcpTraceCandidateDelegateFinalizing {
			c.mu.Unlock()
			return false
		}
	default:
		c.mu.Unlock()
		return false
	}

	c.recorder.appendTrace(resolvedProtocol, c.metadata, bytesRead, correlationHash, outbound)
	c.state = terminalState
	c.mu.Unlock()
	if closeDone {
		c.finishTerminal()
	}
	return true
}

func (c *tcpTraceCandidate) tryStartResolver() bool {
	c.mu.Lock()
	if c.state != tcpTraceCandidateCollecting && c.state != tcpTraceCandidateDelegateFinalizing {
		c.mu.Unlock()
		return false
	}
	if !c.recorder.tryAcquireResolverSlot() {
		c.mu.Unlock()
		return false
	}
	c.state = tcpTraceCandidateResolving
	c.mu.Unlock()
	go c.resolveLoop()
	return true
}

func (c *tcpTraceCandidate) tryCommitFromDelegate() bool {
	return c.tryCommit("tcp", tcpTraceCandidateCommitted, true)
}

func (c *tcpTraceCandidate) tryCommitFromResolver() bool {
	return c.tryCommit("tcp", tcpTraceCandidateCommitted, false)
}

func (c *tcpTraceCandidate) closeIfFinalizing() {
	c.mu.Lock()
	if c.state != tcpTraceCandidateDelegateFinalizing {
		c.mu.Unlock()
		return
	}
	c.state = tcpTraceCandidateClosed
	c.mu.Unlock()
	c.finishTerminal()
}

func (c *tcpTraceCandidate) finishResolver() {
	shouldFinish := false

	c.mu.Lock()
	switch c.state {
	case tcpTraceCandidateResolving:
		c.state = tcpTraceCandidateClosed
		shouldFinish = true
	case tcpTraceCandidateCommitted:
		shouldFinish = true
	}
	c.mu.Unlock()
	if !shouldFinish {
		return
	}
	c.recorder.releaseResolverSlot()
	c.finishTerminal()
	c.recorder.resolverOnDone()
}

func (c *tcpTraceCandidate) finishTerminal() {
	c.doneOnce.Do(func() {
		close(c.done)
	})
}

func (c *tcpTraceCandidate) waitDone() {
	<-c.done
}

func (c *tapConn) peek() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]byte(nil), c.buffer...)
}

func (c *tapConn) snapshot() (uint64, []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.bytesRead, append([]byte(nil), c.buffer...)
}

func markerHash(metadata *C.Metadata, payload []byte) string {
	if metadata == nil {
		return ""
	}
	marker := flowMarkerPattern.Find(payload)
	if len(marker) == 0 {
		return ""
	}
	return hashBytesHex(marker)
}

func resolveTCPTraceCorrelation(metadata *C.Metadata, payload []byte) (string, bool) {
	if len(payload) == 0 {
		return "", false
	}
	if isDNSMetadata(metadata) {
		return hashBytesHex(payload), true
	}
	if marker := probeUUIDMarkerPattern.Find(payload); len(marker) > 0 {
		return hashBytesHex(marker), true
	}
	if hasTruncatedProbeUUIDMarker(payload) {
		return "", false
	}
	if marker := flowMarkerPattern.Find(payload); len(marker) > 0 {
		return hashBytesHex(marker), true
	}
	return "", true
}

func hasTruncatedProbeUUIDMarker(payload []byte) bool {
	for searchFrom := 0; searchFrom <= len(payload); {
		index := bytes.Index(payload[searchFrom:], []byte("cmfa-"))
		if index < 0 {
			return false
		}
		start := searchFrom + index + len("cmfa-")
		if isTruncatedProbeUUIDFragment(payload[start:]) {
			return true
		}
		searchFrom = start
	}
	return false
}

func isTruncatedProbeUUIDFragment(fragment []byte) bool {
	if len(fragment) == 0 {
		return true
	}
	if len(fragment) >= 36 {
		return false
	}
	for index, value := range fragment {
		if !matchesProbeUUIDByte(index, value) {
			return false
		}
	}
	return true
}

func matchesProbeUUIDByte(index int, value byte) bool {
	switch index {
	case 8, 13, 18, 23:
		return value == '-'
	default:
		return (value >= '0' && value <= '9') ||
			(value >= 'a' && value <= 'f') ||
			(value >= 'A' && value <= 'F')
	}
}

func hasTunOutboundProof(proof tunOutboundProof) bool {
	return proof.terminalHash != "" && proof.chainHash != "" && proof.chainLength > 0
}

func isDNSQueryPayload(payload []byte) bool {
	if len(payload) < 17 {
		return false
	}
	questionCount := int(payload[4])<<8 | int(payload[5])
	if questionCount <= 0 {
		return false
	}
	offset := 12
	for questionIndex := 0; questionIndex < questionCount; questionIndex += 1 {
		labelBytes := 0
		for {
			if offset >= len(payload) {
				return false
			}
			length := int(payload[offset])
			offset += 1
			if length == 0 {
				break
			}
			if length&0xc0 != 0 || length > 63 {
				return false
			}
			if offset+length > len(payload) {
				return false
			}
			labelBytes += length + 1
			if labelBytes > 255 {
				return false
			}
			offset += length
		}
		if offset+4 > len(payload) {
			return false
		}
		offset += 4
	}
	return offset == len(payload)
}

func (r *tunTraceRecorder) tryAcquireResolverSlot() bool {
	select {
	case r.resolverSlots <- struct{}{}:
		return true
	default:
		return false
	}
}

func (r *tunTraceRecorder) releaseResolverSlot() {
	select {
	case <-r.resolverSlots:
	default:
	}
}

func isDNSMetadata(metadata *C.Metadata) bool {
	return metadata != nil && metadata.DstPort == 53
}

func destinationHash(protocol string, metadata *C.Metadata) string {
	if metadata == nil || protocol == "" || metadata.DstPort == 0 || !metadata.DstIP.IsValid() {
		return ""
	}
	canonicalIP := metadata.DstIP.Unmap()
	if !canonicalIP.IsValid() {
		return ""
	}
	return hashHex(strings.Join([]string{
		protocol,
		canonicalIP.String(),
		strconv.FormatUint(uint64(metadata.DstPort), 10),
	}, "|"))
}

func makeTunTraceOutboundProofLookup(
	trackerRange func(yield func(statistic.Tracker) bool),
) func(*C.Metadata) tunOutboundProof {
	return func(metadata *C.Metadata) tunOutboundProof {
		return lookupTunOutboundProofWithRange(metadata, trackerRange)
	}
}

func lookupTunOutboundProofWithRange(
	metadata *C.Metadata,
	trackerRange func(yield func(statistic.Tracker) bool),
) tunOutboundProof {
	if metadata == nil {
		return tunOutboundProof{}
	}
	matchCount := 0
	var matchedChain C.Chain
	trackerRange(func(tracker statistic.Tracker) bool {
		info := tracker.Info()
		if info == nil || info.Metadata == nil {
			return true
		}
		if !sameTunTraceMetadata(metadata, info.Metadata) {
			return true
		}
		matchCount += 1
		if matchCount == 1 {
			matchedChain = append(C.Chain(nil), info.Chain...)
		}
		return matchCount < 2
	})
	if matchCount != 1 {
		return tunOutboundProof{}
	}
	terminalHash, chainHash, chainLength, ok := hashTunOutboundChain(matchedChain)
	if !ok {
		return tunOutboundProof{}
	}
	return tunOutboundProof{
		terminalHash: terminalHash,
		chainHash:    chainHash,
		chainLength:  chainLength,
	}
}

func sameTunTraceMetadata(expected *C.Metadata, actual *C.Metadata) bool {
	if expected == nil || actual == nil {
		return false
	}
	expectedSrc, expectedDst, ok := canonicalTunTraceTuple(expected)
	if !ok {
		return false
	}
	actualSrc, actualDst, ok := canonicalTunTraceTuple(actual)
	if !ok {
		return false
	}
	return expected.Type == actual.Type &&
		expected.NetWork == actual.NetWork &&
		expectedSrc == actualSrc &&
		expectedDst == actualDst
}

func canonicalTunTraceTuple(metadata *C.Metadata) (netip.AddrPort, netip.AddrPort, bool) {
	if metadata == nil || metadata.SrcPort == 0 || metadata.DstPort == 0 || !metadata.SrcIP.IsValid() || !metadata.DstIP.IsValid() {
		return netip.AddrPort{}, netip.AddrPort{}, false
	}
	source := netip.AddrPortFrom(metadata.SrcIP.Unmap(), metadata.SrcPort)
	destination := netip.AddrPortFrom(metadata.DstIP.Unmap(), metadata.DstPort)
	return source, destination, source.IsValid() && destination.IsValid()
}

func hashTunOutboundChain(chain C.Chain) (string, string, uint32, bool) {
	if len(chain) == 0 || len(chain) > 16 {
		return "", "", 0, false
	}
	normalized := make([]string, 0, len(chain))
	for _, entry := range chain {
		if entry == "" || !utf8.ValidString(entry) || len([]byte(entry)) > 256 {
			return "", "", 0, false
		}
		for _, codePoint := range entry {
			if unicode.IsControl(codePoint) {
				return "", "", 0, false
			}
		}
		normalized = append(normalized, entry)
	}
	return hashHex(normalized[0]), hashHex(strings.Join(normalized, "\x1f")), uint32(len(normalized)), true
}
