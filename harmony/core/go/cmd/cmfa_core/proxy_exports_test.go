package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	proxygroupspkg "github.com/clashmetaforandroid/harmony/core/go/internal/proxygroups"
)

func TestProxyExportSourceDeclaresRawSymbols(t *testing.T) {
	sourcePath := filepath.Join("main.go")
	source, err := os.ReadFile(sourcePath)
	if err != nil {
		t.Fatalf("os.ReadFile(%q) failed: %v", sourcePath, err)
	}
	text := string(source)

	wantSubstrings := []string{
		"//export cmfa_mihomo_proxy_groups_v1",
		"func cmfa_mihomo_proxy_groups_v1(",
		"generation C.uint64_t",
		"selectableOnly C.uint8_t",
		"outputLength *C.size_t",
		"//export cmfa_mihomo_proxy_group_v1",
		"func cmfa_mihomo_proxy_group_v1(",
		"groupName *C.char",
		"//export cmfa_mihomo_proxy_select_v1",
		"func cmfa_mihomo_proxy_select_v1(",
		"memberName *C.char",
		"proxygroups.NewService(nil)",
		"//export cmfa_mihomo_proxy_delay_start_v1",
		"func cmfa_mihomo_proxy_delay_start_v1(",
		"//export cmfa_mihomo_proxy_delay_snapshot_v1",
		"func cmfa_mihomo_proxy_delay_snapshot_v1(",
		"//export cmfa_mihomo_proxy_delay_cancel_v1",
		"func cmfa_mihomo_proxy_delay_cancel_v1(",
		"proxygroups.NewMihomoDelayJobManager()",
		"CancelActiveAndDrain()",
	}
	for _, want := range wantSubstrings {
		if !strings.Contains(text, want) {
			t.Fatalf("main.go missing %q", want)
		}
	}
}

func TestProxyExportBufferContractRejectsMissingOutputRequirements(t *testing.T) {
	request := validProxyGroupsRequest()
	var calls atomic.Int32
	replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
		listGroupsFn: func(ctx proxygroupspkg.QueryContext, selectableOnly bool) ([]byte, error) {
			calls.Add(1)
			return mustListGroupsPayload(t, ctx), nil
		},
	})

	for _, tc := range []struct {
		name         string
		output       []byte
		outputLength *uint64
	}{
		{name: "nil output buffer", output: nil, outputLength: uint64Ptr(7)},
		{name: "zero capacity", output: []byte{}, outputLength: uint64Ptr(7)},
		{name: "nil length pointer", output: []byte{0xaa, 0xbb, 0xcc}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			result := executeProxyGroupsExport(request, proxyRawExportBuffer{
				output:       tc.output,
				outputLength: tc.outputLength,
			})
			assertProxyExportResult(t, result, proxyRawExportStatusInvalidArgument, string(proxygroupspkg.ErrCodeProxyBridgeInvalid))
			if tc.outputLength != nil && *tc.outputLength != 0 {
				t.Fatalf("output length = %d want 0", *tc.outputLength)
			}
			if len(tc.output) > 0 && tc.output[0] != 0 {
				t.Fatalf("output[0] = %#x want NUL", tc.output[0])
			}
		})
	}

	if got := calls.Load(); got != 0 {
		t.Fatalf("service called %d times for invalid buffer contract", got)
	}
}

