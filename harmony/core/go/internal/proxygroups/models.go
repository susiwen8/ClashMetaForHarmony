package proxygroups

import (
	"encoding/json"
	"regexp"
	"unicode"
	"unicode/utf8"
)

const (
	MaxGroupCount    = 128
	MaxMemberCount   = 1024
	MaxNameUTF8Bytes = 256
	MaxResponseBytes = 1024 * 1024
)

const (
	schemaVersion = "1.0.0"
	kindGroupList = "GROUP_LIST"
	kindSnapshot  = "GROUP_SNAPSHOT"
	kindSelection = "SELECTION_APPLIED"
)

type ErrorCode string

const (
	ErrCodeInvalidQueryContext ErrorCode = "INVALID_QUERY_CONTEXT"
	ErrCodeInvalidName         ErrorCode = "INVALID_NAME"
	ErrCodeUnknownType         ErrorCode = "UNKNOWN_TYPE"
	ErrCodeDuplicateName       ErrorCode = "DUPLICATE_NAME"
	ErrCodeGroupCountExceeded  ErrorCode = "GROUP_COUNT_EXCEEDED"
	ErrCodeMemberCountExceeded ErrorCode = "MEMBER_COUNT_EXCEEDED"
	ErrCodeSelectionMismatch   ErrorCode = "SELECTION_MISMATCH"
	ErrCodeMultipleSelected    ErrorCode = "MULTIPLE_SELECTED"
	ErrCodeResponseTooLarge    ErrorCode = "RESPONSE_TOO_LARGE"
	ErrCodeInvalidEnvelope     ErrorCode = "INVALID_ENVELOPE"
)

var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type ModelError struct {
	Code ErrorCode
}

func (e *ModelError) Error() string {
	if e == nil {
		return ""
	}

	switch e.Code {
	case ErrCodeInvalidQueryContext:
		return "invalid query context"
	case ErrCodeInvalidName:
		return "invalid name"
	case ErrCodeUnknownType:
		return "unknown proxy type"
	case ErrCodeDuplicateName:
		return "duplicate name detected"
	case ErrCodeGroupCountExceeded:
		return "group count exceeds limit"
	case ErrCodeMemberCountExceeded:
		return "member count exceeds limit"
	case ErrCodeSelectionMismatch:
		return "selected member mismatch"
	case ErrCodeMultipleSelected:
		return "multiple selected members"
	case ErrCodeResponseTooLarge:
		return "response exceeds size limit"
	case ErrCodeInvalidEnvelope:
		return "invalid success envelope"
	default:
		return "invalid proxy group model"
	}
}

func newModelError(code ErrorCode) error {
	return &ModelError{Code: code}
}

type QueryContext struct {
	ProfileHash  string  `json:"profileHash"`
	RevisionHash string  `json:"revisionHash"`
	SessionHash  *string `json:"sessionHash"`
	Generation   uint64  `json:"generation"`
}

func (ctx QueryContext) Validate() error {
	if !isValidHash(ctx.ProfileHash) || !isValidHash(ctx.RevisionHash) {
		return newModelError(ErrCodeInvalidQueryContext)
	}
	if ctx.SessionHash != nil && !isValidHash(*ctx.SessionHash) {
		return newModelError(ErrCodeInvalidQueryContext)
	}
	if ctx.Generation == 0 {
		return newModelError(ErrCodeInvalidQueryContext)
	}
	return nil
}

type GroupRef struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

func (g GroupRef) Validate() error {
	if err := validateName(g.Name); err != nil {
		return err
	}
	if !isAllowedType(g.Type) {
		return newModelError(ErrCodeUnknownType)
	}
	return nil
}

type NodeSummary struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	IsGroup  bool   `json:"isGroup"`
	Selected bool   `json:"selected"`
}

func (n NodeSummary) Validate() error {
	if err := validateName(n.Name); err != nil {
		return err
	}
	if !isAllowedType(n.Type) {
		return newModelError(ErrCodeUnknownType)
	}
	return nil
}

type GroupSnapshot struct {
	Name         string        `json:"name"`
	Type         string        `json:"type"`
	SelectedName string        `json:"selectedName"`
	Nodes        []NodeSummary `json:"nodes"`
}

func (g GroupSnapshot) Validate() error {
	if err := validateName(g.Name); err != nil {
		return err
	}
	if !isAllowedType(g.Type) {
		return newModelError(ErrCodeUnknownType)
	}
	if g.SelectedName != "" {
		if err := validateName(g.SelectedName); err != nil {
			return err
		}
	}
	if len(g.Nodes) > MaxMemberCount {
		return newModelError(ErrCodeMemberCountExceeded)
	}

	seen := make(map[string]struct{}, len(g.Nodes))
	selectedCount := 0
	selectedName := ""
	for _, node := range g.Nodes {
		if err := node.Validate(); err != nil {
			return err
		}
		if _, ok := seen[node.Name]; ok {
			return newModelError(ErrCodeDuplicateName)
		}
		seen[node.Name] = struct{}{}
		if node.Selected {
			selectedCount++
			selectedName = node.Name
		}
	}

	if selectedCount > 1 {
		return newModelError(ErrCodeMultipleSelected)
	}
	if g.SelectedName == "" {
		if selectedCount != 0 {
			return newModelError(ErrCodeSelectionMismatch)
		}
		return nil
	}
	if selectedCount != 1 || selectedName != g.SelectedName {
		return newModelError(ErrCodeSelectionMismatch)
	}
	return nil
}

