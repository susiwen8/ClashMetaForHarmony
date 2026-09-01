package proxygroups

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestDelayModelConstantsAndValidation(t *testing.T) {
	if DelaySchemaVersion != "1.0.0" {
		t.Fatalf("DelaySchemaVersion = %q want %q", DelaySchemaVersion, "1.0.0")
	}
	if MaxDelayJobIDBytes != 32 {
		t.Fatalf("MaxDelayJobIDBytes = %d want 32", MaxDelayJobIDBytes)
	}
	if DelayWorkerCount != 16 {
		t.Fatalf("DelayWorkerCount = %d want 16", DelayWorkerCount)
	}
	if DelayNodeTimeout != 5*time.Second {
		t.Fatalf("DelayNodeTimeout = %v want %v", DelayNodeTimeout, 5*time.Second)
	}
	if DefaultDelayTestURL != "https://www.gstatic.com/generate_204" {
		t.Fatalf("DefaultDelayTestURL = %q want %q", DefaultDelayTestURL, "https://www.gstatic.com/generate_204")
	}

	t.Run("constructor rejects invalid inputs", func(t *testing.T) {
		ctx := validQueryContext(nil)

		_, err := NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes-1), DelayJobStateRunning, "group-a", nil)
		if err == nil {
			t.Fatal("expected invalid job id to fail")
		}

		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobState("BROKEN"), "group-a", nil)
		if err == nil {
			t.Fatal("expected invalid job state to fail")
		}

		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, strings.Repeat("g", MaxNameUTF8Bytes+1), nil)
		if err == nil {
			t.Fatal("expected oversized group name to fail")
		}

		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "group-a", makeDelayNodes(MaxMemberCount+1))
		if err == nil {
			t.Fatal("expected node overflow to fail")
		}

		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "group-a", []DelayNodeResult{
			{Index: 0, Name: strings.Repeat("n", MaxNameUTF8Bytes+1), Type: "Direct", State: DelayNodeStateUnsupported},
		})
		if err == nil {
			t.Fatal("expected oversized node name to fail")
		}

		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "group-a", []DelayNodeResult{
			{Index: 0, Name: "node-a", Type: "FutureType", State: DelayNodeStateUnsupported},
		})
		if err == nil {
			t.Fatal("expected unknown node type to fail")
		}

		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "group-a", []DelayNodeResult{
			{Index: 1, Name: "node-a", Type: "Direct", State: DelayNodeStateUnsupported},
		})
		if err == nil {
			t.Fatal("expected non-contiguous index to fail")
		}

		zero := uint16(0)
		fallback := DelayURLSourceFallback
		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "group-a", []DelayNodeResult{
			{Index: 0, Name: "node-a", Type: "Direct", State: DelayNodeStateAvailable, DelayMs: &zero, Source: &fallback},
		})
		if err == nil {
			t.Fatal("expected zero available delay to fail")
		}

		delay := uint16(12)
		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "group-a", []DelayNodeResult{
			{Index: 0, Name: "node-a", Type: "Direct", State: DelayNodeStateTimeout, DelayMs: &delay, Source: &fallback},
		})
		if err == nil {
			t.Fatal("expected non-available delayMs to fail")
		}

		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "group-a", []DelayNodeResult{
			{Index: 0, Name: "node-a", Type: "Direct", State: DelayNodeStateWaiting},
		})
		if err == nil {
			t.Fatal("expected missing source on testable node to fail")
		}

		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "group-a", []DelayNodeResult{
			{Index: 0, Name: "node-a", Type: "Direct", State: DelayNodeStateUnsupported, Source: &fallback},
		})
		if err == nil {
			t.Fatal("expected unsupported node source to fail")
		}

		provider := DelayURLSourceProvider
		_, err = NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-a", []DelayNodeResult{
			{Index: 0, Name: "node-a", Type: "Direct", State: DelayNodeStateTesting, Source: &provider},
		})
		if err == nil {
			t.Fatal("expected terminal job with live node to fail")
		}
	})
}