func TestExecuteProxyGroupsExportRejectsInvalidQueryInputs(t *testing.T) {
	request := validProxyGroupsRequest()
	replaceProxygroupsServiceForTest(t, panicProxygroupsService{})

	cases := []struct {
		name       string
		mutate     func(*proxyRawExportRequest)
		wantStatus proxyRawExportStatus
	}{
		{
			name: "nil profile hash",
			mutate: func(req *proxyRawExportRequest) {
				req.profileHash = nil
			},
			wantStatus: proxyRawExportStatusInvalidArgument,
		},
		{
			name: "invalid utf8 profile hash",
			mutate: func(req *proxyRawExportRequest) {
				req.profileHash = stringPtr(string([]byte{0xff, 0xfe}))
			},
			wantStatus: proxyRawExportStatusInvalidUTF8,
		},
		{
			name: "invalid profile hash format",
			mutate: func(req *proxyRawExportRequest) {
				req.profileHash = stringPtr("short")
			},
			wantStatus: proxyRawExportStatusInvalidArgument,
		},
		{
			name: "invalid utf8 revision hash",
			mutate: func(req *proxyRawExportRequest) {
				req.revisionHash = stringPtr(string([]byte{0xff}))
			},
			wantStatus: proxyRawExportStatusInvalidUTF8,
		},
		{
			name: "invalid revision hash format",
			mutate: func(req *proxyRawExportRequest) {
				req.revisionHash = stringPtr(validHash("A"))
			},
			wantStatus: proxyRawExportStatusInvalidArgument,
		},
		{
			name: "invalid utf8 session hash",
			mutate: func(req *proxyRawExportRequest) {
				req.sessionHash = stringPtr(string([]byte{0xff}))
			},
			wantStatus: proxyRawExportStatusInvalidUTF8,
		},
		{
			name: "invalid session hash format",
			mutate: func(req *proxyRawExportRequest) {
				req.sessionHash = stringPtr("bad-session")
			},
			wantStatus: proxyRawExportStatusInvalidArgument,
		},
		{
			name: "zero generation",
			mutate: func(req *proxyRawExportRequest) {
				req.generation = 0
			},
			wantStatus: proxyRawExportStatusInvalidArgument,
		},
		{
			name: "invalid selectable only flag",
			mutate: func(req *proxyRawExportRequest) {
				req.selectableOnly = 2
			},
			wantStatus: proxyRawExportStatusInvalidArgument,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := request
			tc.mutate(&req)
			output := []byte{0xaa, 0xbb, 0xcc}
			outputLength := uint64(99)

			result := executeProxyGroupsExport(req, proxyRawExportBuffer{
				output:       output,
				outputLength: &outputLength,
			})
			assertProxyExportResult(t, result, tc.wantStatus, string(proxygroupspkg.ErrCodeProxyBridgeInvalid))
			if outputLength != 0 {
				t.Fatalf("output length = %d want 0", outputLength)
			}
			if output[0] != 0 {
				t.Fatalf("output[0] = %#x want NUL", output[0])
			}
		})
	}
}

func TestExecuteProxyGroupAndSelectExportsRejectInvalidNames(t *testing.T) {
	replaceProxygroupsServiceForTest(t, panicProxygroupsService{})

	t.Run("query group name validation", func(t *testing.T) {
		cases := []struct {
			name       string
			groupName  *string
			wantStatus proxyRawExportStatus
		}{
			{name: "nil", groupName: nil, wantStatus: proxyRawExportStatusInvalidArgument},
			{name: "empty", groupName: stringPtr(""), wantStatus: proxyRawExportStatusInvalidArgument},
			{name: "control", groupName: stringPtr("bad\nname"), wantStatus: proxyRawExportStatusInvalidArgument},
			{name: "unicode control", groupName: stringPtr("bad\u0085name"), wantStatus: proxyRawExportStatusInvalidArgument},
			{name: "oversized", groupName: stringPtr(strings.Repeat("a", proxygroupspkg.MaxNameUTF8Bytes+1)), wantStatus: proxyRawExportStatusOutOfRange},
			{name: "invalid utf8", groupName: stringPtr(string([]byte{0xff})), wantStatus: proxyRawExportStatusInvalidUTF8},
		}

		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				req := validProxyGroupRequest()
				req.groupName = tc.groupName
				output := []byte{0xaa, 0xbb, 0xcc}
				outputLength := uint64(5)

				result := executeProxyGroupExport(req, proxyRawExportBuffer{
					output:       output,
					outputLength: &outputLength,
				})
				assertProxyExportResult(t, result, tc.wantStatus, string(proxygroupspkg.ErrCodeProxyBridgeInvalid))
				if outputLength != 0 {
					t.Fatalf("output length = %d want 0", outputLength)
				}
				if output[0] != 0 {
					t.Fatalf("output[0] = %#x want NUL", output[0])
				}
			})
		}
	})

	t.Run("select member name validation", func(t *testing.T) {
		cases := []struct {
			name       string
			memberName *string
			wantStatus proxyRawExportStatus
		}{
			{name: "nil", memberName: nil, wantStatus: proxyRawExportStatusInvalidArgument},
			{name: "empty", memberName: stringPtr(""), wantStatus: proxyRawExportStatusInvalidArgument},
			{name: "control", memberName: stringPtr("bad\tname"), wantStatus: proxyRawExportStatusInvalidArgument},
			{name: "unicode control", memberName: stringPtr("bad\u0085name"), wantStatus: proxyRawExportStatusInvalidArgument},
			{name: "oversized", memberName: stringPtr(strings.Repeat("b", proxygroupspkg.MaxNameUTF8Bytes+1)), wantStatus: proxyRawExportStatusOutOfRange},
			{name: "invalid utf8", memberName: stringPtr(string([]byte{0xff})), wantStatus: proxyRawExportStatusInvalidUTF8},
		}

		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				req := validProxySelectRequest()
				req.memberName = tc.memberName
				output := []byte{0xaa, 0xbb, 0xcc}
				outputLength := uint64(5)

				result := executeProxySelectExport(req, proxyRawExportBuffer{
					output:       output,
					outputLength: &outputLength,
				})
				assertProxyExportResult(t, result, tc.wantStatus, string(proxygroupspkg.ErrCodeProxyBridgeInvalid))
				if outputLength != 0 {
					t.Fatalf("output length = %d want 0", outputLength)
				}
				if output[0] != 0 {
					t.Fatalf("output[0] = %#x want NUL", output[0])
				}
			})
		}
	})
}

