package proxygroups

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestLimitsMatchPlanBContract(t *testing.T) {
	if MaxGroupCount != 128 {
		t.Fatalf("MaxGroupCount = %d want 128", MaxGroupCount)
	}
	if MaxMemberCount != 1024 {
		t.Fatalf("MaxMemberCount = %d want 1024", MaxMemberCount)
	}
	if MaxNameUTF8Bytes != 256 {
		t.Fatalf("MaxNameUTF8Bytes = %d want 256", MaxNameUTF8Bytes)
	}
	if MaxResponseBytes != 1024*1024 {
		t.Fatalf("MaxResponseBytes = %d want %d", MaxResponseBytes, 1024*1024)
	}
}

func TestQueryContextValidate(t *testing.T) {
	session := validHash("c")
	valid := QueryContext{
		ProfileHash:  validHash("a"),
		RevisionHash: validHash("b"),
		SessionHash:  &session,
		Generation:   7,
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("Validate() unexpected error: %v", err)
	}

	cases := []struct {
		name string
		ctx  QueryContext
	}{
		{
			name: "invalid profile hash",
			ctx: QueryContext{
				ProfileHash:  strings.Repeat("A", 64),
				RevisionHash: validHash("b"),
				Generation:   1,
			},
		},
		{
			name: "invalid revision hash",
			ctx: QueryContext{
				ProfileHash:  validHash("a"),
				RevisionHash: strings.Repeat("z", 63),
				Generation:   1,
			},
		},
		{
			name: "invalid session hash",
			ctx: QueryContext{
				ProfileHash:  validHash("a"),
				RevisionHash: validHash("b"),
				SessionHash:  strPtr(strings.Repeat("f", 63)),
				Generation:   1,
			},
		},
		{
			name: "zero generation",
			ctx: QueryContext{
				ProfileHash:  validHash("a"),
				RevisionHash: validHash("b"),
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.ctx.Validate()
			assertErrorCode(t, err, ErrCodeInvalidQueryContext)
			assertNoLeak(t, err, tc.ctx.ProfileHash, tc.ctx.RevisionHash)
		})
	}
}

func TestGroupRefValidateRejectsInvalidNamesAndUnknownGroupTypes(t *testing.T) {
	valid := GroupRef{Name: "节点一", Type: "Selector"}
	if err := valid.Validate(); err != nil {
		t.Fatalf("Validate() unexpected error: %v", err)
	}

	cases := []struct {
		name  string
		group GroupRef
		code  ErrorCode
	}{
		{
			name:  "empty name",
			group: GroupRef{Name: "", Type: "Direct"},
			code:  ErrCodeInvalidName,
		},
		{
			name:  "oversized name",
			group: GroupRef{Name: strings.Repeat("n", MaxNameUTF8Bytes+1), Type: "Direct"},
			code:  ErrCodeInvalidName,
		},
		{
			name:  "control char",
			group: GroupRef{Name: "bad\nname", Type: "Direct"},
			code:  ErrCodeInvalidName,
		},
		{
			name:  "invalid utf8",
			group: GroupRef{Name: string([]byte{0xff, 0xfe}), Type: "Direct"},
			code:  ErrCodeInvalidName,
		},
		{
			name:  "unknown group type",
			group: GroupRef{Name: "group-alpha", Type: "FutureType"},
			code:  ErrCodeUnknownType,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.group.Validate()
			assertErrorCode(t, err, tc.code)
			assertNoLeak(t, err, tc.group.Name, tc.group.Type)
		})
	}
}

func TestNodeSummaryValidateRejectsUnknownMemberType(t *testing.T) {
	member := NodeSummary{Name: "member-alpha", Type: "FutureType"}
	err := member.Validate()
	assertErrorCode(t, err, ErrCodeUnknownType)
	assertNoLeak(t, err, member.Name, member.Type)
}