func TestDelaySnapshotConstructorCanonicalizesAndClones(t *testing.T) {
	session := validHash("c")
	ctx := validQueryContext(&session)
	delayFastA := uint16(12)
	delayFastB := uint16(12)
	delaySlow := uint16(45)
	provider := DelayURLSourceProvider
	fallback := DelayURLSourceFallback
	input := []DelayNodeResult{
		{Index: 0, Name: "node-a", Type: "Direct", State: DelayNodeStateAvailable, DelayMs: &delayFastA, Source: &fallback, Fastest: false},
		{Index: 1, Name: "node-b", Type: "Shadowsocks", State: DelayNodeStateAvailable, DelayMs: &delayFastB, Source: &provider, Fastest: true},
		{Index: 2, Name: "node-c", Type: "Trojan", State: DelayNodeStateTimeout, Source: &provider, Fastest: true},
		{Index: 3, Name: "node-d", Type: "Selector", State: DelayNodeStateWaiting, Source: &fallback},
		{Index: 4, Name: "node-e", Type: "Relay", State: DelayNodeStateTesting, Source: &provider},
		{Index: 5, Name: "node-f", Type: "Http", State: DelayNodeStateFailed, Source: &fallback},
		{Index: 6, Name: "node-g", Type: "Reject", State: DelayNodeStateCancelled, Source: &provider},
		{Index: 7, Name: "node-h", Type: "Dns", State: DelayNodeStateUnsupported},
		{Index: 8, Name: "node-i", Type: "Vmess", State: DelayNodeStateAvailable, DelayMs: &delaySlow, Source: &provider},
	}

	shot, err := NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "delay-group", input)
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}

	if shot.SchemaVersion != DelaySchemaVersion {
		t.Fatalf("SchemaVersion = %q want %q", shot.SchemaVersion, DelaySchemaVersion)
	}
	if shot.ProfileHash != ctx.ProfileHash || shot.RevisionHash != ctx.RevisionHash || shot.Generation != ctx.Generation {
		t.Fatal("query context fields were not echoed into snapshot")
	}
	if shot.SessionHash == nil || *shot.SessionHash != session {
		t.Fatalf("SessionHash = %v want %q", shot.SessionHash, session)
	}
	if shot.TotalCount != len(input) {
		t.Fatalf("TotalCount = %d want %d", shot.TotalCount, len(input))
	}
	if shot.TestableCount != 8 {
		t.Fatalf("TestableCount = %d want 8", shot.TestableCount)
	}
	if shot.CompletedCount != 7 {
		t.Fatalf("CompletedCount = %d want 7", shot.CompletedCount)
	}
	if shot.AvailableCount != 3 || shot.TimeoutCount != 1 || shot.FailedCount != 1 || shot.CancelledCount != 1 || shot.UnsupportedCount != 1 {
		t.Fatalf("unexpected state counters: %+v", shot)
	}
	if shot.FastestNodeIndex == nil || *shot.FastestNodeIndex != 0 {
		t.Fatalf("FastestNodeIndex = %v want 0", shot.FastestNodeIndex)
	}
	for i, node := range shot.Nodes {
		if node.Index != i {
			t.Fatalf("node[%d].Index = %d want %d", i, node.Index, i)
		}
		if node.State == DelayNodeStateAvailable {
			if node.DelayMs == nil || *node.DelayMs == 0 {
				t.Fatalf("node[%d] available delay invalid: %v", i, node.DelayMs)
			}
		} else if node.DelayMs != nil {
			t.Fatalf("node[%d] non-available delay must be nil", i)
		}
		if node.State == DelayNodeStateUnsupported {
			if node.Source != nil {
				t.Fatalf("node[%d] unsupported source must be nil", i)
			}
		} else {
			if node.Source == nil {
				t.Fatalf("node[%d] source must be non-nil", i)
			}
			if *node.Source != DelayURLSourceProvider && *node.Source != DelayURLSourceFallback {
				t.Fatalf("node[%d] invalid source %q", i, *node.Source)
			}
		}
		if wantFastest := i == 0; node.Fastest != wantFastest {
			t.Fatalf("node[%d].Fastest = %v want %v", i, node.Fastest, wantFastest)
		}
	}

	delayFastA = 99
	delayFastB = 98
	delaySlow = 97
	provider = DelayURLSource("BROKEN")
	fallback = DelayURLSource("BROKEN")
	session = validHash("d")
	input[0].Name = "mutated"
	input[0].DelayMs = nil
	input[0].Source = nil
	input[1].Fastest = false
	if shot.Nodes[0].Name != "node-a" {
		t.Fatalf("snapshot retained caller slice mutation: %q", shot.Nodes[0].Name)
	}
	if shot.Nodes[0].DelayMs == nil || *shot.Nodes[0].DelayMs != 12 {
		t.Fatalf("snapshot retained caller delay mutation: %v", shot.Nodes[0].DelayMs)
	}
	if shot.Nodes[0].Source == nil || *shot.Nodes[0].Source != DelayURLSourceFallback {
		t.Fatalf("snapshot retained caller source mutation: %v", shot.Nodes[0].Source)
	}
	if shot.SessionHash == nil || *shot.SessionHash != validHash("c") {
		t.Fatalf("snapshot retained caller session mutation: %v", shot.SessionHash)
	}
}

