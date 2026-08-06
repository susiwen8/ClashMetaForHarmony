package probe

import (
	"testing"
	"time"
)

func TestTrackerObservationRequiresExactNormalizedSourceAddress(t *testing.T) {
	observation, err := newTrackerObservation("[::1]:50001", "127.0.0.1:9443", "HTTPS")
	if err != nil {
		t.Fatalf("newTrackerObservation(...) error = %v", err)
	}

	if observation.matches("::1:50001", "127.0.0.1:9443", "HTTPS") {
		t.Fatal("tracker match should reject a malformed unbracketed IPv6 source address")
	}
	if observation.matches("[::2]:50001", "127.0.0.1:9443", "HTTPS") {
		t.Fatal("tracker match should reject the wrong source IP even when the port matches")
	}
	if observation.matches("[::1]:50001", "127.0.0.1:9443", "Socks5") {
		t.Fatal("tracker match should reject the wrong inbound type")
	}
	if !observation.matches("[::1]:50001", "127.0.0.1:9443", "HTTPS") {
		t.Fatal("tracker match should accept the normalized exact source address")
	}
}

func TestTrackerObservationNormalizesBracketedAndCanonicalIPv6(t *testing.T) {
	observation, err := newTrackerObservation("[2001:db8::1]:41234", "example.invalid:443", "HTTPS")
	if err != nil {
		t.Fatalf("newTrackerObservation(...) error = %v", err)
	}

	if !observation.matches("[2001:db8:0:0:0:0:0:1]:41234", "example.invalid:443", "HTTPS") {
		t.Fatal("tracker match should treat equivalent IPv6 spellings as the same client source")
	}
}

func TestCancelProbeRunRejectsEmptyRunID(t *testing.T) {
	if status := CancelProbeRun(""); status != CancelRunInvalid {
		t.Fatalf("CancelProbeRun(\"\") = %v, want %v", status, CancelRunInvalid)
	}
}

func TestNewTrackerObservationRejectsInvalidSourceAddress(t *testing.T) {
	if _, err := newTrackerObservation("missing-port", "127.0.0.1:9443", "HTTPS"); err == nil {
		t.Fatal("newTrackerObservation should reject an invalid client source address")
	}
}

func TestManagedRunTimeoutDefaultsPositive(t *testing.T) {
	if managedProbeTimeout <= 0 || managedProbeTimeout < 5*time.Second {
		t.Fatalf("managedProbeTimeout = %s, want a bounded production timeout", managedProbeTimeout)
	}
}
