// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// The Linux hosts build with libc++, so they link an LLVM built with libc++
// as well: the distributions' LLVM packages use libstdc++, and the backend
// passes standard library types through LLVM's C++ API. The archives come
// from the toolchain release that .github/workflows/llvm-libcxx.yml
// publishes; a published tag is never replaced, and every archive is checked
// against the digest recorded here before it is used.
const (
	llvmToolchainVersion  = "22.1.6"
	llvmToolchainRevision = 1
)

// llvmToolchainArchitecture is the architecture the archives are chosen
// for; a variable so a test can stand in for another machine.
var llvmToolchainArchitecture = runtime.GOARCH

// llvmToolchainDigests holds the SHA-256 of the archive of each Linux host.
var llvmToolchainDigests = map[string]string{
	"ubuntu-26.04": "5e8a4c1f52b7d7eedf155b76bd057cec079e11daa66822d1f6af1109c551694b",
	"fedora-43":    "5355714911c1d1dcf7f3486d2f2c0b3a468be838314fbe42b49a07b1e86db7b5",
}

// llvmToolchainPlatform names the archive that suits a Linux host.
func llvmToolchainPlatform(currentHost host) (string, error) {
	if currentHost.kind != hostLinux {
		return "", errors.New("the LLVM toolchain archive is for the Linux hosts; Windows and macOS use their own LLVM")
	}
	if llvmToolchainArchitecture != "amd64" {
		return "", fmt.Errorf("only x86-64 LLVM toolchain archives are published; set LLVM_ROOT to an LLVM built with libc++ for %s", llvmToolchainArchitecture)
	}
	switch {
	case strings.HasPrefix(currentHost.name, "Ubuntu") && currentHost.version == "26.04":
		return "ubuntu-26.04", nil
	case strings.HasPrefix(currentHost.name, "Fedora") && currentHost.version == "43":
		return "fedora-43", nil
	default:
		return "", fmt.Errorf("no LLVM toolchain archive exists for %s %s", currentHost.name, currentHost.version)
	}
}

// llvmToolchainName is the name of an archive and of the directory it holds.
func llvmToolchainName(platform string) string {
	return fmt.Sprintf("llvm-%s-libcxx-%s-x86_64", llvmToolchainVersion, platform)
}

// llvmToolchainURL is where the archive of a platform is published.
func llvmToolchainURL(platform string) string {
	return fmt.Sprintf("https://github.com/Progmasoft/tala/releases/download/toolchain-llvm-%s-libcxx-%d/%s.tar.zst",
		llvmToolchainVersion, llvmToolchainRevision, llvmToolchainName(platform))
}

// llvmToolchainCache is the directory the archives are unpacked into:
// TALA_LLVM_CACHE when it is set, otherwise tala/llvm in the user cache.
func llvmToolchainCache() (string, error) {
	if configured := os.Getenv("TALA_LLVM_CACHE"); configured != "" {
		if !filepath.IsAbs(configured) {
			return "", fmt.Errorf("TALA_LLVM_CACHE must be an absolute path: %q", configured)
		}
		return configured, nil
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("no user cache directory for the LLVM toolchain; set TALA_LLVM_CACHE: %w", err)
	}
	return filepath.Join(cache, "tala", "llvm"), nil
}

// llvmToolchainMarker is written beside llvm-config once an archive is
// unpacked; it names the digest of the archive the directory came from.
const llvmToolchainMarker = "TALA-ARCHIVE-SHA256"

// unpackedLLVMToolchain returns the root of an unpacked toolchain when the
// directory exists and came from the archive with the expected digest.
func unpackedLLVMToolchain(root, digest string) bool {
	marker, err := os.ReadFile(filepath.Join(root, llvmToolchainMarker))
	if err != nil || strings.TrimSpace(string(marker)) != digest {
		return false
	}
	information, err := os.Stat(filepath.Join(root, "bin", "llvm-config"))
	return err == nil && !information.IsDir()
}

