package proxygroups

import (
	"bytes"
	"encoding/json"
	"io"
	"regexp"
	"time"
)

const (
	DelaySchemaVersion  = "1.0.0"
	MaxDelayJobIDBytes  = 32
	DelayWorkerCount    = 16
	DelayNodeTimeout    = 5 * time.Second
	DefaultDelayTestURL = "https://www.gstatic.com/generate_204"
)

const ErrCodeInvalidDelaySnapshot ErrorCode = "INVALID_DELAY_SNAPSHOT"

type DelayJobState string

const (
	DelayJobStateRunning   DelayJobState = "RUNNING"
	DelayJobStateCompleted DelayJobState = "COMPLETED"
	DelayJobStateCancelled DelayJobState = "CANCELLED"
	DelayJobStateFailed    DelayJobState = "FAILED"
)

type DelayNodeState string

const (
	DelayNodeStateWaiting     DelayNodeState = "WAITING"
	DelayNodeStateTesting     DelayNodeState = "TESTING"
	DelayNodeStateAvailable   DelayNodeState = "AVAILABLE"
	DelayNodeStateTimeout     DelayNodeState = "TIMEOUT"
	DelayNodeStateFailed      DelayNodeState = "FAILED"
	DelayNodeStateCancelled   DelayNodeState = "CANCELLED"
	DelayNodeStateUnsupported DelayNodeState = "UNSUPPORTED"
)

type DelayURLSource string

const (
	DelayURLSourceProvider DelayURLSource = "PROVIDER"
	DelayURLSourceFallback DelayURLSource = "FALLBACK"
)

var delayJobIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

type DelayNodeResult struct {
	Index   int             `json:"index"`
	Name    string          `json:"name"`
	Type    string          `json:"type"`
	State   DelayNodeState  `json:"state"`
	DelayMs *uint16         `json:"delayMs"`
	Source  *DelayURLSource `json:"source"`
	Fastest bool            `json:"fastest"`
}

type DelayTestSnapshot struct {
	SchemaVersion    string            `json:"schemaVersion"`
	JobID            string            `json:"jobId"`
	State            DelayJobState     `json:"state"`
	ProfileHash      string            `json:"profileHash"`
	RevisionHash     string            `json:"revisionHash"`
	SessionHash      *string           `json:"sessionHash"`
	Generation       uint64            `json:"generation"`
	GroupName        string            `json:"groupName"`
	TotalCount       int               `json:"totalCount"`
	TestableCount    int               `json:"testableCount"`
	CompletedCount   int               `json:"completedCount"`
	AvailableCount   int               `json:"availableCount"`
	TimeoutCount     int               `json:"timeoutCount"`
	FailedCount      int               `json:"failedCount"`
	CancelledCount   int               `json:"cancelledCount"`
	UnsupportedCount int               `json:"unsupportedCount"`
	FastestNodeIndex *int              `json:"fastestNodeIndex"`
	Nodes            []DelayNodeResult `json:"nodes"`
}

func NewDelayTestSnapshot(ctx QueryContext, jobID string, state DelayJobState, groupName string, nodes []DelayNodeResult) (DelayTestSnapshot, error) {
	snapshot := DelayTestSnapshot{
		SchemaVersion: DelaySchemaVersion,
		JobID:         jobID,
		State:         state,
		ProfileHash:   ctx.ProfileHash,
		RevisionHash:  ctx.RevisionHash,
		SessionHash:   cloneStringPtr(ctx.SessionHash),
		Generation:    ctx.Generation,
		GroupName:     groupName,
		Nodes:         normalizeDelayNodeResults(cloneDelayNodeResults(nodes)),
	}
	normalizeDelaySnapshot(&snapshot)
	if err := snapshot.Validate(); err != nil {
		return DelayTestSnapshot{}, err
	}
	return snapshot, nil
}