func TestAllowedTypesMatchPinnedMihomoV11929Allowlist(t *testing.T) {
	allowedTypes := []string{
		"Direct", "Reject", "RejectDrop", "Compatible", "Pass", "PassRule", "Rematch", "Dns",
		"Relay", "Selector", "Fallback", "URLTest", "LoadBalance", "Shadowsocks", "ShadowsocksR",
		"Snell", "Socks5", "Http", "Vmess", "Vless", "Trojan", "Hysteria", "Hysteria2",
		"WireGuard", "Tuic", "Ssh", "Mieru", "AnyTLS", "Sudoku", "Masque", "TrustTunnel",
		"ShadowQuic", "OpenVPN", "Tailscale", "GostRelay",
	}

	for _, allowedType := range allowedTypes {
		t.Run(allowedType, func(t *testing.T) {
			group := GroupRef{Name: "group-allow", Type: allowedType}
			if err := group.Validate(); err != nil {
				t.Fatalf("GroupRef.Validate() unexpected error: %v", err)
			}

			node := NodeSummary{Name: "node-allow", Type: allowedType}
			if err := node.Validate(); err != nil {
				t.Fatalf("NodeSummary.Validate() unexpected error: %v", err)
			}
		})
	}

	unknown := GroupRef{Name: "group-unknown", Type: "FutureType"}
	err := unknown.Validate()
	assertErrorCode(t, err, ErrCodeUnknownType)
	assertNoLeak(t, err, unknown.Type)
}

func TestGroupSnapshotValidateRejectsSelectionAndMemberViolations(t *testing.T) {
	t.Run("valid snapshot", func(t *testing.T) {
		group := GroupSnapshot{
			Name:         "selector-alpha",
			Type:         "Selector",
			SelectedName: "node-two",
			Nodes: []NodeSummary{
				{Name: "node-one", Type: "Direct"},
				{Name: "node-two", Type: "Shadowsocks", Selected: true},
				{Name: "child-group", Type: "Relay", IsGroup: true},
			},
		}
		if err := group.Validate(); err != nil {
			t.Fatalf("Validate() unexpected error: %v", err)
		}
	})

	t.Run("duplicate member names", func(t *testing.T) {
		group := GroupSnapshot{
			Name: "selector-alpha",
			Type: "Selector",
			Nodes: []NodeSummary{
				{Name: "dup-node", Type: "Direct"},
				{Name: "dup-node", Type: "Reject"},
			},
		}
		err := group.Validate()
		assertErrorCode(t, err, ErrCodeDuplicateName)
		assertNoLeak(t, err, "dup-node")
	})

	t.Run("member count overflow", func(t *testing.T) {
		group := GroupSnapshot{
			Name:  "selector-alpha",
			Type:  "Selector",
			Nodes: makeNodeSummaries(MaxMemberCount + 1),
		}
		err := group.Validate()
		assertErrorCode(t, err, ErrCodeMemberCountExceeded)
	})

	t.Run("unknown group type", func(t *testing.T) {
		group := GroupSnapshot{
			Name: "selector-alpha",
			Type: "GroupFutureType",
			Nodes: []NodeSummary{
				{Name: "node-one", Type: "Direct"},
			},
		}
		err := group.Validate()
		assertErrorCode(t, err, ErrCodeUnknownType)
		assertNoLeak(t, err, group.Type)
	})

	t.Run("unknown member type", func(t *testing.T) {
		group := GroupSnapshot{
			Name: "selector-alpha",
			Type: "Selector",
			Nodes: []NodeSummary{
				{Name: "node-one", Type: "FutureType"},
			},
		}
		err := group.Validate()
		assertErrorCode(t, err, ErrCodeUnknownType)
		assertNoLeak(t, err, "FutureType")
	})

	t.Run("mismatched selected name", func(t *testing.T) {
		group := GroupSnapshot{
			Name:         "selector-alpha",
			Type:         "Selector",
			SelectedName: "node-two",
			Nodes: []NodeSummary{
				{Name: "node-one", Type: "Direct", Selected: true},
				{Name: "node-two", Type: "Reject"},
			},
		}
		err := group.Validate()
		assertErrorCode(t, err, ErrCodeSelectionMismatch)
		assertNoLeak(t, err, "node-one", "node-two")
	})

	t.Run("multiple members selected", func(t *testing.T) {
		group := GroupSnapshot{
			Name:         "selector-alpha",
			Type:         "Selector",
			SelectedName: "node-two",
			Nodes: []NodeSummary{
				{Name: "node-one", Type: "Direct", Selected: true},
				{Name: "node-two", Type: "Reject", Selected: true},
			},
		}
		err := group.Validate()
		assertErrorCode(t, err, ErrCodeMultipleSelected)
		assertNoLeak(t, err, "node-one", "node-two")
	})
}