func TestExecuteProxyExportsAllowOrdinaryUnicodeNames(t *testing.T) {
	req := validProxySelectRequest()
	req.groupName = stringPtr("香港节点组")
	req.memberName = stringPtr("东京-01")

	var called atomic.Int32
	replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
		selectFn: func(ctx proxygroupspkg.QueryContext, groupName, memberName string) ([]byte, error) {
			called.Add(1)
			if groupName != "香港节点组" {
				t.Fatalf("groupName = %q want %q", groupName, "香港节点组")
			}
			if memberName != "东京-01" {
				t.Fatalf("memberName = %q want %q", memberName, "东京-01")
			}
			return mustSelectionPayload(t, ctx, groupName, memberName), nil
		},
	})

	output := makeFilledBuffer(1024)
	outputLength := uint64(17)
	result := executeProxySelectExport(req, proxyRawExportBuffer{
		output:       output,
		outputLength: &outputLength,
	})
	assertProxyExportResult(t, result, proxyRawExportStatusOK, "")
	if got := called.Load(); got != 1 {
		t.Fatalf("service called %d times want 1", got)
	}
}

func TestExecuteProxyGroupsExportTreatsEmptySessionHashAsAbsent(t *testing.T) {
	req := validProxyGroupsRequest()
	req.sessionHash = stringPtr("")

	var gotCtx proxygroupspkg.QueryContext
	replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
		listGroupsFn: func(ctx proxygroupspkg.QueryContext, selectableOnly bool) ([]byte, error) {
			gotCtx = ctx
			return mustListGroupsPayload(t, ctx), nil
		},
	})

	payload := mustListGroupsPayload(t, proxygroupspkg.QueryContext{
		ProfileHash:  mustString(req.profileHash),
		RevisionHash: mustString(req.revisionHash),
		Generation:   req.generation,
	})
	output := makeFilledBuffer(len(payload) + 2)
	outputLength := uint64(13)

	result := executeProxyGroupsExport(req, proxyRawExportBuffer{
		output:       output,
		outputLength: &outputLength,
	})
	assertProxyExportResult(t, result, proxyRawExportStatusOK, "")
	if gotCtx.SessionHash != nil {
		t.Fatalf("session hash = %q want nil", *gotCtx.SessionHash)
	}
}

func TestExecuteProxyGroupsExportReturnsBufferTooSmallWithoutPartialJSON(t *testing.T) {
	req := validProxyGroupsRequest()
	expectedPayload := mustListGroupsPayload(t, proxygroupspkg.QueryContext{
		ProfileHash:  mustString(req.profileHash),
		RevisionHash: mustString(req.revisionHash),
		SessionHash:  req.sessionHash,
		Generation:   req.generation,
	})
	replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
		listGroupsFn: func(ctx proxygroupspkg.QueryContext, selectableOnly bool) ([]byte, error) {
			return mustListGroupsPayload(t, ctx), nil
		},
	})

	output := makeFilledBuffer(len(expectedPayload))
	outputLength := uint64(41)
	result := executeProxyGroupsExport(req, proxyRawExportBuffer{
		output:       output,
		outputLength: &outputLength,
	})
	assertProxyExportResult(t, result, proxyRawExportStatusBufferTooSmall, string(proxygroupspkg.ErrCodeProxyBridgeInvalid))
	if outputLength != uint64(len(expectedPayload)) {
		t.Fatalf("required length = %d want %d", outputLength, len(expectedPayload))
	}
	if output[0] != 0 {
		t.Fatalf("output[0] = %#x want NUL", output[0])
	}
	for index, b := range output[1:] {
		if b != 0x7f {
			t.Fatalf("output[%d] = %#x want untouched sentinel", index+1, b)
		}
	}
}