// downloadVerified writes the response for a URL to a file and fails unless
// its SHA-256 is the expected digest. A file that fails the check is removed.
func downloadVerified(client *http.Client, url, destination, digest string) error {
	response, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("could not download %s: %w", url, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("could not download %s: %s", url, response.Status)
	}
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	hash := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(output, hash), response.Body)
	closeErr := output.Close()
	if err := errors.Join(copyErr, closeErr); err != nil {
		os.Remove(destination)
		return fmt.Errorf("could not write %s: %w", destination, err)
	}
	if actual := hex.EncodeToString(hash.Sum(nil)); actual != digest {
		os.Remove(destination)
		return fmt.Errorf("%s has SHA-256 %s; the repository records %s", url, actual, digest)
	}
	return nil
}

// ensureLLVMToolchain returns the root of the LLVM toolchain of a Linux host,
// downloading, checking and unpacking its archive the first time. The archive
// is unpacked into a fresh directory and renamed into place, so an
// interrupted run never leaves a half-unpacked toolchain behind.
func ensureLLVMToolchain(currentHost host, runner commandRunner, client *http.Client) (string, error) {
	platform, err := llvmToolchainPlatform(currentHost)
	if err != nil {
		return "", err
	}
	digest := llvmToolchainDigests[platform]
	cache, err := llvmToolchainCache()
	if err != nil {
		return "", err
	}
	name := llvmToolchainName(platform)
	root := filepath.Join(cache, name)
	if unpackedLLVMToolchain(root, digest) {
		return root, nil
	}
	tar, err := runner.LookPath("tar")
	if err != nil {
		return "", errors.New("tar was not found; it unpacks the LLVM toolchain archive")
	}
	if _, err := runner.LookPath("zstd"); err != nil {
		return "", errors.New("zstd was not found; install it to unpack the LLVM toolchain archive")
	}
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return "", fmt.Errorf("could not create the LLVM toolchain cache %q: %w", cache, err)
	}
	work, err := os.MkdirTemp(cache, ".unpack-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(work)
	archive := filepath.Join(work, name+".tar.zst")
	fmt.Fprintf(os.Stderr, "Downloading LLVM %s with libc++ for %s...\n", llvmToolchainVersion, platform)
	if err := downloadVerified(client, llvmToolchainURL(platform), archive, digest); err != nil {
		return "", err
	}
	if err := runner.Run(work, nil, tar, "--zstd", "-xf", archive, "-C", work); err != nil {
		return "", fmt.Errorf("could not unpack %s: %w", archive, err)
	}
	unpacked := filepath.Join(work, name)
	if err := os.WriteFile(filepath.Join(unpacked, llvmToolchainMarker), []byte(digest+"\n"), 0o644); err != nil {
		return "", err
	}
	if !unpackedLLVMToolchain(unpacked, digest) {
		return "", fmt.Errorf("the archive of %s holds no bin/llvm-config", platform)
	}
	// A directory from an older or interrupted run gives way to the checked one.
	if err := os.RemoveAll(root); err != nil {
		return "", err
	}
	if err := os.Rename(unpacked, root); err != nil {
		return "", fmt.Errorf("could not move the LLVM toolchain into %q: %w", root, err)
	}
	return root, nil
}

// prepareLinuxLLVMRoot points LLVM_ROOT at the toolchain of a Linux host when
// nothing else names an LLVM, so the Bazel repository rule finds the libc++
// build instead of a distribution LLVM on PATH. A LLVM_ROOT that is already
// set is left as it is.
func prepareLinuxLLVMRoot(currentHost host, runner commandRunner) error {
	if currentHost.kind != hostLinux || os.Getenv("LLVM_ROOT") != "" {
		return nil
	}
	root, err := ensureLLVMToolchain(currentHost, runner, &http.Client{Timeout: 30 * time.Minute})
	if err != nil {
		return fmt.Errorf("could not prepare the LLVM toolchain; set LLVM_ROOT to an LLVM built with libc++: %w", err)
	}
	return os.Setenv("LLVM_ROOT", root)
}