func TestDelayJSONMarshalAndParseAreClosedAndBounded(t *testing.T) {
	session := validHash("c")
	ctx := validQueryContext(&session)
	delayA := uint16(10)
	delayB := uint16(25)
	provider := DelayURLSourceProvider
	fallback := DelayURLSourceFallback

	shot, err := NewDelayTestSnapshot(ctx, strings.Repeat("a", MaxDelayJobIDBytes), DelayJobStateRunning, "delay-group", []DelayNodeResult{
		{Index: 0, Name: "node-a", Type: "Direct", State: DelayNodeStateAvailable, DelayMs: &delayA, Source: &fallback},
		{Index: 1, Name: "node-b", Type: "Shadowsocks", State: DelayNodeStateAvailable, DelayMs: &delayB, Source: &provider},
		{Index: 2, Name: "node-c", Type: "Selector", State: DelayNodeStateFailed, Source: &provider},
		{Index: 3, Name: "node-d", Type: "Dns", State: DelayNodeStateUnsupported},
	})
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}

	payload, err := shot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	if len(payload) > MaxResponseBytes {
		t.Fatalf("payload size = %d exceeds cap %d", len(payload), MaxResponseBytes)
	}

	assertTopLevelKeys(t, payload,
		"availableCount",
		"cancelledCount",
		"completedCount",
		"failedCount",
		"fastestNodeIndex",
		"generation",
		"groupName",
		"jobId",
		"nodes",
		"profileHash",
		"revisionHash",
		"schemaVersion",
		"sessionHash",
		"state",
		"testableCount",
		"timeoutCount",
		"totalCount",
		"unsupportedCount",
	)
	assertJSONArrayObjectKeys(t, payload, "nodes", "delayMs", "fastest", "index", "name", "source", "state", "type")
	assertJSONField(t, payload, "schemaVersion", DelaySchemaVersion)
	assertJSONField(t, payload, "jobId", strings.Repeat("a", MaxDelayJobIDBytes))
	assertJSONField(t, payload, "profileHash", ctx.ProfileHash)
	assertJSONField(t, payload, "revisionHash", ctx.RevisionHash)
	assertJSONField(t, payload, "generation", float64(ctx.Generation))
	assertJSONField(t, payload, "state", string(DelayJobStateRunning))
	assertForbiddenDelayFieldsAbsent(t, payload)

	parsed, err := ParseDelayTestSnapshotJSON(payload)
	if err != nil {
		t.Fatalf("ParseDelayTestSnapshotJSON() unexpected error: %v", err)
	}
	if parsed.FastestNodeIndex == nil || *parsed.FastestNodeIndex != 0 {
		t.Fatalf("parsed FastestNodeIndex = %v want 0", parsed.FastestNodeIndex)
	}
	if parsed.Nodes[3].Source != nil {
		t.Fatalf("parsed unsupported node source = %v want nil", parsed.Nodes[3].Source)
	}

	cases := []struct {
		name    string
		payload []byte
	}{
		{
			name:    "top level unknown field",
			payload: appendObjectField(payload, `"extra":"x"`),
		},
		{
			name:    "forbidden url field",
			payload: replaceOnce(payload, `"fastest":false}`, `"fastest":false,"url":"https://example.com"}`),
		},
		{
			name:    "forbidden provider field",
			payload: replaceOnce(payload, `"fastest":false}`, `"fastest":false,"provider":"remote"}`),
		},
		{
			name:    "forbidden credential field",
			payload: replaceOnce(payload, `"fastest":false}`, `"fastest":false,`+jsonStringField(strings.Join([]string{"pass", "word"}, ""), "secret")+`}`),
		},
		{
			name:    "unknown job state",
			payload: replaceOnce(payload, `"state":"RUNNING"`, `"state":"BROKEN"`),
		},
		{
			name:    "unknown node state",
			payload: replaceOnce(payload, `"state":"FAILED"`, `"state":"BROKEN"`),
		},
		{
			name:    "unknown source",
			payload: replaceOnce(payload, `"source":"PROVIDER"`, `"source":"BROKEN"`),
		},
		{
			name:    "malformed counts",
			payload: replaceOnce(payload, `"completedCount":4`, `"completedCount":2`),
		},
		{
			name:    "oversized payload",
			payload: bytes.Repeat([]byte("x"), MaxResponseBytes+1),
		},
		{
			name:    "second json document",
			payload: append(append([]byte{}, payload...), []byte(` {}`)...),
		},
		{
			name:    "trailing garbage",
			payload: append(append([]byte{}, payload...), []byte(` x`)...),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParseDelayTestSnapshotJSON(tc.payload)
			if err == nil {
				t.Fatal("expected parse failure")
			}
		})
	}
}