func TestExecuteProxyGroupsExportSuccessWritesPayloadWithTrailingNUL(t *testing.T) {
	req := validProxyGroupsRequest()
	expectedPayload := mustListGroupsPayload(t, proxygroupspkg.QueryContext{
		ProfileHash:  mustString(req.profileHash),
		RevisionHash: mustString(req.revisionHash),
		SessionHash:  req.sessionHash,
		Generation:   req.generation,
	})
	replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
		listGroupsFn: func(ctx proxygroupspkg.QueryContext, selectableOnly bool) ([]byte, error) {
			return mustListGroupsPayload(t, ctx), nil
		},
	})

	output := makeFilledBuffer(len(expectedPayload) + 3)
	outputLength := uint64(123)
	result := executeProxyGroupsExport(req, proxyRawExportBuffer{
		output:       output,
		outputLength: &outputLength,
	})
	assertProxyExportResult(t, result, proxyRawExportStatusOK, "")
	if outputLength != uint64(len(expectedPayload)) {
		t.Fatalf("output length = %d want %d", outputLength, len(expectedPayload))
	}
	if !bytes.Equal(output[:len(expectedPayload)], expectedPayload) {
		t.Fatalf("payload bytes mismatch")
	}
	if output[len(expectedPayload)] != 0 {
		t.Fatalf("trailing byte = %#x want NUL", output[len(expectedPayload)])
	}
	if output[len(expectedPayload)+1] != 0x7f {
		t.Fatalf("byte after trailing NUL = %#x want untouched sentinel", output[len(expectedPayload)+1])
	}
}

func TestExecuteProxyExportsMapTypedServiceErrorsWithoutLeakingNames(t *testing.T) {
	t.Run("list runtime not ready", func(t *testing.T) {
		req := validProxyGroupsRequest()
		replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
			listGroupsFn: func(ctx proxygroupspkg.QueryContext, selectableOnly bool) ([]byte, error) {
				return nil, &proxygroupspkg.ModelError{Code: proxygroupspkg.ErrCodeProxyRuntimeNotReady}
			},
		})

		result := executeProxyGroupsExport(req, validProxyBuffer(32))
		assertProxyExportResult(t, result, proxyRawExportStatusInvalidState, string(proxygroupspkg.ErrCodeProxyRuntimeNotReady))
	})

	t.Run("query missing group", func(t *testing.T) {
		req := validProxyGroupRequest()
		replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
			queryGroupFn: func(ctx proxygroupspkg.QueryContext, groupName string) ([]byte, error) {
				return nil, &proxygroupspkg.ModelError{Code: proxygroupspkg.ErrCodeProxyGroupNotFound}
			},
		})

		result := executeProxyGroupExport(req, validProxyBuffer(32))
		assertProxyExportResult(t, result, proxyRawExportStatusInvalidArgument, string(proxygroupspkg.ErrCodeProxyGroupNotFound))
		assertNoLeak(t, result.errorCode, mustString(req.groupName))
	})

	t.Run("query bridge invalid", func(t *testing.T) {
		req := validProxyGroupRequest()
		replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
			queryGroupFn: func(ctx proxygroupspkg.QueryContext, groupName string) ([]byte, error) {
				return nil, &proxygroupspkg.ModelError{Code: proxygroupspkg.ErrCodeProxyBridgeInvalid}
			},
		})

		result := executeProxyGroupExport(req, validProxyBuffer(32))
		assertProxyExportResult(t, result, proxyRawExportStatusBackendError, string(proxygroupspkg.ErrCodeProxyBridgeInvalid))
	})

	t.Run("select group not selectable", func(t *testing.T) {
		req := validProxySelectRequest()
		replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
			selectFn: func(ctx proxygroupspkg.QueryContext, groupName, memberName string) ([]byte, error) {
				return nil, &proxygroupspkg.ModelError{Code: proxygroupspkg.ErrCodeProxyGroupNotSelectable}
			},
		})

		result := executeProxySelectExport(req, validProxyBuffer(32))
		assertProxyExportResult(t, result, proxyRawExportStatusInvalidArgument, string(proxygroupspkg.ErrCodeProxyGroupNotSelectable))
		assertNoLeak(t, result.errorCode, mustString(req.groupName), mustString(req.memberName))
	})

	t.Run("select member not found", func(t *testing.T) {
		req := validProxySelectRequest()
		replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
			selectFn: func(ctx proxygroupspkg.QueryContext, groupName, memberName string) ([]byte, error) {
				return nil, &proxygroupspkg.ModelError{Code: proxygroupspkg.ErrCodeProxyMemberNotFound}
			},
		})

		result := executeProxySelectExport(req, validProxyBuffer(32))
		assertProxyExportResult(t, result, proxyRawExportStatusInvalidArgument, string(proxygroupspkg.ErrCodeProxyMemberNotFound))
	})

	t.Run("select backend failures collapse to selection failed", func(t *testing.T) {
		req := validProxySelectRequest()
		replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
			selectFn: func(ctx proxygroupspkg.QueryContext, groupName, memberName string) ([]byte, error) {
				return nil, errors.New("backend exploded for " + groupName + "/" + memberName)
			},
		})

		result := executeProxySelectExport(req, validProxyBuffer(32))
		assertProxyExportResult(t, result, proxyRawExportStatusBackendError, string(proxygroupspkg.ErrCodeProxySelectionFailed))
		assertNoLeak(t, result.errorCode, mustString(req.groupName), mustString(req.memberName))
	})
}

