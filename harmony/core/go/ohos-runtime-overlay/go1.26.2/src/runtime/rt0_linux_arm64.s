// Copyright 2015 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "textflag.h"

TEXT _rt0_arm64_linux(SB),NOSPLIT,$0
	JMP	_rt0_arm64(SB)

// When building with -buildmode=c-shared, this symbol is called when the shared
// library is loaded. OpenHarmony invokes init-array constructors without the
// glibc argc/argv extension, so provide a stable synthetic vector there.
TEXT _rt0_arm64_linux_lib(SB),NOSPLIT,$0
#ifdef CMFA_GOOS_OHOS
	MOVW	$1, R0
	MOVD	$_rt0_arm64_ohos_argv(SB), R1
#endif
	JMP	_rt0_arm64_lib(SB)

#ifdef CMFA_GOOS_OHOS
DATA _rt0_arm64_ohos_argv+0x00(SB)/8,$_rt0_arm64_ohos_argv0(SB)
DATA _rt0_arm64_ohos_argv+0x08(SB)/8,$0 // end argv
DATA _rt0_arm64_ohos_argv+0x10(SB)/8,$0 // end envv
DATA _rt0_arm64_ohos_argv+0x18(SB)/8,$0 // end auxv
GLOBL _rt0_arm64_ohos_argv(SB),NOPTR,$0x20

DATA _rt0_arm64_ohos_argv0(SB)/8, $"goohos"
GLOBL _rt0_arm64_ohos_argv0(SB),RODATA,$8
#endif