func TestDelayJSONParseRejectsMissingRequiredTopLevelFields(t *testing.T) {
	shot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("e", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-empty", nil)
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	payload, err := shot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}

	for _, field := range []string{
		"schemaVersion",
		"jobId",
		"state",
		"profileHash",
		"revisionHash",
		"sessionHash",
		"generation",
		"groupName",
		"totalCount",
		"testableCount",
		"completedCount",
		"availableCount",
		"timeoutCount",
		"failedCount",
		"cancelledCount",
		"unsupportedCount",
		"fastestNodeIndex",
		"nodes",
	} {
		t.Run(field, func(t *testing.T) {
			mutated, err := omitDelayTopLevelField(payload, field)
			if err != nil {
				t.Fatalf("omitDelayTopLevelField() unexpected error: %v", err)
			}
			_, err = ParseDelayTestSnapshotJSON(mutated)
			if err == nil {
				t.Fatalf("expected missing top-level field %q to fail", field)
			}
		})
	}
}

func TestDelayJSONParseRejectsMissingRequiredNodeFields(t *testing.T) {
	shot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("d", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-node", []DelayNodeResult{
		{Index: 0, Name: "node-unsupported", Type: "Direct", State: DelayNodeStateUnsupported},
	})
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	payload, err := shot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}

	for _, field := range []string{
		"index",
		"name",
		"type",
		"state",
		"delayMs",
		"source",
		"fastest",
	} {
		t.Run(field, func(t *testing.T) {
			mutated, err := omitDelayNodeField(payload, 0, field)
			if err != nil {
				t.Fatalf("omitDelayNodeField() unexpected error: %v", err)
			}
			_, err = ParseDelayTestSnapshotJSON(mutated)
			if err == nil {
				t.Fatalf("expected missing node field %q to fail", field)
			}
		})
	}
}

func TestDelayJSONParseRejectsDuplicateKeys(t *testing.T) {
	emptyShot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("c", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-empty", nil)
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	emptyPayload, err := emptyShot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	duplicateTopLevel, err := duplicateDelayTopLevelField(emptyPayload, "unsupportedCount")
	if err != nil {
		t.Fatalf("duplicateDelayTopLevelField() unexpected error: %v", err)
	}
	if _, err := ParseDelayTestSnapshotJSON(duplicateTopLevel); err == nil {
		t.Fatal("expected duplicate top-level key to fail")
	}

	nodeShot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("b", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-node", []DelayNodeResult{
		{Index: 0, Name: "node-unsupported", Type: "Direct", State: DelayNodeStateUnsupported},
	})
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	nodePayload, err := nodeShot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	duplicateNode, err := duplicateDelayNodeField(nodePayload, 0, "fastest")
	if err != nil {
		t.Fatalf("duplicateDelayNodeField() unexpected error: %v", err)
	}
	if _, err := ParseDelayTestSnapshotJSON(duplicateNode); err == nil {
		t.Fatal("expected duplicate node key to fail")
	}
}