func TestNewGroupListEnvelopeRejectsDuplicateAndOverflowGroups(t *testing.T) {
	ctx := validQueryContext(nil)

	t.Run("valid and clones input", func(t *testing.T) {
		groups := []GroupRef{
			{Name: "group-a", Type: "Selector"},
			{Name: "group-b", Type: "Direct"},
		}
		envelope, err := NewGroupListEnvelope(ctx, groups)
		if err != nil {
			t.Fatalf("NewGroupListEnvelope() unexpected error: %v", err)
		}

		groups[0].Name = "mutated"
		payload, err := envelope.MarshalJSONBytes()
		if err != nil {
			t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
		}
		if strings.Contains(string(payload), "mutated") {
			t.Fatal("envelope retained caller mutation")
		}
	})

	t.Run("duplicate groups", func(t *testing.T) {
		_, err := NewGroupListEnvelope(ctx, []GroupRef{
			{Name: "dup-group", Type: "Selector"},
			{Name: "dup-group", Type: "Direct"},
		})
		assertErrorCode(t, err, ErrCodeDuplicateName)
		assertNoLeak(t, err, "dup-group")
	})

	t.Run("group count overflow", func(t *testing.T) {
		_, err := NewGroupListEnvelope(ctx, makeGroupRefs(MaxGroupCount+1))
		assertErrorCode(t, err, ErrCodeGroupCountExceeded)
	})
}

func TestEnvelopeMarshalJSONBytesProducesClosedSchemas(t *testing.T) {
	ctx := validQueryContext(nil)

	listEnvelope, err := NewGroupListEnvelope(ctx, []GroupRef{
		{Name: "group-a", Type: "Selector"},
		{Name: "group-b", Type: "Direct"},
	})
	if err != nil {
		t.Fatalf("NewGroupListEnvelope() unexpected error: %v", err)
	}
	listPayload, err := listEnvelope.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	assertTopLevelKeys(t, listPayload, "generation", "groups", "kind", "profileHash", "revisionHash", "schemaVersion", "sessionHash")
	assertJSONArrayObjectKeys(t, listPayload, "groups", "name", "type")
	assertJSONField(t, listPayload, "schemaVersion", "1.0.0")
	assertJSONField(t, listPayload, "kind", "GROUP_LIST")
	assertJSONField(t, listPayload, "profileHash", ctx.ProfileHash)
	assertJSONField(t, listPayload, "revisionHash", ctx.RevisionHash)
	assertJSONField(t, listPayload, "generation", float64(ctx.Generation))
	assertJSONNull(t, listPayload, "sessionHash")
	assertForbiddenFieldsAbsent(t, listPayload)

	session := validHash("c")
	ctxWithSession := validQueryContext(&session)
	group := GroupSnapshot{
		Name:         "selector-alpha",
		Type:         "Selector",
		SelectedName: "node-two",
		Nodes: []NodeSummary{
			{Name: "node-one", Type: "Direct"},
			{Name: "node-two", Type: "Reject", Selected: true},
		},
	}

	snapshotEnvelope, err := NewGroupSnapshotEnvelope(ctxWithSession, group)
	if err != nil {
		t.Fatalf("NewGroupSnapshotEnvelope() unexpected error: %v", err)
	}
	group.Nodes[0].Name = "mutated"
	snapshotPayload, err := snapshotEnvelope.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	assertTopLevelKeys(t, snapshotPayload, "generation", "group", "kind", "profileHash", "revisionHash", "schemaVersion", "sessionHash")
	assertJSONObjectKeysAtPath(t, snapshotPayload, "group", "name", "nodes", "selectedName", "type")
	assertJSONArrayObjectKeysAtPath(t, snapshotPayload, "group", "nodes", "isGroup", "name", "selected", "type")
	assertJSONField(t, snapshotPayload, "kind", "GROUP_SNAPSHOT")
	assertJSONField(t, snapshotPayload, "sessionHash", session)
	if strings.Contains(string(snapshotPayload), "mutated") {
		t.Fatal("snapshot envelope retained caller mutation")
	}
	assertForbiddenFieldsAbsent(t, snapshotPayload)

	selectionEnvelope, err := NewSelectionAppliedEnvelope(ctxWithSession, group, "node-one")
	if err != nil {
		t.Fatalf("NewSelectionAppliedEnvelope() unexpected error: %v", err)
	}
	selectionPayload, err := selectionEnvelope.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	assertTopLevelKeys(t, selectionPayload, "generation", "group", "kind", "previousName", "profileHash", "revisionHash", "schemaVersion", "sessionHash")
	assertJSONObjectKeysAtPath(t, selectionPayload, "group", "name", "nodes", "selectedName", "type")
	assertJSONArrayObjectKeysAtPath(t, selectionPayload, "group", "nodes", "isGroup", "name", "selected", "type")
	assertJSONField(t, selectionPayload, "kind", "SELECTION_APPLIED")
	assertJSONField(t, selectionPayload, "previousName", "node-one")
	assertForbiddenFieldsAbsent(t, selectionPayload)
}

