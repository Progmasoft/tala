// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestTheLinuxHostsHaveAnArchiveAndADigest(t *testing.T) {
	previous := llvmToolchainArchitecture
	llvmToolchainArchitecture = "amd64"
	defer func() { llvmToolchainArchitecture = previous }()
	for _, example := range []struct {
		host     host
		platform string
	}{
		{host{kind: hostLinux, name: "Ubuntu 26.04 LTS", version: "26.04"}, "ubuntu-26.04"},
		{host{kind: hostLinux, name: "Fedora 43 (N-1)", version: "43"}, "fedora-43"},
	} {
		platform, err := llvmToolchainPlatform(example.host)
		if err != nil || platform != example.platform {
			t.Fatalf("%s: platform = %q, %v; want %q", example.host.name, platform, err, example.platform)
		}
		if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(llvmToolchainDigests[platform]) {
			t.Fatalf("%s has no SHA-256 digest", platform)
		}
	}
	for _, other := range []host{{kind: hostWindows}, {kind: hostMacOS}, {kind: hostLinux, name: "Ubuntu 24.04 LTS", version: "24.04"}} {
		if _, err := llvmToolchainPlatform(other); err == nil {
			t.Fatalf("%v must have no archive", other)
		}
	}
	llvmToolchainArchitecture = "arm64"
	if _, err := llvmToolchainPlatform(host{kind: hostLinux, name: "Ubuntu 26.04 LTS", version: "26.04"}); err == nil {
		t.Fatal("an arm64 host must not get an x86-64 archive")
	}
}

func TestTheArchiveComesFromTheImmutableToolchainRelease(t *testing.T) {
	want := "https://github.com/Progmasoft/tala/releases/download/toolchain-llvm-22.1.6-libcxx-2/llvm-22.1.6-libcxx-fedora-43-x86_64.tar.zst"
	if got := llvmToolchainURL("fedora-43"); got != want {
		t.Fatalf("URL = %q, want %q", got, want)
	}
}

// The container images unpack the same archive while they are built, because a
// container run has no network. Their digests must be the ones recorded here.
func TestTheContainerImagesUnpackTheRecordedArchives(t *testing.T) {
	repository, err := findRepositoryRoot()
	if err != nil {
		t.Skip("not inside the repository")
	}
	for platform, digest := range llvmToolchainDigests {
		containerfile, err := os.ReadFile(filepath.Join(repository, "helpers", "containers", platform, "Containerfile"))
		if err != nil {
			t.Fatal(err)
		}
		text := string(containerfile)
		if !strings.Contains(text, digest) || !strings.Contains(text, llvmToolchainURL(platform)) {
			t.Fatalf("the %s Containerfile does not unpack %s with digest %s", platform, llvmToolchainURL(platform), digest)
		}
	}
}

func TestADownloadIsKeptOnlyWithTheRecordedDigest(t *testing.T) {
	content := []byte("archive bytes")
	sum := sha256.Sum256(content)
	digest := hex.EncodeToString(sum[:])
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/missing" {
			http.NotFound(writer, request)
			return
		}
		writer.Write(content)
	}))
	defer server.Close()
	directory := t.TempDir()

	good := filepath.Join(directory, "good")
	if err := downloadVerified(server.Client(), server.URL+"/archive", good, digest); err != nil {
		t.Fatal(err)
	}
	if kept, err := os.ReadFile(good); err != nil || string(kept) != string(content) {
		t.Fatalf("kept %q, %v", kept, err)
	}

	bad := filepath.Join(directory, "bad")
	err := downloadVerified(server.Client(), server.URL+"/archive", bad, strings.Repeat("0", 64))
	if err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("a wrong digest must fail: %v", err)
	}
	if _, err := os.Stat(bad); !os.IsNotExist(err) {
		t.Fatalf("a file with the wrong digest must be removed: %v", err)
	}

	if err := downloadVerified(server.Client(), server.URL+"/missing", filepath.Join(directory, "missing"), digest); err == nil {
		t.Fatal("a missing archive must fail")
	}
}

func TestAnUnpackedToolchainIsUsedOnlyWithItsMarker(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin", "llvm-config"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if unpackedLLVMToolchain(root, "abc") {
		t.Fatal("a directory without a marker is not a checked toolchain")
	}
	if err := os.WriteFile(filepath.Join(root, llvmToolchainMarker), []byte("other\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if unpackedLLVMToolchain(root, "abc") {
		t.Fatal("a directory from another archive is not this toolchain")
	}
	if err := os.WriteFile(filepath.Join(root, llvmToolchainMarker), []byte("abc\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !unpackedLLVMToolchain(root, "abc") {
		t.Fatal("a directory with its marker and llvm-config is the toolchain")
	}
}

func TestTheCacheIsTheConfiguredAbsoluteDirectory(t *testing.T) {
	absolute := t.TempDir()
	t.Setenv("TALA_LLVM_CACHE", absolute)
	if cache, err := llvmToolchainCache(); err != nil || cache != absolute {
		t.Fatalf("cache = %q, %v", cache, err)
	}
	t.Setenv("TALA_LLVM_CACHE", "relative")
	if _, err := llvmToolchainCache(); err == nil {
		t.Fatal("a relative TALA_LLVM_CACHE must be refused")
	}
}

func TestAnLLVMRootThatIsSetIsLeftAsItIs(t *testing.T) {
	t.Setenv("LLVM_ROOT", "/opt/llvm")
	if err := prepareLinuxLLVMRoot(host{kind: hostLinux, name: "Ubuntu 26.04 LTS", version: "26.04"}, fakeRunner{}); err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv("LLVM_ROOT"); got != "/opt/llvm" {
		t.Fatalf("LLVM_ROOT = %q", got)
	}
	t.Setenv("LLVM_ROOT", "")
	if err := prepareLinuxLLVMRoot(host{kind: hostWindows}, fakeRunner{}); err != nil || os.Getenv("LLVM_ROOT") != "" {
		t.Fatalf("Windows must not get a downloaded LLVM: %v", err)
	}
}