func TestDelayJSONParseRejectsNullNonNullablePrimitiveFields(t *testing.T) {
	emptyShot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("c", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-empty", nil)
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	emptyPayload, err := emptyShot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}

	for _, field := range []string{
		"schemaVersion",
		"jobId",
		"state",
		"profileHash",
		"revisionHash",
		"generation",
		"groupName",
		"totalCount",
		"testableCount",
		"completedCount",
		"availableCount",
		"timeoutCount",
		"failedCount",
		"cancelledCount",
		"unsupportedCount",
	} {
		t.Run("top-level "+field, func(t *testing.T) {
			mutated, err := setDelayTopLevelFieldToNull(emptyPayload, field)
			if err != nil {
				t.Fatalf("setDelayTopLevelFieldToNull() unexpected error: %v", err)
			}
			_, err = ParseDelayTestSnapshotJSON(mutated)
			if err == nil {
				t.Fatalf("expected null top-level field %q to fail", field)
			}
		})
	}

	nodeShot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("b", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-node", []DelayNodeResult{
		{Index: 0, Name: "node-unsupported", Type: "Direct", State: DelayNodeStateUnsupported},
	})
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	nodePayload, err := nodeShot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}

	for _, field := range []string{"index", "name", "type", "state", "fastest"} {
		t.Run("node "+field, func(t *testing.T) {
			mutated, err := setDelayNodeFieldToNull(nodePayload, 0, field)
			if err != nil {
				t.Fatalf("setDelayNodeFieldToNull() unexpected error: %v", err)
			}
			_, err = ParseDelayTestSnapshotJSON(mutated)
			if err == nil {
				t.Fatalf("expected null node field %q to fail", field)
			}
		})
	}
}

func TestDelayJSONParseAllowsNullableNullFields(t *testing.T) {
	emptyShot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("c", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-empty", nil)
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	emptyPayload, err := emptyShot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}

	for _, field := range []string{"sessionHash", "fastestNodeIndex"} {
		t.Run("top-level "+field, func(t *testing.T) {
			mutated, err := setDelayTopLevelFieldToNull(emptyPayload, field)
			if err != nil {
				t.Fatalf("setDelayTopLevelFieldToNull() unexpected error: %v", err)
			}
			if _, err := ParseDelayTestSnapshotJSON(mutated); err != nil {
				t.Fatalf("expected nullable top-level field %q to accept null: %v", field, err)
			}
		})
	}

	nodeShot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("b", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-node", []DelayNodeResult{
		{Index: 0, Name: "node-unsupported", Type: "Direct", State: DelayNodeStateUnsupported},
	})
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	nodePayload, err := nodeShot.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}

	for _, field := range []string{"delayMs", "source"} {
		t.Run("node "+field, func(t *testing.T) {
			mutated, err := setDelayNodeFieldToNull(nodePayload, 0, field)
			if err != nil {
				t.Fatalf("setDelayNodeFieldToNull() unexpected error: %v", err)
			}
			if _, err := ParseDelayTestSnapshotJSON(mutated); err != nil {
				t.Fatalf("expected nullable node field %q to accept null: %v", field, err)
			}
		})
	}
}

func makeDelayNodes(count int) []DelayNodeResult {
	nodes := make([]DelayNodeResult, 0, count)
	for i := 0; i < count; i++ {
		nodes = append(nodes, DelayNodeResult{
			Index: i,
			Name:  "node-" + strings.Repeat("x", 8),
			Type:  "Direct",
			State: DelayNodeStateUnsupported,
		})
	}
	return nodes
}

func assertForbiddenDelayFieldsAbsent(t *testing.T, payload []byte) {
	t.Helper()
	for _, forbidden := range []string{
		"\"provider\"",
		"\"providerName\"",
		"\"providerIdentity\"",
		"\"url\"",
		"\"testUrl\"",
		"\"endpoint\"",
		"\"server\"",
		"\"port\"",
		"\"host\"",
		"\"uuid\"",
		"\"username\"",
		jsonQuotedKey(strings.Join([]string{"pass", "word"}, "")),
		"\"token\"",
		"\"secret\"",
		"\"selected\"",
		"\"selectedName\"",
		"\"failure\"",
		"\"reason\"",
	} {
		if strings.Contains(string(payload), forbidden) {
			t.Fatalf("payload unexpectedly contains forbidden field %s", forbidden)
		}
	}
}

func appendObjectField(payload []byte, rawField string) []byte {
	return append([]byte(strings.TrimSuffix(string(payload), "}")), []byte(","+rawField+"}")...)
}

func replaceOnce(payload []byte, from, to string) []byte {
	return []byte(strings.Replace(string(payload), from, to, 1))
}

func jsonStringField(key, value string) string {
	return jsonQuotedKey(key) + ":" + jsonQuotedValue(value)
}

func jsonQuotedKey(key string) string {
	return jsonQuotedValue(key)
}

func jsonQuotedValue(value string) string {
	return `"` + value + `"`
}