func TestEnvelopeConstructorsNormalizeNilSlicesToEmptyJSONArrays(t *testing.T) {
	ctx := validQueryContext(nil)

	listEnvelope, err := NewGroupListEnvelope(ctx, nil)
	if err != nil {
		t.Fatalf("NewGroupListEnvelope() unexpected error: %v", err)
	}
	if listEnvelope.Groups == nil {
		t.Fatal("Groups must normalize nil to empty slice")
	}
	listPayload, err := listEnvelope.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	assertJSONArrayLength(t, listPayload, "groups", 0)

	snapshotEnvelope, err := NewGroupSnapshotEnvelope(ctx, GroupSnapshot{
		Name: "selector-empty",
		Type: "Selector",
	})
	if err != nil {
		t.Fatalf("NewGroupSnapshotEnvelope() unexpected error: %v", err)
	}
	if snapshotEnvelope.Group.Nodes == nil {
		t.Fatal("Nodes must normalize nil to empty slice")
	}
	snapshotPayload, err := snapshotEnvelope.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	assertJSONArrayLengthAtPath(t, snapshotPayload, "group", "nodes", 0)

	selectionEnvelope, err := NewSelectionAppliedEnvelope(ctx, GroupSnapshot{
		Name: "selector-empty",
		Type: "Selector",
	}, "")
	if err != nil {
		t.Fatalf("NewSelectionAppliedEnvelope() unexpected error: %v", err)
	}
	if selectionEnvelope.Group.Nodes == nil {
		t.Fatal("Selection group nodes must normalize nil to empty slice")
	}
	selectionPayload, err := selectionEnvelope.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	assertJSONArrayLengthAtPath(t, selectionPayload, "group", "nodes", 0)
}

func TestMarshalJSONBytesMaximumValidPayloadsStayWithinCap(t *testing.T) {
	t.Run("group list max valid payload remains within cap", func(t *testing.T) {
		envelope, err := NewGroupListEnvelope(validQueryContext(nil), makeWideGroupRefs(MaxGroupCount))
		if err != nil {
			t.Fatalf("NewGroupListEnvelope() unexpected error: %v", err)
		}
		payload, err := envelope.MarshalJSONBytes()
		if err != nil {
			t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
		}
		if len(payload) > MaxResponseBytes {
			t.Fatalf("payload size = %d exceeds cap %d", len(payload), MaxResponseBytes)
		}
	})

	t.Run("group snapshot max valid payload remains within cap", func(t *testing.T) {
		envelope, err := NewGroupSnapshotEnvelope(validQueryContext(nil), makeWideSnapshot())
		if err != nil {
			t.Fatalf("NewGroupSnapshotEnvelope() unexpected error: %v", err)
		}
		payload, err := envelope.MarshalJSONBytes()
		if err != nil {
			t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
		}
		if len(payload) > MaxResponseBytes {
			t.Fatalf("payload size = %d exceeds cap %d", len(payload), MaxResponseBytes)
		}
	})

	t.Run("selection applied max valid payload remains within cap", func(t *testing.T) {
		group := makeWideSnapshot()
		envelope, err := NewSelectionAppliedEnvelope(validQueryContext(nil), group, makeWidePreviousName())
		if err != nil {
			t.Fatalf("NewSelectionAppliedEnvelope() unexpected error: %v", err)
		}
		payload, err := envelope.MarshalJSONBytes()
		if err != nil {
			t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
		}
		if len(payload) > MaxResponseBytes {
			t.Fatalf("payload size = %d exceeds cap %d", len(payload), MaxResponseBytes)
		}
	})
}

