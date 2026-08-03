package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const expectedProbeVersion = "cmfa-probe/v1"

func TestProbeVersion(t *testing.T) {
	if got := goProbeVersion(); got != expectedProbeVersion {
		t.Fatalf("goProbeVersion() = %q, want %q", got, expectedProbeVersion)
	}
}

func TestProbeAdd(t *testing.T) {
	if got := goProbeAdd(19, 23); got != 42 {
		t.Fatalf("goProbeAdd(19, 23) = %d, want 42", got)
	}
}

func TestProbeExportsRequiredSymbols(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "libcmfa_probe.so")
	command := exec.Command("go", "build", "-buildmode=c-shared", "-o", outputPath, ".")
	command.Env = append(os.Environ(), "CGO_ENABLED=1")

	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("go build -buildmode=c-shared failed: %v\n%s", err, output)
	}

	headerPath := strings.TrimSuffix(outputPath, ".so") + ".h"
	headerBytes, err := os.ReadFile(headerPath)
	if err != nil {
		t.Fatalf("read generated header: %v", err)
	}

	header := string(headerBytes)
	if !regexp.MustCompile(`(?m)^const char \*cmfa_probe_version\(void\);$`).MatchString(header) {
		t.Fatalf("generated header %s does not contain exact public version signature:\n%s", headerPath, header)
	}
	if !regexp.MustCompile(`(?m)^int32_t cmfa_probe_add\(int32_t left, int32_t right\);$`).MatchString(header) {
		t.Fatalf("generated header %s does not contain exact public add signature:\n%s", headerPath, header)
	}
	if regexp.MustCompile(`(?m)^extern char\* cmfa_probe_version\(void\);$`).MatchString(header) {
		t.Fatalf("generated header %s still exposes non-const public version signature:\n%s", headerPath, header)
	}
}