type GroupListEnvelope struct {
	SchemaVersion string     `json:"schemaVersion"`
	Kind          string     `json:"kind"`
	ProfileHash   string     `json:"profileHash"`
	RevisionHash  string     `json:"revisionHash"`
	SessionHash   *string    `json:"sessionHash"`
	Generation    uint64     `json:"generation"`
	Groups        []GroupRef `json:"groups"`
}

func NewGroupListEnvelope(ctx QueryContext, groups []GroupRef) (GroupListEnvelope, error) {
	envelope := GroupListEnvelope{
		SchemaVersion: schemaVersion,
		Kind:          kindGroupList,
		ProfileHash:   ctx.ProfileHash,
		RevisionHash:  ctx.RevisionHash,
		SessionHash:   cloneStringPtr(ctx.SessionHash),
		Generation:    ctx.Generation,
		Groups:        normalizeGroupRefs(cloneGroupRefs(groups)),
	}
	if err := envelope.Validate(); err != nil {
		return GroupListEnvelope{}, err
	}
	return envelope, nil
}

func (e GroupListEnvelope) Validate() error {
	if err := validateEnvelopeBase(e.SchemaVersion, e.Kind, QueryContext{
		ProfileHash:  e.ProfileHash,
		RevisionHash: e.RevisionHash,
		SessionHash:  e.SessionHash,
		Generation:   e.Generation,
	}); err != nil {
		return err
	}
	if len(e.Groups) > MaxGroupCount {
		return newModelError(ErrCodeGroupCountExceeded)
	}

	seen := make(map[string]struct{}, len(e.Groups))
	for _, group := range e.Groups {
		if err := group.Validate(); err != nil {
			return err
		}
		if _, ok := seen[group.Name]; ok {
			return newModelError(ErrCodeDuplicateName)
		}
		seen[group.Name] = struct{}{}
	}
	return nil
}

func (e GroupListEnvelope) MarshalJSONBytes() ([]byte, error) {
	return e.marshalJSONBytesWithLimit(MaxResponseBytes)
}

func (e GroupListEnvelope) marshalJSONBytesWithLimit(limit int) ([]byte, error) {
	e.Groups = normalizeGroupRefs(e.Groups)
	return marshalEnvelopeJSON(e, e.Validate, limit)
}

type GroupSnapshotEnvelope struct {
	SchemaVersion string        `json:"schemaVersion"`
	Kind          string        `json:"kind"`
	ProfileHash   string        `json:"profileHash"`
	RevisionHash  string        `json:"revisionHash"`
	SessionHash   *string       `json:"sessionHash"`
	Generation    uint64        `json:"generation"`
	Group         GroupSnapshot `json:"group"`
}

func NewGroupSnapshotEnvelope(ctx QueryContext, group GroupSnapshot) (GroupSnapshotEnvelope, error) {
	envelope := GroupSnapshotEnvelope{
		SchemaVersion: schemaVersion,
		Kind:          kindSnapshot,
		ProfileHash:   ctx.ProfileHash,
		RevisionHash:  ctx.RevisionHash,
		SessionHash:   cloneStringPtr(ctx.SessionHash),
		Generation:    ctx.Generation,
		Group:         cloneGroupSnapshot(group),
	}
	if err := envelope.Validate(); err != nil {
		return GroupSnapshotEnvelope{}, err
	}
	return envelope, nil
}

func (e GroupSnapshotEnvelope) Validate() error {
	if err := validateEnvelopeBase(e.SchemaVersion, e.Kind, QueryContext{
		ProfileHash:  e.ProfileHash,
		RevisionHash: e.RevisionHash,
		SessionHash:  e.SessionHash,
		Generation:   e.Generation,
	}); err != nil {
		return err
	}
	return e.Group.Validate()
}

func (e GroupSnapshotEnvelope) MarshalJSONBytes() ([]byte, error) {
	return e.marshalJSONBytesWithLimit(MaxResponseBytes)
}

func (e GroupSnapshotEnvelope) marshalJSONBytesWithLimit(limit int) ([]byte, error) {
	e.Group = normalizeGroupSnapshot(e.Group)
	return marshalEnvelopeJSON(e, e.Validate, limit)
}

type SelectionAppliedEnvelope struct {
	SchemaVersion string        `json:"schemaVersion"`
	Kind          string        `json:"kind"`
	ProfileHash   string        `json:"profileHash"`
	RevisionHash  string        `json:"revisionHash"`
	SessionHash   *string       `json:"sessionHash"`
	Generation    uint64        `json:"generation"`
	Group         GroupSnapshot `json:"group"`
	PreviousName  string        `json:"previousName"`
}