func TestInternalResponseSizeCapRejectsMaxResponseBytesPlusOne(t *testing.T) {
	payload := make([]byte, MaxResponseBytes+1)
	err := validateResponseSize(payload, MaxResponseBytes)
	assertErrorCode(t, err, ErrCodeResponseTooLarge)
}

func TestPublicMarshalCannotReachOverflowUnderPinnedBounds(t *testing.T) {
	// Under the pinned MaxGroupCount/MaxMemberCount/MaxNameUTF8Bytes bounds, the largest
	// valid success payload remains below MaxResponseBytes, so the public overflow branch
	// cannot be hit without weakening model validity or adding a test-only seam.
	for _, payload := range [][]byte{
		mustMarshalPayload(t, mustNewGroupListEnvelope(t, validQueryContext(nil), makeWideGroupRefs(MaxGroupCount))),
		mustMarshalPayload(t, mustNewGroupSnapshotEnvelope(t, validQueryContext(nil), makeWideSnapshot())),
		mustMarshalPayload(t, mustNewSelectionAppliedEnvelope(t, validQueryContext(nil), makeWideSnapshot(), makeWidePreviousName())),
	} {
		if len(payload) > MaxResponseBytes {
			t.Fatalf("expected valid payload <= cap, got %d > %d", len(payload), MaxResponseBytes)
		}
	}
}

func validQueryContext(session *string) QueryContext {
	return QueryContext{
		ProfileHash:  validHash("a"),
		RevisionHash: validHash("b"),
		SessionHash:  session,
		Generation:   1,
	}
}

func validHash(char string) string {
	return strings.Repeat(char, 64)
}

func strPtr(value string) *string {
	return &value
}

func makeGroupRefs(count int) []GroupRef {
	groups := make([]GroupRef, 0, count)
	for i := 0; i < count; i++ {
		groups = append(groups, GroupRef{
			Name: fmt.Sprintf("group-%04d", i),
			Type: "Selector",
		})
	}
	return groups
}

func makeWideGroupRefs(count int) []GroupRef {
	groups := make([]GroupRef, 0, count)
	for i := 0; i < count; i++ {
		groups = append(groups, GroupRef{
			Name: makeWideName(i),
			Type: "Selector",
		})
	}
	return groups
}

func makeNodeSummaries(count int) []NodeSummary {
	nodes := make([]NodeSummary, 0, count)
	for i := 0; i < count; i++ {
		nodes = append(nodes, NodeSummary{
			Name: fmt.Sprintf("node-%04d", i),
			Type: "Direct",
		})
	}
	return nodes
}

func makeWideName(index int) string {
	base := fmt.Sprintf("node-%04d-", index)
	width := MaxNameUTF8Bytes - len(base)
	if width < 1 {
		width = 1
	}
	return base + strings.Repeat("x", width)
}

func makeWideSnapshot() GroupSnapshot {
	nodes := make([]NodeSummary, 0, MaxMemberCount)
	for i := 0; i < MaxMemberCount; i++ {
		nodes = append(nodes, NodeSummary{
			Name:     makeWideName(i),
			Type:     "Shadowsocks",
			Selected: i == MaxMemberCount-1,
		})
	}
	return GroupSnapshot{
		Name:         makeWideGroupName(),
		Type:         "Selector",
		SelectedName: nodes[len(nodes)-1].Name,
		Nodes:        nodes,
	}
}

