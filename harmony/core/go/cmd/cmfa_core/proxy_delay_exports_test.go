package main

import (
	"bytes"
	"errors"
	"strings"
	"sync/atomic"
	"testing"

	proxygroupspkg "github.com/clashmetaforandroid/harmony/core/go/internal/proxygroups"
)

func TestProxyDelayStartExportRejectsInvalidBufferContract(t *testing.T) {
	request := validProxyDelayStartRequest()
	var calls atomic.Int32
	replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
		startFn: func(ctx proxygroupspkg.QueryContext, groupName string) (proxygroupspkg.DelayTestSnapshot, error) {
			calls.Add(1)
			return mustDelaySnapshotForTest(t, ctx, fixedDelayJobID(), groupName), nil
		},
	})

	for _, tc := range []struct {
		name         string
		output       []byte
		outputLength *uint64
	}{
		{name: "nil output buffer", outputLength: uint64Ptr(7)},
		{name: "zero capacity", output: []byte{}, outputLength: uint64Ptr(7)},
		{name: "nil length pointer", output: []byte{0xaa, 0xbb, 0xcc}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			result := executeProxyDelayStartExport(request, proxyRawExportBuffer{
				output:       tc.output,
				outputLength: tc.outputLength,
			})
			assertProxyDelayExportResult(t, result, proxyRawExportStatusInvalidArgument, delayBridgeInvalidErrorCode)
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

func TestProxyDelayStartExportRejectsInvalidQueryAndGroupInputs(t *testing.T) {
	replaceProxyDelayServiceForTest(t, panicProxyDelayService{})
	request := validProxyDelayStartRequest()

	tests := []struct {
		name       string
		mutate     func(*proxyRawExportRequest)
		wantStatus proxyRawExportStatus
	}{
		{name: "nil profile hash", mutate: func(req *proxyRawExportRequest) { req.profileHash = nil }, wantStatus: proxyRawExportStatusInvalidArgument},
		{name: "invalid utf8 profile hash", mutate: func(req *proxyRawExportRequest) { req.profileHash = stringPtr(string([]byte{0xff})) }, wantStatus: proxyRawExportStatusInvalidUTF8},
		{name: "invalid profile hash format", mutate: func(req *proxyRawExportRequest) { req.profileHash = stringPtr("short") }, wantStatus: proxyRawExportStatusInvalidArgument},
		{name: "invalid utf8 revision hash", mutate: func(req *proxyRawExportRequest) { req.revisionHash = stringPtr(string([]byte{0xff})) }, wantStatus: proxyRawExportStatusInvalidUTF8},
		{name: "invalid revision hash format", mutate: func(req *proxyRawExportRequest) { req.revisionHash = stringPtr(validHash("A")) }, wantStatus: proxyRawExportStatusInvalidArgument},
		{name: "invalid utf8 session hash", mutate: func(req *proxyRawExportRequest) { req.sessionHash = stringPtr(string([]byte{0xff})) }, wantStatus: proxyRawExportStatusInvalidUTF8},
		{name: "invalid session hash format", mutate: func(req *proxyRawExportRequest) { req.sessionHash = stringPtr("bad-session") }, wantStatus: proxyRawExportStatusInvalidArgument},
		{name: "zero generation", mutate: func(req *proxyRawExportRequest) { req.generation = 0 }, wantStatus: proxyRawExportStatusInvalidArgument},
		{name: "nil group name", mutate: func(req *proxyRawExportRequest) { req.groupName = nil }, wantStatus: proxyRawExportStatusInvalidArgument},
		{name: "empty group name", mutate: func(req *proxyRawExportRequest) { req.groupName = stringPtr("") }, wantStatus: proxyRawExportStatusInvalidArgument},
		{name: "control group name", mutate: func(req *proxyRawExportRequest) { req.groupName = stringPtr("group\nname") }, wantStatus: proxyRawExportStatusInvalidArgument},
		{name: "oversized group name", mutate: func(req *proxyRawExportRequest) {
			req.groupName = stringPtr(strings.Repeat("g", proxygroupspkg.MaxNameUTF8Bytes+1))
		}, wantStatus: proxyRawExportStatusOutOfRange},
		{name: "invalid utf8 group name", mutate: func(req *proxyRawExportRequest) { req.groupName = stringPtr(string([]byte{0xff})) }, wantStatus: proxyRawExportStatusInvalidUTF8},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := request
			tc.mutate(&req)
			output := []byte{0xaa, 0xbb, 0xcc}
			outputLength := uint64(11)

			result := executeProxyDelayStartExport(req, proxyRawExportBuffer{
				output:       output,
				outputLength: &outputLength,
			})
			assertProxyDelayExportResult(t, result, tc.wantStatus, delayBridgeInvalidErrorCode)
			if outputLength != 0 {
				t.Fatalf("output length = %d want 0", outputLength)
			}
			if output[0] != 0 {
				t.Fatalf("output[0] = %#x want NUL", output[0])
			}
		})
	}
}