type delayTestSnapshotFieldSet struct {
	SchemaVersion    *json.RawMessage `json:"schemaVersion,omitempty"`
	JobID            *json.RawMessage `json:"jobId,omitempty"`
	State            *json.RawMessage `json:"state,omitempty"`
	ProfileHash      *json.RawMessage `json:"profileHash,omitempty"`
	RevisionHash     *json.RawMessage `json:"revisionHash,omitempty"`
	SessionHash      *json.RawMessage `json:"sessionHash,omitempty"`
	Generation       *json.RawMessage `json:"generation,omitempty"`
	GroupName        *json.RawMessage `json:"groupName,omitempty"`
	TotalCount       *json.RawMessage `json:"totalCount,omitempty"`
	TestableCount    *json.RawMessage `json:"testableCount,omitempty"`
	CompletedCount   *json.RawMessage `json:"completedCount,omitempty"`
	AvailableCount   *json.RawMessage `json:"availableCount,omitempty"`
	TimeoutCount     *json.RawMessage `json:"timeoutCount,omitempty"`
	FailedCount      *json.RawMessage `json:"failedCount,omitempty"`
	CancelledCount   *json.RawMessage `json:"cancelledCount,omitempty"`
	UnsupportedCount *json.RawMessage `json:"unsupportedCount,omitempty"`
	FastestNodeIndex *json.RawMessage `json:"fastestNodeIndex,omitempty"`
	Nodes            *json.RawMessage `json:"nodes,omitempty"`
}

type delayNodeFieldSet struct {
	Index   *json.RawMessage `json:"index,omitempty"`
	Name    *json.RawMessage `json:"name,omitempty"`
	Type    *json.RawMessage `json:"type,omitempty"`
	State   *json.RawMessage `json:"state,omitempty"`
	DelayMs *json.RawMessage `json:"delayMs,omitempty"`
	Source  *json.RawMessage `json:"source,omitempty"`
	Fastest *json.RawMessage `json:"fastest,omitempty"`
}

func omitDelayTopLevelField(payload []byte, field string) ([]byte, error) {
	var decoded delayTestSnapshotFieldSet
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, err
	}
	switch field {
	case "schemaVersion":
		decoded.SchemaVersion = nil
	case "jobId":
		decoded.JobID = nil
	case "state":
		decoded.State = nil
	case "profileHash":
		decoded.ProfileHash = nil
	case "revisionHash":
		decoded.RevisionHash = nil
	case "sessionHash":
		decoded.SessionHash = nil
	case "generation":
		decoded.Generation = nil
	case "groupName":
		decoded.GroupName = nil
	case "totalCount":
		decoded.TotalCount = nil
	case "testableCount":
		decoded.TestableCount = nil
	case "completedCount":
		decoded.CompletedCount = nil
	case "availableCount":
		decoded.AvailableCount = nil
	case "timeoutCount":
		decoded.TimeoutCount = nil
	case "failedCount":
		decoded.FailedCount = nil
	case "cancelledCount":
		decoded.CancelledCount = nil
	case "unsupportedCount":
		decoded.UnsupportedCount = nil
	case "fastestNodeIndex":
		decoded.FastestNodeIndex = nil
	case "nodes":
		decoded.Nodes = nil
	default:
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}
	return json.Marshal(decoded)
}

func omitDelayNodeField(payload []byte, nodeIndex int, field string) ([]byte, error) {
	var topLevel delayTestSnapshotFieldSet
	if err := json.Unmarshal(payload, &topLevel); err != nil {
		return nil, err
	}
	if topLevel.Nodes == nil {
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}

	var nodes []delayNodeFieldSet
	if err := json.Unmarshal(*topLevel.Nodes, &nodes); err != nil {
		return nil, err
	}
	if nodeIndex < 0 || nodeIndex >= len(nodes) {
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}

	switch field {
	case "index":
		nodes[nodeIndex].Index = nil
	case "name":
		nodes[nodeIndex].Name = nil
	case "type":
		nodes[nodeIndex].Type = nil
	case "state":
		nodes[nodeIndex].State = nil
	case "delayMs":
		nodes[nodeIndex].DelayMs = nil
	case "source":
		nodes[nodeIndex].Source = nil
	case "fastest":
		nodes[nodeIndex].Fastest = nil
	default:
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}

	rawNodes, err := json.Marshal(nodes)
	if err != nil {
		return nil, err
	}
	raw := json.RawMessage(rawNodes)
	topLevel.Nodes = &raw
	return json.Marshal(topLevel)
}

