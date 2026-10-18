// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// repositorySourceRoots are the directories whose Tala sources seed the
// targets that read source text. They are the programs the repository already
// maintains for other reasons: the examples, the samples of the specification
// and the fixtures of the Core tests. Seeding from them keeps
// the corpus as wide as the language the repository exercises, without a
// second copy of any program to keep in step.
func repositorySourceRoots() []string {
	return []string{
		"Examples",
		"Spec",
		filepath.Join("Talac", "Core"),
	}
}

// readsSourceText reports whether a corpus holds Tala source text. The
// other corpora hold selectors, argument lists or records of their own.
func readsSourceText(corpus string) bool {
	switch corpus {
	case "lexer", "parser", "source":
		return true
	}
	return false
}

// syncRepositorySources copies every Tala source under the seed roots
// into a corpus and returns how many the corpus now holds from them. A source
// longer than the input limit of the target is left out: the target would
// reject it unread. A seed is named after its content, so a source that
// changes adds a seed and never replaces one, and a second run adds nothing.
func syncRepositorySources(repository string, destination string, limit int) (int, error) {
	held := 0
	for _, root := range repositorySourceRoots() {
		start := filepath.Join(repository, root)
		if _, err := os.Stat(start); os.IsNotExist(err) {
			continue
		} else if err != nil {
			return held, err
		}
		err := filepath.WalkDir(start, func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.IsDir() || !entry.Type().IsRegular() || !strings.EqualFold(filepath.Ext(path), ".tala") {
				return nil
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if info.Size() == 0 || info.Size() > int64(limit) {
				return nil
			}
			seed, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			digest := sha256.Sum256(seed)
			target := filepath.Join(destination, fmt.Sprintf("repository-%x.tala", digest[:16]))
			if existing, err := os.Lstat(target); err == nil {
				if !existing.Mode().IsRegular() {
					return fmt.Errorf("cached corpus entry is not a regular file: %q", target)
				}
				held++
				return nil
			} else if !os.IsNotExist(err) {
				return err
			}
			if err := writeSeedExclusive(target, seed); err != nil {
				return err
			}
			held++
			return nil
		})
		if err != nil {
			return held, err
		}
	}
	return held, nil
}
