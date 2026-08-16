package main

/*
#include <stdlib.h>
#include "../../../abi/include/cmfa_types.h"
*/
import "C"

import "unsafe"

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