func TestExecuteProxyGroupsExportRejectsPayloadBeyondResponseCap(t *testing.T) {
	req := validProxyGroupsRequest()
	replaceProxygroupsServiceForTest(t, fakeProxygroupsService{
		listGroupsFn: func(ctx proxygroupspkg.QueryContext, selectableOnly bool) ([]byte, error) {
			return bytes.Repeat([]byte("x"), proxygroupspkg.MaxResponseBytes+1), nil
		},
	})

	output := makeFilledBuffer(proxygroupspkg.MaxResponseBytes + 1)
	outputLength := uint64(7)
	result := executeProxyGroupsExport(req, proxyRawExportBuffer{
		output:       output,
		outputLength: &outputLength,
	})
	assertProxyExportResult(t, result, proxyRawExportStatusOutOfRange, string(proxygroupspkg.ErrCodeProxyBridgeInvalid))
	if outputLength != 0 {
		t.Fatalf("output length = %d want 0", outputLength)
	}
	if output[0] != 0 {
		t.Fatalf("output[0] = %#x want NUL", output[0])
	}
}

func TestProxyExportAccessibleBytesCapsAtResponseLimitPlusNUL(t *testing.T) {
	if got := proxyExportAccessibleBytes(0); got != 0 {
		t.Fatalf("proxyExportAccessibleBytes(0) = %d want 0", got)
	}

	wantCap := proxygroupspkg.MaxResponseBytes + 1
	if got := proxyExportAccessibleBytes(uint64(wantCap + 1024)); got != wantCap {
		t.Fatalf("proxyExportAccessibleBytes(oversized) = %d want %d", got, wantCap)
	}
}

type fakeProxygroupsService struct {
	listGroupsFn func(ctx proxygroupspkg.QueryContext, selectableOnly bool) ([]byte, error)
	queryGroupFn func(ctx proxygroupspkg.QueryContext, groupName string) ([]byte, error)
	selectFn     func(ctx proxygroupspkg.QueryContext, groupName, memberName string) ([]byte, error)
}

func (f fakeProxygroupsService) ListGroups(ctx proxygroupspkg.QueryContext, selectableOnly bool) ([]byte, error) {
	if f.listGroupsFn == nil {
		return nil, errors.New("unexpected ListGroups call")
	}
	return f.listGroupsFn(ctx, selectableOnly)
}

func (f fakeProxygroupsService) QueryGroup(ctx proxygroupspkg.QueryContext, groupName string) ([]byte, error) {
	if f.queryGroupFn == nil {
		return nil, errors.New("unexpected QueryGroup call")
	}
	return f.queryGroupFn(ctx, groupName)
}

func (f fakeProxygroupsService) Select(ctx proxygroupspkg.QueryContext, groupName, memberName string) ([]byte, error) {
	if f.selectFn == nil {
		return nil, errors.New("unexpected Select call")
	}
	return f.selectFn(ctx, groupName, memberName)
}

type panicProxygroupsService struct{}

func (panicProxygroupsService) ListGroups(proxygroupspkg.QueryContext, bool) ([]byte, error) {
	panic("unexpected ListGroups call")
}

func (panicProxygroupsService) QueryGroup(proxygroupspkg.QueryContext, string) ([]byte, error) {
	panic("unexpected QueryGroup call")
}

func (panicProxygroupsService) Select(proxygroupspkg.QueryContext, string, string) ([]byte, error) {
	panic("unexpected Select call")
}

