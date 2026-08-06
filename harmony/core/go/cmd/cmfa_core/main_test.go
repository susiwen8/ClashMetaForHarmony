package main

import (
	"encoding/json"
	"errors"
	"testing"

	runtimepkg "github.com/clashmetaforandroid/harmony/core/go/internal/runtime"
	"github.com/clashmetaforandroid/harmony/core/go/internal/version"
)

func TestBuildInfoPrivateExportIncludesPinnedFields(t *testing.T) {
	raw := goBuildInfoJSON()
	var info version.Info
	if err := json.Unmarshal([]byte(raw), &info); err != nil {
		t.Fatalf("unmarshal build info: %v", err)
	}

	expected := version.Build()
	if info.Version != expected.Version {
		t.Fatalf("version mismatch: got %q want %q", info.Version, expected.Version)
	}
	if info.UpstreamCommit != expected.UpstreamCommit {
		t.Fatalf("commit mismatch: got %q want %q", info.UpstreamCommit, expected.UpstreamCommit)
	}
	if info.ABIVersion != expected.ABIVersion {
		t.Fatalf("abi mismatch: got %q want %q", info.ABIVersion, expected.ABIVersion)
	}
	if info.BuildID != expected.BuildID {
		t.Fatalf("buildID mismatch: got %q want %q", info.BuildID, expected.BuildID)
	}
}

func TestFailureMessagePrefersSnapshotLastError(t *testing.T) {
	snapshot := runtimepkg.Snapshot{LastError: "redacted snapshot error"}
	err := errors.New("raw backend error")

	if got := failureMessage(snapshot, err); got != "redacted snapshot error" {
		t.Fatalf("failureMessage = %q want snapshot last error", got)
	}
}