func NewSelectionAppliedEnvelope(ctx QueryContext, group GroupSnapshot, previousName string) (SelectionAppliedEnvelope, error) {
	envelope := SelectionAppliedEnvelope{
		SchemaVersion: schemaVersion,
		Kind:          kindSelection,
		ProfileHash:   ctx.ProfileHash,
		RevisionHash:  ctx.RevisionHash,
		SessionHash:   cloneStringPtr(ctx.SessionHash),
		Generation:    ctx.Generation,
		Group:         cloneGroupSnapshot(group),
		PreviousName:  previousName,
	}
	if err := envelope.Validate(); err != nil {
		return SelectionAppliedEnvelope{}, err
	}
	return envelope, nil
}

func (e SelectionAppliedEnvelope) Validate() error {
	if err := validateEnvelopeBase(e.SchemaVersion, e.Kind, QueryContext{
		ProfileHash:  e.ProfileHash,
		RevisionHash: e.RevisionHash,
		SessionHash:  e.SessionHash,
		Generation:   e.Generation,
	}); err != nil {
		return err
	}
	if e.PreviousName != "" {
		if err := validateName(e.PreviousName); err != nil {
			return err
		}
	}
	return e.Group.Validate()
}

func (e SelectionAppliedEnvelope) MarshalJSONBytes() ([]byte, error) {
	return e.marshalJSONBytesWithLimit(MaxResponseBytes)
}

func (e SelectionAppliedEnvelope) marshalJSONBytesWithLimit(limit int) ([]byte, error) {
	e.Group = normalizeGroupSnapshot(e.Group)
	return marshalEnvelopeJSON(e, e.Validate, limit)
}

func marshalEnvelopeJSON(value any, validate func() error, limit int) ([]byte, error) {
	if err := validate(); err != nil {
		return nil, err
	}
	payload, err := json.Marshal(value)
	if err != nil {
		return nil, newModelError(ErrCodeInvalidEnvelope)
	}
	if err := validateResponseSize(payload, limit); err != nil {
		return nil, err
	}
	return payload, nil
}

func validateResponseSize(payload []byte, limit int) error {
	if len(payload) > limit {
		return newModelError(ErrCodeResponseTooLarge)
	}
	return nil
}

func validateEnvelopeBase(version, kind string, ctx QueryContext) error {
	if version != schemaVersion {
		return newModelError(ErrCodeInvalidEnvelope)
	}
	switch kind {
	case kindGroupList, kindSnapshot, kindSelection:
	default:
		return newModelError(ErrCodeInvalidEnvelope)
	}
	return ctx.Validate()
}

func validateName(name string) error {
	if name == "" {
		return newModelError(ErrCodeInvalidName)
	}
	if !utf8.ValidString(name) {
		return newModelError(ErrCodeInvalidName)
	}
	if len(name) > MaxNameUTF8Bytes {
		return newModelError(ErrCodeInvalidName)
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return newModelError(ErrCodeInvalidName)
		}
	}
	return nil
}

func isValidHash(value string) bool {
	return hashPattern.MatchString(value)
}

func cloneStringPtr(value *string) *string {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func cloneGroupRefs(groups []GroupRef) []GroupRef {
	if groups == nil {
		return nil
	}
	return append([]GroupRef(nil), groups...)
}

func cloneGroupSnapshot(group GroupSnapshot) GroupSnapshot {
	group.Nodes = normalizeNodeSummaries(cloneNodeSummaries(group.Nodes))
	return group
}

func cloneNodeSummaries(nodes []NodeSummary) []NodeSummary {
	if nodes == nil {
		return nil
	}
	return append([]NodeSummary(nil), nodes...)
}

func normalizeGroupRefs(groups []GroupRef) []GroupRef {
	if groups == nil {
		return []GroupRef{}
	}
	return groups
}

func normalizeGroupSnapshot(group GroupSnapshot) GroupSnapshot {
	group.Nodes = normalizeNodeSummaries(group.Nodes)
	return group
}

func normalizeNodeSummaries(nodes []NodeSummary) []NodeSummary {
	if nodes == nil {
		return []NodeSummary{}
	}
	return nodes
}

func isAllowedType(value string) bool {
	switch value {
	case "Direct",
		"Reject",
		"RejectDrop",
		"Compatible",
		"Pass",
		"PassRule",
		"Rematch",
		"Dns",
		"Relay",
		"Selector",
		"Fallback",
		"URLTest",
		"LoadBalance",
		"Shadowsocks",
		"ShadowsocksR",
		"Snell",
		"Socks5",
		"Http",
		"Vmess",
		"Vless",
		"Trojan",
		"Hysteria",
		"Hysteria2",
		"WireGuard",
		"Tuic",
		"Ssh",
		"Mieru",
		"AnyTLS",
		"Sudoku",
		"Masque",
		"TrustTunnel",
		"ShadowQuic",
		"OpenVPN",
		"Tailscale",
		"GostRelay":
		return true
	default:
		return false
	}
}