func TestProxyDelayStartExportSuccessWritesJSONWithTrailingNUL(t *testing.T) {
	req := validProxyDelayStartRequest()
	ctx := proxygroupspkg.QueryContext{
		ProfileHash:  mustString(req.profileHash),
		RevisionHash: mustString(req.revisionHash),
		SessionHash:  req.sessionHash,
		Generation:   req.generation,
	}
	want := mustDelaySnapshotPayloadForTest(t, ctx, fixedDelayJobID(), mustString(req.groupName))
	var called atomic.Int32
	replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
		startFn: func(gotCtx proxygroupspkg.QueryContext, groupName string) (proxygroupspkg.DelayTestSnapshot, error) {
			called.Add(1)
			if gotCtx.ProfileHash != ctx.ProfileHash || gotCtx.RevisionHash != ctx.RevisionHash || gotCtx.Generation != ctx.Generation {
				t.Fatalf("ctx core fields = %#v want %#v", gotCtx, ctx)
			}
			if (gotCtx.SessionHash == nil) != (ctx.SessionHash == nil) {
				t.Fatalf("session hash presence = %v want %v", gotCtx.SessionHash != nil, ctx.SessionHash != nil)
			}
			if gotCtx.SessionHash != nil && *gotCtx.SessionHash != *ctx.SessionHash {
				t.Fatalf("session hash = %q want %q", *gotCtx.SessionHash, *ctx.SessionHash)
			}
			if groupName != mustString(req.groupName) {
				t.Fatalf("groupName = %q want %q", groupName, mustString(req.groupName))
			}
			return mustDelaySnapshotForTest(t, gotCtx, fixedDelayJobID(), groupName), nil
		},
	})

	output := makeFilledBuffer(len(want) + 3)
	outputLength := uint64(99)
	result := executeProxyDelayStartExport(req, proxyRawExportBuffer{
		output:       output,
		outputLength: &outputLength,
	})
	assertProxyDelayExportResult(t, result, proxyRawExportStatusOK, "")
	if got := called.Load(); got != 1 {
		t.Fatalf("service called %d times want 1", got)
	}
	if outputLength != uint64(len(want)) {
		t.Fatalf("output length = %d want %d", outputLength, len(want))
	}
	if !bytes.Equal(output[:len(want)], want) {
		t.Fatalf("payload bytes mismatch")
	}
	if output[len(want)] != 0 {
		t.Fatalf("trailing byte = %#x want NUL", output[len(want)])
	}
	if output[len(want)+1] != 0x7f {
		t.Fatalf("byte after trailing NUL = %#x want untouched sentinel", output[len(want)+1])
	}
}