func makeWideGroupName() string {
	return strings.Repeat("g", MaxNameUTF8Bytes)
}

func makeWidePreviousName() string {
	return strings.Repeat("p", MaxNameUTF8Bytes)
}

func mustNewGroupListEnvelope(t *testing.T, ctx QueryContext, groups []GroupRef) GroupListEnvelope {
	t.Helper()
	envelope, err := NewGroupListEnvelope(ctx, groups)
	if err != nil {
		t.Fatalf("NewGroupListEnvelope() unexpected error: %v", err)
	}
	return envelope
}

func mustNewGroupSnapshotEnvelope(t *testing.T, ctx QueryContext, group GroupSnapshot) GroupSnapshotEnvelope {
	t.Helper()
	envelope, err := NewGroupSnapshotEnvelope(ctx, group)
	if err != nil {
		t.Fatalf("NewGroupSnapshotEnvelope() unexpected error: %v", err)
	}
	return envelope
}

func mustNewSelectionAppliedEnvelope(t *testing.T, ctx QueryContext, group GroupSnapshot, previousName string) SelectionAppliedEnvelope {
	t.Helper()
	envelope, err := NewSelectionAppliedEnvelope(ctx, group, previousName)
	if err != nil {
		t.Fatalf("NewSelectionAppliedEnvelope() unexpected error: %v", err)
	}
	return envelope
}

func mustMarshalPayload(t *testing.T, marshaler interface{ MarshalJSONBytes() ([]byte, error) }) []byte {
	t.Helper()
	payload, err := marshaler.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	return payload
}

func assertErrorCode(t *testing.T, err error, code ErrorCode) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error code %q, got nil", code)
	}

	var modelErr *ModelError
	if !errors.As(err, &modelErr) {
		t.Fatalf("expected ModelError, got %T (%v)", err, err)
	}
	if modelErr.Code != code {
		t.Fatalf("error code = %q want %q", modelErr.Code, code)
	}
}

func assertNoLeak(t *testing.T, err error, tokens ...string) {
	t.Helper()
	if err == nil {
		t.Fatal("expected non-nil error")
	}

	text := err.Error()
	for _, token := range tokens {
		if token == "" {
			continue
		}
		if strings.Contains(text, token) {
			t.Fatalf("error leaked raw token %q in %q", token, text)
		}
	}
}

func assertTopLevelKeys(t *testing.T, payload []byte, keys ...string) {
	t.Helper()
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("json.Unmarshal() failed: %v", err)
	}
	if len(decoded) != len(keys) {
		t.Fatalf("top-level key count = %d want %d", len(decoded), len(keys))
	}
	for _, key := range keys {
		if _, ok := decoded[key]; !ok {
			t.Fatalf("missing top-level key %q", key)
		}
	}
}

func assertJSONObjectKeysAtPath(t *testing.T, payload []byte, objectKey string, keys ...string) {
	t.Helper()
	root := decodeJSONObject(t, payload)
	raw, ok := root[objectKey]
	if !ok {
		t.Fatalf("missing object key %q", objectKey)
	}
	assertRawObjectKeys(t, raw, keys...)
}

func assertJSONArrayObjectKeys(t *testing.T, payload []byte, arrayKey string, keys ...string) {
	t.Helper()
	root := decodeJSONObject(t, payload)
	raw, ok := root[arrayKey]
	if !ok {
		t.Fatalf("missing array key %q", arrayKey)
	}
	assertRawArrayObjectKeys(t, raw, keys...)
}