func setDelayTopLevelFieldToNull(payload []byte, field string) ([]byte, error) {
	var decoded delayTestSnapshotFieldSet
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, err
	}
	ensureNullableDelayTopLevelFieldsPresent(&decoded)
	nullRaw := json.RawMessage("null")
	switch field {
	case "schemaVersion":
		decoded.SchemaVersion = &nullRaw
	case "jobId":
		decoded.JobID = &nullRaw
	case "state":
		decoded.State = &nullRaw
	case "profileHash":
		decoded.ProfileHash = &nullRaw
	case "revisionHash":
		decoded.RevisionHash = &nullRaw
	case "sessionHash":
		decoded.SessionHash = &nullRaw
	case "generation":
		decoded.Generation = &nullRaw
	case "groupName":
		decoded.GroupName = &nullRaw
	case "totalCount":
		decoded.TotalCount = &nullRaw
	case "testableCount":
		decoded.TestableCount = &nullRaw
	case "completedCount":
		decoded.CompletedCount = &nullRaw
	case "availableCount":
		decoded.AvailableCount = &nullRaw
	case "timeoutCount":
		decoded.TimeoutCount = &nullRaw
	case "failedCount":
		decoded.FailedCount = &nullRaw
	case "cancelledCount":
		decoded.CancelledCount = &nullRaw
	case "unsupportedCount":
		decoded.UnsupportedCount = &nullRaw
	case "fastestNodeIndex":
		decoded.FastestNodeIndex = &nullRaw
	case "nodes":
		decoded.Nodes = &nullRaw
	default:
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}
	return json.Marshal(decoded)
}

func setDelayNodeFieldToNull(payload []byte, nodeIndex int, field string) ([]byte, error) {
	var topLevel delayTestSnapshotFieldSet
	if err := json.Unmarshal(payload, &topLevel); err != nil {
		return nil, err
	}
	ensureNullableDelayTopLevelFieldsPresent(&topLevel)
	if topLevel.Nodes == nil {
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}

	var nodes []delayNodeFieldSet
	if err := json.Unmarshal(*topLevel.Nodes, &nodes); err != nil {
		return nil, err
	}
	if nodeIndex < 0 || nodeIndex >= len(nodes) {
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}

	ensureNullableDelayNodeFieldsPresent(&nodes[nodeIndex])
	nullRaw := json.RawMessage("null")
	switch field {
	case "index":
		nodes[nodeIndex].Index = &nullRaw
	case "name":
		nodes[nodeIndex].Name = &nullRaw
	case "type":
		nodes[nodeIndex].Type = &nullRaw
	case "state":
		nodes[nodeIndex].State = &nullRaw
	case "delayMs":
		nodes[nodeIndex].DelayMs = &nullRaw
	case "source":
		nodes[nodeIndex].Source = &nullRaw
	case "fastest":
		nodes[nodeIndex].Fastest = &nullRaw
	default:
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}

	rawNodes, err := json.Marshal(nodes)
	if err != nil {
		return nil, err
	}
	raw := json.RawMessage(rawNodes)
	topLevel.Nodes = &raw
	return json.Marshal(topLevel)
}

func duplicateDelayTopLevelField(payload []byte, field string) ([]byte, error) {
	var decoded delayTestSnapshotFieldSet
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, err
	}
	raw, err := selectDelayTopLevelFieldRaw(decoded, field)
	if err != nil {
		return nil, err
	}
	return appendObjectField(payload, `"`+field+`":`+string(raw)), nil
}

func duplicateDelayNodeField(payload []byte, nodeIndex int, field string) ([]byte, error) {
	var topLevel delayTestSnapshotFieldSet
	if err := json.Unmarshal(payload, &topLevel); err != nil {
		return nil, err
	}
	ensureNullableDelayTopLevelFieldsPresent(&topLevel)
	if topLevel.Nodes == nil {
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}

	var nodes []json.RawMessage
	if err := json.Unmarshal(*topLevel.Nodes, &nodes); err != nil {
		return nil, err
	}
	if nodeIndex < 0 || nodeIndex >= len(nodes) {
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}

	var node delayNodeFieldSet
	if err := json.Unmarshal(nodes[nodeIndex], &node); err != nil {
		return nil, err
	}
	ensureNullableDelayNodeFieldsPresent(&node)
	raw, err := selectDelayNodeFieldRaw(node, field)
	if err != nil {
		return nil, err
	}
	nodes[nodeIndex] = appendObjectField(nodes[nodeIndex], `"`+field+`":`+string(raw))
	rawNodes, err := json.Marshal(nodes)
	if err != nil {
		return nil, err
	}
	rawArray := json.RawMessage(rawNodes)
	topLevel.Nodes = &rawArray
	return json.Marshal(topLevel)
}

