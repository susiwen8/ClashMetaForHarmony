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

//export cmfa_core_version
func cmfa_core_version() *C.char {
	coreVersionOnce.Do(func() {
		coreVersionCStr = C.CString(goCoreVersion())
	})

	return coreVersionCStr
}

func main() {}