func TestProxyDelayStartExportReturnsBufferTooSmallWithoutPartialJSON(t *testing.T) {
	req := validProxyDelayStartRequest()
	ctx := proxygroupspkg.QueryContext{
		ProfileHash:  mustString(req.profileHash),
		RevisionHash: mustString(req.revisionHash),
		SessionHash:  req.sessionHash,
		Generation:   req.generation,
	}
	want := mustDelaySnapshotPayloadForTest(t, ctx, fixedDelayJobID(), mustString(req.groupName))
	replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
		startFn: func(gotCtx proxygroupspkg.QueryContext, groupName string) (proxygroupspkg.DelayTestSnapshot, error) {
			return mustDelaySnapshotForTest(t, gotCtx, fixedDelayJobID(), groupName), nil
		},
	})

	output := makeFilledBuffer(len(want))
	outputLength := uint64(3)
	result := executeProxyDelayStartExport(req, proxyRawExportBuffer{
		output:       output,
		outputLength: &outputLength,
	})
	assertProxyDelayExportResult(t, result, proxyRawExportStatusBufferTooSmall, delayBridgeInvalidErrorCode)
	if outputLength != uint64(len(want)) {
		t.Fatalf("required length = %d want %d", outputLength, len(want))
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

func TestProxyDelayStartExportMapsMissingGroupToInvalidArgumentWithoutLeak(t *testing.T) {
	req := validProxyDelayStartRequest()
	output := []byte{0xaa, 0xbb, 0xcc}
	outputLength := uint64(9)
	replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
		startFn: func(proxygroupspkg.QueryContext, string) (proxygroupspkg.DelayTestSnapshot, error) {
			return proxygroupspkg.DelayTestSnapshot{}, &proxygroupspkg.ModelError{Code: proxygroupspkg.ErrCodeProxyGroupNotFound}
		},
	})

	result := executeProxyDelayStartExport(req, proxyRawExportBuffer{
		output:       output,
		outputLength: &outputLength,
	})
	assertProxyDelayExportResult(t, result, proxyRawExportStatusInvalidArgument, delayBridgeInvalidErrorCode)
	if outputLength != 0 {
		t.Fatalf("output length = %d want 0", outputLength)
	}
	if output[0] != 0 {
		t.Fatalf("output[0] = %#x want NUL", output[0])
	}
	assertNoLeak(t, result.errorCode, mustString(req.groupName))
}

func TestProxyDelaySnapshotAndCancelExportsValidateJobIDAndMapErrors(t *testing.T) {
	t.Run("invalid job id rejected", func(t *testing.T) {
		replaceProxyDelayServiceForTest(t, panicProxyDelayService{})
		for _, fn := range []struct {
			name   string
			invoke func(*string, proxyRawExportBuffer) proxyRawExportResult
		}{
			{name: "snapshot", invoke: executeProxyDelaySnapshotExport},
			{name: "cancel", invoke: executeProxyDelayCancelExport},
		} {
			t.Run(fn.name, func(t *testing.T) {
				output := []byte{0xaa, 0xbb}
				outputLength := uint64(4)
				result := fn.invoke(stringPtr("BADJOBID"), proxyRawExportBuffer{
					output:       output,
					outputLength: &outputLength,
				})
				assertProxyDelayExportResult(t, result, proxyRawExportStatusInvalidArgument, delayBridgeInvalidErrorCode)
				if outputLength != 0 {
					t.Fatalf("output length = %d want 0", outputLength)
				}
				if output[0] != 0 {
					t.Fatalf("output[0] = %#x want NUL", output[0])
				}
			})
		}
	})

	t.Run("job not found maps to invalid state", func(t *testing.T) {
		replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
			readFn: func(string) (proxygroupspkg.DelayTestSnapshot, error) {
				return proxygroupspkg.DelayTestSnapshot{}, &proxygroupspkg.ModelError{Code: proxygroupspkg.ErrCodeDelayJobNotFound}
			},
			cancelFn: func(string) (proxygroupspkg.DelayTestSnapshot, error) {
				return proxygroupspkg.DelayTestSnapshot{}, &proxygroupspkg.ModelError{Code: proxygroupspkg.ErrCodeDelayJobNotFound}
			},
		})
		for _, fn := range []struct {
			name   string
			invoke func(*string, proxyRawExportBuffer) proxyRawExportResult
		}{
			{name: "snapshot", invoke: executeProxyDelaySnapshotExport},
			{name: "cancel", invoke: executeProxyDelayCancelExport},
		} {
			t.Run(fn.name, func(t *testing.T) {
				result := fn.invoke(stringPtr(fixedDelayJobID()), validProxyBuffer(32))
				assertProxyDelayExportResult(t, result, proxyRawExportStatusInvalidState, delayJobNotFoundErrorCode)
			})
		}
	})

	t.Run("panic is contained", func(t *testing.T) {
		replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
			readFn: func(string) (proxygroupspkg.DelayTestSnapshot, error) {
				panic("synthetic snapshot panic")
			},
		})
		result := executeProxyDelaySnapshotExport(stringPtr(fixedDelayJobID()), validProxyBuffer(32))
		assertProxyDelayExportResult(t, result, proxyRawExportStatusBackendError, delayBridgeInvalidErrorCode)
		assertNoLeak(t, result.errorCode, "synthetic", "snapshot")
	})
}

