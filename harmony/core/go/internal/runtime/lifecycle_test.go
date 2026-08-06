package runtime

import (
	"testing"
)

func TestLifecycleRejectsIllegalTransitions(t *testing.T) {
	lifecycle := NewLifecycle()

	if err := lifecycle.Transition(StateRunning); err == nil {
		t.Fatal("idle -> running unexpectedly succeeded")
	}

	if err := lifecycle.Transition(StateConfigLoaded); err != nil {
		t.Fatalf("idle -> config_loaded failed: %v", err)
	}

	if err := lifecycle.Transition(StateIdle); err == nil {
		t.Fatal("config_loaded -> idle unexpectedly succeeded")
	}

	if err := lifecycle.Transition(StateRunning); err != nil {
		t.Fatalf("config_loaded -> running failed: %v", err)
	}

	if err := lifecycle.Transition(StateConfigLoaded); err == nil {
		t.Fatal("running -> config_loaded unexpectedly succeeded")
	}

	if err := lifecycle.Transition(StateShutdown); err != nil {
		t.Fatalf("running -> shutdown failed: %v", err)
	}

	if err := lifecycle.Transition(StateStopped); err == nil {
		t.Fatal("shutdown -> stopped unexpectedly succeeded")
	}
}

func TestTransitionWithHoldsLifecycleLockUntilActionReturns(t *testing.T) {
	lifecycle := NewLifecycle()
	actionEntered := make(chan struct{})
	releaseAction := make(chan struct{})
	transitionDone := make(chan error, 1)

	go func() {
		transitionDone <- lifecycle.TransitionWith(StateConfigLoaded, func() error {
			close(actionEntered)
			<-releaseAction
			return nil
		})
	}()

	<-actionEntered
	if lifecycle.mu.TryLock() {
		lifecycle.mu.Unlock()
		t.Fatal("TransitionWith released lifecycle lock before action returned")
	}

	close(releaseAction)
	if err := <-transitionDone; err != nil {
		t.Fatalf("TransitionWith returned error: %v", err)
	}
	if lifecycle.State() != StateConfigLoaded {
		t.Fatalf("lifecycle state = %s want %s", lifecycle.State(), StateConfigLoaded)
	}
}
