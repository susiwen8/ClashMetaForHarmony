// Copyright 2015 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "go_asm.h"
#include "go_tls.h"
#include "funcdata.h"
#include "textflag.h"
#include "tls_arm64.h"

TEXT runtime·load_g(SB),NOSPLIT,$0
#ifdef CMFA_GOOS_OHOS
	MOVB	runtime·iscgo(SB), R0
	CBZ	R0, nocgo
	// The C helper follows AAPCS64 and may clobber R0-R17. Go's
	// load_g contract only permits R0, R27, and g to be clobbered.
	SUB	$144, RSP
	STP	(R1, R2), 0(RSP)
	STP	(R3, R4), 16(RSP)
	STP	(R5, R6), 32(RSP)
	STP	(R7, R8), 48(RSP)
	STP	(R9, R10), 64(RSP)
	STP	(R11, R12), 80(RSP)
	STP	(R13, R14), 96(RSP)
	STP	(R15, R16), 112(RSP)
	MOVD	R17, 128(RSP)
	BL	x_cgo_ohos_load_g(SB)
	MOVD	R0, g
	MOVD	128(RSP), R17
	LDP	112(RSP), (R15, R16)
	LDP	96(RSP), (R13, R14)
	LDP	80(RSP), (R11, R12)
	LDP	64(RSP), (R9, R10)
	LDP	48(RSP), (R7, R8)
	LDP	32(RSP), (R5, R6)
	LDP	16(RSP), (R3, R4)
	LDP	0(RSP), (R1, R2)
	ADD	$144, RSP
#else
#ifndef GOOS_darwin
#ifndef GOOS_openbsd
#ifndef GOOS_windows
	MOVB	runtime·iscgo(SB), R0
	CBZ	R0, nocgo
#endif
#endif
#endif

	MRS_TPIDR_R0
#ifdef TLS_darwin
	// Darwin sometimes returns unaligned pointers
	AND	$0xfffffffffffffff8, R0
#endif
	MOVD	runtime·tls_g(SB), R27
	MOVD	(R0)(R27), g
#endif

nocgo:
	RET

TEXT runtime·save_g(SB),NOSPLIT,$0
#ifdef CMFA_GOOS_OHOS
	MOVB	runtime·iscgo(SB), R0
	CBZ	R0, nocgo
	// Preserve the registers that AAPCS64 permits the C helper to
	// clobber but callers of the Go runtime save_g stub keep live.
	SUB	$144, RSP
	STP	(R1, R2), 0(RSP)
	STP	(R3, R4), 16(RSP)
	STP	(R5, R6), 32(RSP)
	STP	(R7, R8), 48(RSP)
	STP	(R9, R10), 64(RSP)
	STP	(R11, R12), 80(RSP)
	STP	(R13, R14), 96(RSP)
	STP	(R15, R16), 112(RSP)
	MOVD	R17, 128(RSP)
	MOVD	g, R0
	BL	x_cgo_ohos_save_g(SB)
	MOVD	128(RSP), R17
	LDP	112(RSP), (R15, R16)
	LDP	96(RSP), (R13, R14)
	LDP	80(RSP), (R11, R12)
	LDP	64(RSP), (R9, R10)
	LDP	48(RSP), (R7, R8)
	LDP	32(RSP), (R5, R6)
	LDP	16(RSP), (R3, R4)
	LDP	0(RSP), (R1, R2)
	ADD	$144, RSP
#else
#ifndef GOOS_darwin
#ifndef GOOS_openbsd
#ifndef GOOS_windows
	MOVB	runtime·iscgo(SB), R0
	CBZ	R0, nocgo
#endif
#endif
#endif

	MRS_TPIDR_R0
#ifdef TLS_darwin
	// Darwin sometimes returns unaligned pointers
	AND	$0xfffffffffffffff8, R0
#endif
	MOVD	runtime·tls_g(SB), R27
	MOVD	g, (R0)(R27)
#endif

nocgo:
	RET

#ifdef CMFA_GOOS_OHOS
GLOBL runtime·tls_g+0(SB), NOPTR, $8
#else
#ifdef TLSG_IS_VARIABLE
#ifdef GOOS_android
// Use the free TLS_SLOT_APP slot #2 on Android Q.
// Earlier androids are set up in gcc_android.c.
DATA runtime·tls_g+0(SB)/8, $16
#endif
GLOBL runtime·tls_g+0(SB), NOPTR, $8
#else
GLOBL runtime·tls_g+0(SB), TLSBSS, $8
#endif
#endif