func TestDelayDrainWaitsForDrainBeforeMutation(t *testing.T) {
	drainStarted := make(chan struct{})
	releaseDrain := make(chan struct{})
	mutationStarted := make(chan struct{}, 1)
	replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
		drainFn: func() error {
			close(drainStarted)
			<-releaseDrain
			return nil
		},
	})

	done := make(chan proxyMutationResult, 1)
	go func() {
		done <- executeAfterProxyDelayDrain(func() {}, func() proxyMutationResult {
			mutationStarted <- struct{}{}
			return proxyMutationResult{status: 17}
		})
	}()

	<-drainStarted
	select {
	case <-mutationStarted:
		t.Fatal("mutation started before drain completed")
	default:
	}

	close(releaseDrain)
	result := <-done
	if result.status != 17 {
		t.Fatalf("status = %d want 17", result.status)
	}
	<-mutationStarted
}

func TestDelayDrainBlocksMutationOnFailureAndPanic(t *testing.T) {
	t.Run("drain failure", func(t *testing.T) {
		var called atomic.Int32
		replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
			drainFn: func() error { return errors.New("backend exploded") },
		})
		result := executeAfterProxyDelayDrain(func() {}, func() proxyMutationResult {
			called.Add(1)
			return proxyMutationResult{status: 23}
		})
		if result.status != proxyMutationBackendErrorStatus {
			t.Fatalf("status = %d want backend error", result.status)
		}
		if result.message != delayBridgeInvalidErrorCode {
			t.Fatalf("message = %q want %q", result.message, delayBridgeInvalidErrorCode)
		}
		if got := called.Load(); got != 0 {
			t.Fatalf("mutation called %d times on drain failure", got)
		}
	})

	t.Run("drain panic", func(t *testing.T) {
		var called atomic.Int32
		replaceProxyDelayServiceForTest(t, fakeProxyDelayService{
			drainFn: func() error { panic("synthetic panic") },
		})
		result := executeAfterProxyDelayDrain(func() {}, func() proxyMutationResult {
			called.Add(1)
			return proxyMutationResult{status: 23}
		})
		if result.status != proxyMutationBackendErrorStatus {
			t.Fatalf("status = %d want backend error", result.status)
		}
		if result.message != delayBridgeInvalidErrorCode {
			t.Fatalf("message = %q want %q", result.message, delayBridgeInvalidErrorCode)
		}
		if got := called.Load(); got != 0 {
			t.Fatalf("mutation called %d times on drain panic", got)
		}
	})
}

type fakeProxyDelayService struct {
	startFn  func(ctx proxygroupspkg.QueryContext, groupName string) (proxygroupspkg.DelayTestSnapshot, error)
	readFn   func(jobID string) (proxygroupspkg.DelayTestSnapshot, error)
	cancelFn func(jobID string) (proxygroupspkg.DelayTestSnapshot, error)
	drainFn  func() error
}

func (f fakeProxyDelayService) Start(ctx proxygroupspkg.QueryContext, groupName string) (proxygroupspkg.DelayTestSnapshot, error) {
	if f.startFn == nil {
		return proxygroupspkg.DelayTestSnapshot{}, errors.New("unexpected Start call")
	}
	return f.startFn(ctx, groupName)
}