func replaceProxygroupsServiceForTest(t *testing.T, service proxygroupsService) {
	t.Helper()

	proxygroupsServiceMu.Lock()
	previous := proxygroupsRuntimeService
	proxygroupsRuntimeService = service
	proxygroupsServiceMu.Unlock()

	t.Cleanup(func() {
		proxygroupsServiceMu.Lock()
		proxygroupsRuntimeService = previous
		proxygroupsServiceMu.Unlock()
	})
}

func validProxyGroupsRequest() proxyRawExportRequest {
	return proxyRawExportRequest{
		profileHash:    stringPtr(validHash("a")),
		revisionHash:   stringPtr(validHash("b")),
		sessionHash:    stringPtr(validHash("c")),
		generation:     1,
		selectableOnly: 1,
	}
}

func validProxyGroupRequest() proxyRawExportRequest {
	req := validProxyGroupsRequest()
	req.groupName = stringPtr("group-a")
	return req
}

func validProxySelectRequest() proxyRawExportRequest {
	req := validProxyGroupRequest()
	req.memberName = stringPtr("member-a")
	return req
}

func validProxyBuffer(size int) proxyRawExportBuffer {
	outputLength := uint64(0)
	return proxyRawExportBuffer{
		output:       makeFilledBuffer(size),
		outputLength: &outputLength,
	}
}

func validHash(seed string) string {
	return strings.Repeat(seed, 64)
}

func stringPtr(value string) *string {
	return &value
}

func uint64Ptr(value uint64) *uint64 {
	return &value
}

func mustString(value *string) string {
	if value == nil {
		panic("unexpected nil string pointer")
	}
	return *value
}

func makeFilledBuffer(size int) []byte {
	buffer := make([]byte, size)
	for index := range buffer {
		buffer[index] = 0x7f
	}
	return buffer
}

func mustListGroupsPayload(t *testing.T, ctx proxygroupspkg.QueryContext) []byte {
	t.Helper()

	envelope, err := proxygroupspkg.NewGroupListEnvelope(ctx, []proxygroupspkg.GroupRef{
		{Name: "group-a", Type: "Selector"},
	})
	if err != nil {
		t.Fatalf("NewGroupListEnvelope() unexpected error: %v", err)
	}
	payload, err := envelope.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	return payload
}

func mustSelectionPayload(t *testing.T, ctx proxygroupspkg.QueryContext, groupName, memberName string) []byte {
	t.Helper()

	envelope, err := proxygroupspkg.NewSelectionAppliedEnvelope(ctx, proxygroupspkg.GroupSnapshot{
		Name:         groupName,
		Type:         "Selector",
		SelectedName: memberName,
		Nodes: []proxygroupspkg.NodeSummary{
			{Name: memberName, Type: "Direct", Selected: true},
		},
	}, "")
	if err != nil {
		t.Fatalf("NewSelectionAppliedEnvelope() unexpected error: %v", err)
	}
	payload, err := envelope.MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	return payload
}

func assertProxyExportResult(t *testing.T, got proxyRawExportResult, wantStatus proxyRawExportStatus, wantErrorCode string) {
	t.Helper()

	if got.status != wantStatus {
		t.Fatalf("status = %v want %v", got.status, wantStatus)
	}
	if got.errorCode != wantErrorCode {
		t.Fatalf("error code = %q want %q", got.errorCode, wantErrorCode)
	}
	if wantErrorCode != "" && !isAllowedProxyExportErrorCode(got.errorCode) {
		t.Fatalf("error code %q is not allowlisted", got.errorCode)
	}
}

func isAllowedProxyExportErrorCode(code string) bool {
	switch code {
	case "",
		string(proxygroupspkg.ErrCodeProxyRuntimeNotReady),
		string(proxygroupspkg.ErrCodeProxyGroupNotFound),
		string(proxygroupspkg.ErrCodeProxyGroupNotSelectable),
		string(proxygroupspkg.ErrCodeProxyMemberNotFound),
		string(proxygroupspkg.ErrCodeProxySelectionFailed),
		string(proxygroupspkg.ErrCodeProxyBridgeInvalid):
		return true
	default:
		return false
	}
}

func assertNoLeak(t *testing.T, detail string, forbidden ...string) {
	t.Helper()
	for _, item := range forbidden {
		if item == "" {
			continue
		}
		if strings.Contains(detail, item) {
			t.Fatalf("detail %q leaked forbidden value %q", detail, item)
		}
	}
}
