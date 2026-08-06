package runtime_test

import (
	"testing"

	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
)

func TestLifecycleRejectsIllegalTransitions(t *testing.T) {
	lifecycle := runtimepkg.NewLifecycle()

	if err := lifecycle.Transition(runtimepkg.StateRunning); err == nil {
		t.Fatal("idle -> running unexpectedly succeeded")
	}

	if err := lifecycle.Transition(runtimepkg.StateConfigLoaded); err != nil {
		t.Fatalf("idle -> config_loaded failed: %v", err)
	}

	if err := lifecycle.Transition(runtimepkg.StateIdle); err == nil {
		t.Fatal("config_loaded -> idle unexpectedly succeeded")
	}

	if err := lifecycle.Transition(runtimepkg.StateRunning); err != nil {
		t.Fatalf("config_loaded -> running failed: %v", err)
	}

	if err := lifecycle.Transition(runtimepkg.StateConfigLoaded); err == nil {
		t.Fatal("running -> config_loaded unexpectedly succeeded")
	}

	if err := lifecycle.Transition(runtimepkg.StateShutdown); err != nil {
		t.Fatalf("running -> shutdown failed: %v", err)
	}

	if err := lifecycle.Transition(runtimepkg.StateStopped); err == nil {
		t.Fatal("shutdown -> stopped unexpectedly succeeded")
	}
}