func (f fakeProxyDelayService) Read(jobID string) (proxygroupspkg.DelayTestSnapshot, error) {
	if f.readFn == nil {
		return proxygroupspkg.DelayTestSnapshot{}, errors.New("unexpected Read call")
	}
	return f.readFn(jobID)
}

func (f fakeProxyDelayService) Cancel(jobID string) (proxygroupspkg.DelayTestSnapshot, error) {
	if f.cancelFn == nil {
		return proxygroupspkg.DelayTestSnapshot{}, errors.New("unexpected Cancel call")
	}
	return f.cancelFn(jobID)
}

func (f fakeProxyDelayService) CancelActiveAndDrain() error {
	if f.drainFn == nil {
		return nil
	}
	return f.drainFn()
}

type panicProxyDelayService struct{}

func (panicProxyDelayService) Start(proxygroupspkg.QueryContext, string) (proxygroupspkg.DelayTestSnapshot, error) {
	panic("unexpected Start call")
}

func (panicProxyDelayService) Read(string) (proxygroupspkg.DelayTestSnapshot, error) {
	panic("unexpected Read call")
}

func (panicProxyDelayService) Cancel(string) (proxygroupspkg.DelayTestSnapshot, error) {
	panic("unexpected Cancel call")
}

func (panicProxyDelayService) CancelActiveAndDrain() error {
	panic("unexpected CancelActiveAndDrain call")
}

func replaceProxyDelayServiceForTest(t *testing.T, service proxyDelayService) {
	t.Helper()

	proxyDelayServiceMu.Lock()
	previous := proxyDelayRuntimeService
	proxyDelayRuntimeService = service
	proxyDelayServiceMu.Unlock()

	t.Cleanup(func() {
		proxyDelayServiceMu.Lock()
		proxyDelayRuntimeService = previous
		proxyDelayServiceMu.Unlock()
	})
}

func validProxyDelayStartRequest() proxyRawExportRequest {
	req := validProxyGroupsRequest()
	req.groupName = stringPtr("delay-group")
	return req
}

func fixedDelayJobID() string {
	return strings.Repeat("1", proxygroupspkg.MaxDelayJobIDBytes)
}

func mustDelaySnapshotForTest(t *testing.T, ctx proxygroupspkg.QueryContext, jobID, groupName string) proxygroupspkg.DelayTestSnapshot {
	t.Helper()

	provider := proxygroupspkg.DelayURLSourceProvider
	delay := uint16(12)
	snapshot, err := proxygroupspkg.NewDelayTestSnapshot(ctx, jobID, proxygroupspkg.DelayJobStateCompleted, groupName, []proxygroupspkg.DelayNodeResult{
		{Index: 0, Name: "node-a", Type: "Direct", State: proxygroupspkg.DelayNodeStateAvailable, DelayMs: &delay, Source: &provider},
	})
	if err != nil {
		t.Fatalf("NewDelayTestSnapshot() unexpected error: %v", err)
	}
	return snapshot
}

func mustDelaySnapshotPayloadForTest(t *testing.T, ctx proxygroupspkg.QueryContext, jobID, groupName string) []byte {
	t.Helper()
	payload, err := mustDelaySnapshotForTest(t, ctx, jobID, groupName).MarshalJSONBytes()
	if err != nil {
		t.Fatalf("MarshalJSONBytes() unexpected error: %v", err)
	}
	return payload
}

func assertProxyDelayExportResult(t *testing.T, got proxyRawExportResult, wantStatus proxyRawExportStatus, wantErrorCode string) {
	t.Helper()
	if got.status != wantStatus {
		t.Fatalf("status = %v want %v", got.status, wantStatus)
	}
	if got.errorCode != wantErrorCode {
		t.Fatalf("error code = %q want %q", got.errorCode, wantErrorCode)
	}
	if wantErrorCode != "" && !isAllowedProxyDelayExportErrorCode(got.errorCode) {
		t.Fatalf("error code %q is not allowlisted", got.errorCode)
	}
}

func isAllowedProxyDelayExportErrorCode(code string) bool {
	switch code {
	case "", delayBridgeInvalidErrorCode, delayJobNotFoundErrorCode:
		return true
	default:
		return false
	}
}