func assertJSONArrayObjectKeysAtPath(t *testing.T, payload []byte, objectKey, arrayKey string, keys ...string) {
	t.Helper()
	root := decodeJSONObject(t, payload)
	rawObject, ok := root[objectKey]
	if !ok {
		t.Fatalf("missing object key %q", objectKey)
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(rawObject, &object); err != nil {
		t.Fatalf("json.Unmarshal(%q) failed: %v", objectKey, err)
	}
	rawArray, ok := object[arrayKey]
	if !ok {
		t.Fatalf("missing nested array key %q", arrayKey)
	}
	assertRawArrayObjectKeys(t, rawArray, keys...)
}

func assertJSONArrayLength(t *testing.T, payload []byte, arrayKey string, want int) {
	t.Helper()
	root := decodeJSONObject(t, payload)
	raw, ok := root[arrayKey]
	if !ok {
		t.Fatalf("missing array key %q", arrayKey)
	}
	assertRawArrayLength(t, raw, want)
}

func assertJSONArrayLengthAtPath(t *testing.T, payload []byte, objectKey, arrayKey string, want int) {
	t.Helper()
	root := decodeJSONObject(t, payload)
	rawObject, ok := root[objectKey]
	if !ok {
		t.Fatalf("missing object key %q", objectKey)
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(rawObject, &object); err != nil {
		t.Fatalf("json.Unmarshal(%q) failed: %v", objectKey, err)
	}
	rawArray, ok := object[arrayKey]
	if !ok {
		t.Fatalf("missing nested array key %q", arrayKey)
	}
	assertRawArrayLength(t, rawArray, want)
}

func assertJSONField(t *testing.T, payload []byte, key string, want any) {
	t.Helper()
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("json.Unmarshal() failed: %v", err)
	}
	got, ok := decoded[key]
	if !ok {
		t.Fatalf("missing key %q", key)
	}
	if fmt.Sprintf("%v", got) != fmt.Sprintf("%v", want) {
		t.Fatalf("json field %q = %v want %v", key, got, want)
	}
}

func assertJSONNull(t *testing.T, payload []byte, key string) {
	t.Helper()
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("json.Unmarshal() failed: %v", err)
	}
	raw, ok := decoded[key]
	if !ok {
		t.Fatalf("missing key %q", key)
	}
	if string(raw) != "null" {
		t.Fatalf("json field %q = %s want null", key, string(raw))
	}
}

func assertForbiddenFieldsAbsent(t *testing.T, payload []byte) {
	t.Helper()
	for _, forbidden := range []string{
		"\"server\"",
		"\"port\"",
		"\"uuid\"",
		"\"password\"",
		"\"token\"",
		"\"transport\"",
		"\"certificate\"",
		"\"provider\"",
		"\"delay\"",
		"\"url\"",
	} {
		if strings.Contains(string(payload), forbidden) {
			t.Fatalf("payload unexpectedly contains forbidden field %s", forbidden)
		}
	}
}

func decodeJSONObject(t *testing.T, payload []byte) map[string]json.RawMessage {
	t.Helper()
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("json.Unmarshal() failed: %v", err)
	}
	return decoded
}

func assertRawObjectKeys(t *testing.T, raw json.RawMessage, keys ...string) {
	t.Helper()
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal(object) failed: %v", err)
	}
	if len(decoded) != len(keys) {
		t.Fatalf("object key count = %d want %d", len(decoded), len(keys))
	}
	for _, key := range keys {
		if _, ok := decoded[key]; !ok {
			t.Fatalf("missing object key %q", key)
		}
	}
}

func assertRawArrayObjectKeys(t *testing.T, raw json.RawMessage, keys ...string) {
	t.Helper()
	var decoded []json.RawMessage
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal(array) failed: %v", err)
	}
	for i, item := range decoded {
		var object map[string]json.RawMessage
		if err := json.Unmarshal(item, &object); err != nil {
			t.Fatalf("json.Unmarshal(array[%d]) failed: %v", i, err)
		}
		if len(object) != len(keys) {
			t.Fatalf("array[%d] key count = %d want %d", i, len(object), len(keys))
		}
		for _, key := range keys {
			if _, ok := object[key]; !ok {
				t.Fatalf("array[%d] missing key %q", i, key)
			}
		}
	}
}

func assertRawArrayLength(t *testing.T, raw json.RawMessage, want int) {
	t.Helper()
	var decoded []json.RawMessage
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal(array) failed: %v", err)
	}
	if len(decoded) != want {
		t.Fatalf("array length = %d want %d", len(decoded), want)
	}
}
