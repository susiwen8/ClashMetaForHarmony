package main

/*
#include <stdint.h>
*/
import "C"

import (
	"sync"

	"github.com/clashmetaforandroid/harmony/core/go/internal/version"
)

var (
	coreVersionOnce sync.Once
	coreVersionCStr *C.char
)

func goCoreVersion() string {
	return version.Mihomo()
}

//export cmfa_mihomo_core_version_cstr_v1
func cmfa_mihomo_core_version_cstr_v1() *C.char {
	coreVersionOnce.Do(func() {
		coreVersionCStr = C.CString(goCoreVersion())
	})

	return coreVersionCStr
}

func main() {}
