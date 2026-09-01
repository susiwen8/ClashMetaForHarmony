//go:build !ohos

package main

/*
#include <stdlib.h>
#include "../../../abi/include/cmfa_types.h"

static char *cmfa_test_tun_trace_destination_hash(cmfa_tun_trace *trace) {
	return trace->destination_hash;
}

static char *cmfa_test_tun_trace_outbound_terminal_hash(cmfa_tun_trace *trace) {
	return trace->outbound_terminal_hash;
}

static char *cmfa_test_tun_trace_outbound_chain_hash(cmfa_tun_trace *trace) {
	return trace->outbound_chain_hash;
}
*/
import "C"

import (
	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
	"unsafe"
)

type encodedTunTraceForTest struct {
	DestinationHash     string
	OutboundTerminalHash string
	OutboundChainHash    string
	OutboundChainLength  uint32
}

func callCloseStaleTunConnectionsForTest(sessionID string) int {
	cSessionID := C.CString(sessionID)
	defer C.free(unsafe.Pointer(cSessionID))
	var errorOut C.cmfa_error
	return int(cmfa_mihomo_close_stale_tun_connections_v1(cSessionID, &errorOut))
}

func closeStaleTunStatusOK() int {
	return int(C.CMFA_OK)
}

func closeStaleTunStatusBusy() int {
	return int(C.CMFA_BUSY)
}

func closeStaleTunStatusInvalidArgument() int {
	return int(C.CMFA_INVALID_ARGUMENT)
}

func closeStaleTunStatusBackendError() int {
	return int(C.CMFA_BACKEND_ERROR)
}

func encodeTunTraceForTest(source runtimepkg.TunTrace) encodedTunTraceForTest {
	var trace C.cmfa_tun_trace
	writeTunTrace(&trace, source)
	return encodedTunTraceForTest{
		DestinationHash:      C.GoString(C.cmfa_test_tun_trace_destination_hash(&trace)),
		OutboundTerminalHash: C.GoString(C.cmfa_test_tun_trace_outbound_terminal_hash(&trace)),
		OutboundChainHash:    C.GoString(C.cmfa_test_tun_trace_outbound_chain_hash(&trace)),
		OutboundChainLength:  uint32(trace.outbound_chain_length),
	}
}