func selectDelayTopLevelFieldRaw(decoded delayTestSnapshotFieldSet, field string) (json.RawMessage, error) {
	switch field {
	case "schemaVersion":
		return derefRawMessage(decoded.SchemaVersion)
	case "jobId":
		return derefRawMessage(decoded.JobID)
	case "state":
		return derefRawMessage(decoded.State)
	case "profileHash":
		return derefRawMessage(decoded.ProfileHash)
	case "revisionHash":
		return derefRawMessage(decoded.RevisionHash)
	case "sessionHash":
		return derefRawMessage(decoded.SessionHash)
	case "generation":
		return derefRawMessage(decoded.Generation)
	case "groupName":
		return derefRawMessage(decoded.GroupName)
	case "totalCount":
		return derefRawMessage(decoded.TotalCount)
	case "testableCount":
		return derefRawMessage(decoded.TestableCount)
	case "completedCount":
		return derefRawMessage(decoded.CompletedCount)
	case "availableCount":
		return derefRawMessage(decoded.AvailableCount)
	case "timeoutCount":
		return derefRawMessage(decoded.TimeoutCount)
	case "failedCount":
		return derefRawMessage(decoded.FailedCount)
	case "cancelledCount":
		return derefRawMessage(decoded.CancelledCount)
	case "unsupportedCount":
		return derefRawMessage(decoded.UnsupportedCount)
	case "fastestNodeIndex":
		return derefRawMessage(decoded.FastestNodeIndex)
	case "nodes":
		return derefRawMessage(decoded.Nodes)
	default:
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}
}

func selectDelayNodeFieldRaw(decoded delayNodeFieldSet, field string) (json.RawMessage, error) {
	switch field {
	case "index":
		return derefRawMessage(decoded.Index)
	case "name":
		return derefRawMessage(decoded.Name)
	case "type":
		return derefRawMessage(decoded.Type)
	case "state":
		return derefRawMessage(decoded.State)
	case "delayMs":
		return derefRawMessage(decoded.DelayMs)
	case "source":
		return derefRawMessage(decoded.Source)
	case "fastest":
		return derefRawMessage(decoded.Fastest)
	default:
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}
}

func derefRawMessage(raw *json.RawMessage) (json.RawMessage, error) {
	if raw == nil {
		return nil, &ModelError{Code: ErrCodeInvalidEnvelope}
	}
	return append(json.RawMessage(nil), *raw...), nil
}

func ensureNullableDelayTopLevelFieldsPresent(decoded *delayTestSnapshotFieldSet) {
	nullRaw := json.RawMessage("null")
	if decoded.SessionHash == nil {
		decoded.SessionHash = &nullRaw
	}
	if decoded.FastestNodeIndex == nil {
		nullCopy := json.RawMessage("null")
		decoded.FastestNodeIndex = &nullCopy
	}
}

func ensureNullableDelayNodeFieldsPresent(decoded *delayNodeFieldSet) {
	nullRaw := json.RawMessage("null")
	if decoded.DelayMs == nil {
		decoded.DelayMs = &nullRaw
	}
	if decoded.Source == nil {
		nullCopy := json.RawMessage("null")
		decoded.Source = &nullCopy
	}
}

func TestDelayJSONRoundTripUsesExactSchema(t *testing.T) {
	delay := uint16(9)
	provider := DelayURLSourceProvider
	shot, err := NewDelayTestSnapshot(validQueryContext(nil), strings.Repeat("f", MaxDelayJobIDBytes), DelayJobStateCompleted, "group-a", []DelayNodeResult{
		{Index: 0, Name: "node-a", Type: "Direct", State: DelayNodeStateAvailable, DelayMs: &delay, Source: &provider},
	})
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	payload, err := json.Marshal(shot)
	if err != nil {
		t.Fatalf("json.Marshal() unexpected error: %v", err)
	}
	parsed, err := ParseDelayTestSnapshotJSON(payload)
	if err != nil {
		t.Fatalf("ParseDelayTestSnapshotJSON() unexpected error: %v", err)
	}
	if parsed.TotalCount != 1 || parsed.AvailableCount != 1 || parsed.CompletedCount != 1 {
		t.Fatalf("unexpected parsed counters: %+v", parsed)
	}
}
