// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package crossplatform

import (
	"archive/tar"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// The sources reach a container as an archive on its standard input and not
// as a mounted directory. A build in a mounted checkout would write its
// output, the links of Bazel and the directories of Cabal, into the
// developer's working tree, in the form of another operating system; and a
// directory shared between Windows and a Linux machine is slow enough to
// dominate a build. What is sent is what Git would commit: tracked files and
// new files that are not ignored, as they are in the working tree.

// SourceFiles parses the NUL-separated output of `git ls-files` into sorted,
// unique, slash-separated paths, and refuses a path that would leave the
// checkout.
func SourceFiles(listing string) ([]string, error) {
	seen := map[string]bool{}
	var files []string
	for _, entry := range strings.Split(listing, "\x00") {
		if entry == "" {
			continue
		}
		clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(entry)))
		if clean == "." || strings.HasPrefix(clean, "../") || clean == ".." || filepath.IsAbs(entry) || strings.HasPrefix(clean, "/") {
			return nil, fmt.Errorf("source path %q is outside the checkout", entry)
		}
		if !seen[clean] {
			seen[clean] = true
			files = append(files, clean)
		}
	}
	sort.Strings(files)
	return files, nil
}

// executableSource reports whether a file should be executable in the
// archive. A Windows working tree does not record that, so shell scripts are
// recognized by their extension.
func executableSource(path string, mode os.FileMode) bool {
	if mode&0o111 != 0 {
		return true
	}
	base := filepath.Base(path)
	return strings.HasSuffix(base, ".sh")
}

// WriteArchive writes the named files of the checkout as a tar stream and
// returns how many it wrote. A listed file that no longer exists, deleted in
// the working tree and not yet in the index, is left out; a directory, which
// is how a submodule without a checkout is listed, is too. Symbolic links are
// not followed and not sent.
func WriteArchive(output io.Writer, root string, files []string) (int, error) {
	archive := tar.NewWriter(output)
	written := 0
	for _, name := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return written, err
		}
		if !info.Mode().IsRegular() {
			continue
		}
		mode := int64(0o644)
		if executableSource(name, info.Mode()) {
			mode = 0o755
		}
		header := &tar.Header{Name: name, Mode: mode, Size: info.Size(), ModTime: info.ModTime(), Typeflag: tar.TypeReg, Format: tar.FormatPAX}
		if err := archive.WriteHeader(header); err != nil {
			return written, err
		}
		file, err := os.Open(path)
		if err != nil {
			return written, err
		}
		// A file that changes size while it is read would corrupt the
		// stream; the copy is bounded by the size in the header.
		copied, copyErr := io.CopyN(archive, file, info.Size())
		closeErr := file.Close()
		if copyErr != nil {
			return written, fmt.Errorf("could not read %s (%d of %d bytes): %w", name, copied, info.Size(), copyErr)
		}
		if closeErr != nil {
			return written, closeErr
		}
		written++
	}
	if err := archive.Close(); err != nil {
		return written, err
	}
	return written, nil
}