func ParseDelayTestSnapshotJSON(payload []byte) (DelayTestSnapshot, error) {
	if err := validateResponseSize(payload, MaxResponseBytes); err != nil {
		return DelayTestSnapshot{}, err
	}

	if err := validateDelaySnapshotWire(payload); err != nil {
		return DelayTestSnapshot{}, err
	}

	var decoded DelayTestSnapshot
	if err := decodeStrictJSON(payload, &decoded); err != nil {
		return DelayTestSnapshot{}, err
	}
	if err := decoded.Validate(); err != nil {
		return DelayTestSnapshot{}, err
	}
	decoded.SessionHash = cloneStringPtr(decoded.SessionHash)
	decoded.FastestNodeIndex = cloneIntPtr(decoded.FastestNodeIndex)
	decoded.Nodes = normalizeDelayNodeResults(cloneDelayNodeResults(decoded.Nodes))
	return decoded, nil
}

func (s DelayTestSnapshot) Validate() error {
	if s.SchemaVersion != DelaySchemaVersion {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	if err := (QueryContext{
		ProfileHash:  s.ProfileHash,
		RevisionHash: s.RevisionHash,
		SessionHash:  s.SessionHash,
		Generation:   s.Generation,
	}).Validate(); err != nil {
		return err
	}
	if !delayJobIDPattern.MatchString(s.JobID) {
		return newModelError(ErrCodeInvalidDelaySnapshot)
	}
	if !isValidDelayJobState(s.State) {
		return newModelError(ErrCodeInvalidDelaySnapshot)
	}
	if err := validateName(s.GroupName); err != nil {
		return err
	}
	if len(s.Nodes) > MaxMemberCount {
		return newModelError(ErrCodeMemberCountExceeded)
	}

	expected := DelayTestSnapshot{
		SchemaVersion: s.SchemaVersion,
		JobID:         s.JobID,
		State:         s.State,
		ProfileHash:   s.ProfileHash,
		RevisionHash:  s.RevisionHash,
		SessionHash:   cloneStringPtr(s.SessionHash),
		Generation:    s.Generation,
		GroupName:     s.GroupName,
		Nodes:         normalizeDelayNodeResults(cloneDelayNodeResults(s.Nodes)),
	}
	normalizeDelaySnapshot(&expected)

	if expected.TotalCount != s.TotalCount ||
		expected.TestableCount != s.TestableCount ||
		expected.CompletedCount != s.CompletedCount ||
		expected.AvailableCount != s.AvailableCount ||
		expected.TimeoutCount != s.TimeoutCount ||
		expected.FailedCount != s.FailedCount ||
		expected.CancelledCount != s.CancelledCount ||
		expected.UnsupportedCount != s.UnsupportedCount ||
		!equalOptionalInt(expected.FastestNodeIndex, s.FastestNodeIndex) {
		return newModelError(ErrCodeInvalidDelaySnapshot)
	}

	for i := range s.Nodes {
		if err := validateDelayNodeResult(s.Nodes[i], i); err != nil {
			return err
		}
		if s.Nodes[i].Fastest != expected.Nodes[i].Fastest {
			return newModelError(ErrCodeInvalidDelaySnapshot)
		}
	}

	if s.State != DelayJobStateRunning {
		for _, node := range s.Nodes {
			if isLiveDelayNodeState(node.State) {
				return newModelError(ErrCodeInvalidDelaySnapshot)
			}
		}
	}

	return nil
}

func (s DelayTestSnapshot) MarshalJSONBytes() ([]byte, error) {
	return s.MarshalJSON()
}

func (s DelayTestSnapshot) MarshalJSON() ([]byte, error) {
	clone := DelayTestSnapshot{
		SchemaVersion:    s.SchemaVersion,
		JobID:            s.JobID,
		State:            s.State,
		ProfileHash:      s.ProfileHash,
		RevisionHash:     s.RevisionHash,
		SessionHash:      cloneStringPtr(s.SessionHash),
		Generation:       s.Generation,
		GroupName:        s.GroupName,
		TotalCount:       s.TotalCount,
		TestableCount:    s.TestableCount,
		CompletedCount:   s.CompletedCount,
		AvailableCount:   s.AvailableCount,
		TimeoutCount:     s.TimeoutCount,
		FailedCount:      s.FailedCount,
		CancelledCount:   s.CancelledCount,
		UnsupportedCount: s.UnsupportedCount,
		FastestNodeIndex: cloneIntPtr(s.FastestNodeIndex),
		Nodes:            normalizeDelayNodeResults(cloneDelayNodeResults(s.Nodes)),
	}
	if err := clone.Validate(); err != nil {
		return nil, err
	}

	type alias DelayTestSnapshot
	payload, err := json.Marshal(alias(clone))
	if err != nil {
		return nil, newModelError(ErrCodeInvalidEnvelope)
	}
	if err := validateResponseSize(payload, MaxResponseBytes); err != nil {
		return nil, err
	}
	return payload, nil
}

func validateDelayNodeResult(node DelayNodeResult, index int) error {
	if node.Index != index {
		return newModelError(ErrCodeInvalidDelaySnapshot)
	}
	if err := validateName(node.Name); err != nil {
		return err
	}
	if !isAllowedType(node.Type) {
		return newModelError(ErrCodeUnknownType)
	}
	if !isValidDelayNodeState(node.State) {
		return newModelError(ErrCodeInvalidDelaySnapshot)
	}
	if node.State == DelayNodeStateAvailable {
		if node.DelayMs == nil || *node.DelayMs == 0 {
			return newModelError(ErrCodeInvalidDelaySnapshot)
		}
	} else if node.DelayMs != nil {
		return newModelError(ErrCodeInvalidDelaySnapshot)
	}

	if node.State == DelayNodeStateUnsupported {
		if node.Source != nil {
			return newModelError(ErrCodeInvalidDelaySnapshot)
		}
		return nil
	}
	if node.Source == nil || !isValidDelayURLSource(*node.Source) {
		return newModelError(ErrCodeInvalidDelaySnapshot)
	}
	return nil
}

func normalizeDelaySnapshot(snapshot *DelayTestSnapshot) {
	snapshot.Nodes = normalizeDelayNodeResults(snapshot.Nodes)
	snapshot.TotalCount = len(snapshot.Nodes)
	snapshot.TestableCount = 0
	snapshot.CompletedCount = 0
	snapshot.AvailableCount = 0
	snapshot.TimeoutCount = 0
	snapshot.FailedCount = 0
	snapshot.CancelledCount = 0
	snapshot.UnsupportedCount = 0
	snapshot.FastestNodeIndex = nil

	var fastestDelay uint16
	for i := range snapshot.Nodes {
		snapshot.Nodes[i].DelayMs = cloneUint16Ptr(snapshot.Nodes[i].DelayMs)
		snapshot.Nodes[i].Source = cloneDelayURLSourcePtr(snapshot.Nodes[i].Source)
		snapshot.Nodes[i].Fastest = false

		switch snapshot.Nodes[i].State {
		case DelayNodeStateUnsupported:
			snapshot.UnsupportedCount++
		default:
			snapshot.TestableCount++
		}
		if !isLiveDelayNodeState(snapshot.Nodes[i].State) {
			snapshot.CompletedCount++
		}
		switch snapshot.Nodes[i].State {
		case DelayNodeStateAvailable:
			snapshot.AvailableCount++
			delay := *snapshot.Nodes[i].DelayMs
			if snapshot.FastestNodeIndex == nil || delay < fastestDelay {
				fastestDelay = delay
				fastestIndex := i
				snapshot.FastestNodeIndex = &fastestIndex
			}
		case DelayNodeStateTimeout:
			snapshot.TimeoutCount++
		case DelayNodeStateFailed:
			snapshot.FailedCount++
		case DelayNodeStateCancelled:
			snapshot.CancelledCount++
		}
	}

	if snapshot.FastestNodeIndex != nil {
		snapshot.Nodes[*snapshot.FastestNodeIndex].Fastest = true
	}
}

func normalizeDelayNodeResults(nodes []DelayNodeResult) []DelayNodeResult {
	if nodes == nil {
		return []DelayNodeResult{}
	}
	return nodes
}

func cloneDelayNodeResults(nodes []DelayNodeResult) []DelayNodeResult {
	if nodes == nil {
		return nil
	}
	cloned := make([]DelayNodeResult, len(nodes))
	for i, node := range nodes {
		cloned[i] = DelayNodeResult{
			Index:   node.Index,
			Name:    node.Name,
			Type:    node.Type,
			State:   node.State,
			DelayMs: cloneUint16Ptr(node.DelayMs),
			Source:  cloneDelayURLSourcePtr(node.Source),
			Fastest: node.Fastest,
		}
	}
	return cloned
}

func cloneUint16Ptr(value *uint16) *uint16 {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func cloneDelayURLSourcePtr(value *DelayURLSource) *DelayURLSource {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func cloneIntPtr(value *int) *int {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func equalOptionalInt(left, right *int) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}

func isValidDelayJobState(state DelayJobState) bool {
	switch state {
	case DelayJobStateRunning, DelayJobStateCompleted, DelayJobStateCancelled, DelayJobStateFailed:
		return true
	default:
		return false
	}
}

func isValidDelayNodeState(state DelayNodeState) bool {
	switch state {
	case DelayNodeStateWaiting,
		DelayNodeStateTesting,
		DelayNodeStateAvailable,
		DelayNodeStateTimeout,
		DelayNodeStateFailed,
		DelayNodeStateCancelled,
		DelayNodeStateUnsupported:
		return true
	default:
		return false
	}
}

func isLiveDelayNodeState(state DelayNodeState) bool {
	switch state {
	case DelayNodeStateWaiting, DelayNodeStateTesting:
		return true
	default:
		return false
	}
}

func isValidDelayURLSource(source DelayURLSource) bool {
	switch source {
	case DelayURLSourceProvider, DelayURLSourceFallback:
		return true
	default:
		return false
	}
}

func consumeJSONEOF(decoder *json.Decoder) error {
	var extra struct{}
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return newModelError(ErrCodeInvalidEnvelope)
		}
		return newModelError(ErrCodeInvalidEnvelope)
	}
	return nil
}

func decodeStrictJSON(payload []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	return consumeJSONEOF(decoder)
}

type delaySnapshotWireTracker struct {
	schemaVersion    bool
	jobID            bool
	state            bool
	profileHash      bool
	revisionHash     bool
	sessionHash      bool
	generation       bool
	groupName        bool
	totalCount       bool
	testableCount    bool
	completedCount   bool
	availableCount   bool
	timeoutCount     bool
	failedCount      bool
	cancelledCount   bool
	unsupportedCount bool
	fastestNodeIndex bool
	nodes            bool
}

func (t *delaySnapshotWireTracker) mark(key string) error {
	switch key {
	case "schemaVersion":
		return markDelayField(&t.schemaVersion)
	case "jobId":
		return markDelayField(&t.jobID)
	case "state":
		return markDelayField(&t.state)
	case "profileHash":
		return markDelayField(&t.profileHash)
	case "revisionHash":
		return markDelayField(&t.revisionHash)
	case "sessionHash":
		return markDelayField(&t.sessionHash)
	case "generation":
		return markDelayField(&t.generation)
	case "groupName":
		return markDelayField(&t.groupName)
	case "totalCount":
		return markDelayField(&t.totalCount)
	case "testableCount":
		return markDelayField(&t.testableCount)
	case "completedCount":
		return markDelayField(&t.completedCount)
	case "availableCount":
		return markDelayField(&t.availableCount)
	case "timeoutCount":
		return markDelayField(&t.timeoutCount)
	case "failedCount":
		return markDelayField(&t.failedCount)
	case "cancelledCount":
		return markDelayField(&t.cancelledCount)
	case "unsupportedCount":
		return markDelayField(&t.unsupportedCount)
	case "fastestNodeIndex":
		return markDelayField(&t.fastestNodeIndex)
	case "nodes":
		return markDelayField(&t.nodes)
	default:
		return newModelError(ErrCodeInvalidEnvelope)
	}
}

func (t delaySnapshotWireTracker) complete() bool {
	return t.schemaVersion &&
		t.jobID &&
		t.state &&
		t.profileHash &&
		t.revisionHash &&
		t.sessionHash &&
		t.generation &&
		t.groupName &&
		t.totalCount &&
		t.testableCount &&
		t.completedCount &&
		t.availableCount &&
		t.timeoutCount &&
		t.failedCount &&
		t.cancelledCount &&
		t.unsupportedCount &&
		t.fastestNodeIndex &&
		t.nodes
}

type delayNodeWireTracker struct {
	index   bool
	name    bool
	typ     bool
	state   bool
	delayMs bool
	source  bool
	fastest bool
}

func (t *delayNodeWireTracker) mark(key string) error {
	switch key {
	case "index":
		return markDelayField(&t.index)
	case "name":
		return markDelayField(&t.name)
	case "type":
		return markDelayField(&t.typ)
	case "state":
		return markDelayField(&t.state)
	case "delayMs":
		return markDelayField(&t.delayMs)
	case "source":
		return markDelayField(&t.source)
	case "fastest":
		return markDelayField(&t.fastest)
	default:
		return newModelError(ErrCodeInvalidEnvelope)
	}
}

func (t delayNodeWireTracker) complete() bool {
	return t.index && t.name && t.typ && t.state && t.delayMs && t.source && t.fastest
}

func validateDelaySnapshotWire(payload []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	token, err := decoder.Token()
	if err != nil {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	if !isJSONDelim(token, '{') {
		return newModelError(ErrCodeInvalidEnvelope)
	}

	var tracker delaySnapshotWireTracker
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return newModelError(ErrCodeInvalidEnvelope)
		}
		key, ok := keyToken.(string)
		if !ok {
			return newModelError(ErrCodeInvalidEnvelope)
		}
		if err := tracker.mark(key); err != nil {
			return err
		}

		switch key {
		case "sessionHash", "fastestNodeIndex":
			if err := skipNextJSONValue(decoder); err != nil {
				return err
			}
		case "nodes":
			if err := validateDelayNodesWire(decoder); err != nil {
				return err
			}
		default:
			if err := requireNonNullJSONValue(decoder); err != nil {
				return err
			}
		}
	}
	if _, err := decoder.Token(); err != nil {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	if !tracker.complete() {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	return consumeJSONEOF(decoder)
}

func validateDelayNodesWire(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	if !isJSONDelim(token, '[') {
		return newModelError(ErrCodeInvalidEnvelope)
	}

	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return newModelError(ErrCodeInvalidEnvelope)
		}
		if !isJSONDelim(token, '{') {
			return newModelError(ErrCodeInvalidEnvelope)
		}

		var tracker delayNodeWireTracker
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return newModelError(ErrCodeInvalidEnvelope)
			}
			key, ok := keyToken.(string)
			if !ok {
				return newModelError(ErrCodeInvalidEnvelope)
			}
			if err := tracker.mark(key); err != nil {
				return err
			}

			switch key {
			case "delayMs", "source":
				if err := skipNextJSONValue(decoder); err != nil {
					return err
				}
			default:
				if err := requireNonNullJSONValue(decoder); err != nil {
					return err
				}
			}
		}
		if _, err := decoder.Token(); err != nil {
			return newModelError(ErrCodeInvalidEnvelope)
		}
		if !tracker.complete() {
			return newModelError(ErrCodeInvalidEnvelope)
		}
	}
	if _, err := decoder.Token(); err != nil {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	return nil
}

func markDelayField(seen *bool) error {
	if *seen {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	*seen = true
	return nil
}

func requireNonNullJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	if token == nil {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	return skipConsumedJSONValue(decoder, token)
}

func skipNextJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	return skipConsumedJSONValue(decoder, token)
}

func skipConsumedJSONValue(decoder *json.Decoder, token json.Token) error {
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return newModelError(ErrCodeInvalidEnvelope)
			}
			if _, ok := keyToken.(string); !ok {
				return newModelError(ErrCodeInvalidEnvelope)
			}
			if err := skipNextJSONValue(decoder); err != nil {
				return err
			}
		}
		if _, err := decoder.Token(); err != nil {
			return newModelError(ErrCodeInvalidEnvelope)
		}
		return nil
	case '[':
		for decoder.More() {
			if err := skipNextJSONValue(decoder); err != nil {
				return err
			}
		}
		if _, err := decoder.Token(); err != nil {
			return newModelError(ErrCodeInvalidEnvelope)
		}
		return nil
	default:
		return newModelError(ErrCodeInvalidEnvelope)
	}
}

func isJSONDelim(token json.Token, want json.Delim) bool {
	delim, ok := token.(json.Delim)
	return ok && delim == want
}
