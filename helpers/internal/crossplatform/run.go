// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package crossplatform

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"github.com/Progmasoft/tala/helpers/internal/console"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Engine is what the tool needs of Podman and Git. Tests replace it.
type Engine interface {
	// LookPath finds a program.
	LookPath(name string) (string, error)
	// Output runs a program and returns its standard output.
	Output(directory string, name string, arguments ...string) (string, error)
	// Run runs a program with the given standard input, writing what it
	// prints to the given writers.
	Run(directory string, input io.Reader, output io.Writer, errorOutput io.Writer, name string, arguments ...string) error
}

// SystemEngine runs real programs. With a Console each program is a step;
// without one its output goes straight to the given writers.
type SystemEngine struct {
	Console *console.Console
}

func (SystemEngine) LookPath(name string) (string, error) { return exec.LookPath(name) }

func (SystemEngine) Output(directory string, name string, arguments ...string) (string, error) {
	command := exec.Command(name, arguments...)
	command.Dir = directory
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil {
		return string(output), fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return string(output), nil
}

func (engine SystemEngine) Run(directory string, input io.Reader, output io.Writer, errorOutput io.Writer, name string, arguments ...string) error {
	if engine.Console == nil {
		return runProgram(directory, input, output, errorOutput, name, arguments)
	}
	work := func(stdout, stderr io.Writer) error {
		return runProgram(directory, input, stdout, stderr, name, arguments)
	}
	title := console.Describe(name, arguments)
	// gh run watch draws the state of a workflow run itself.
	if len(arguments) >= 2 && arguments[0] == "run" && arguments[1] == "watch" {
		return engine.Console.Live(title, work)
	}
	return engine.Console.Step(title, work)
}

func runProgram(directory string, input io.Reader, output io.Writer, errorOutput io.Writer, name string, arguments []string) error {
	command := exec.Command(name, arguments...)
	command.Dir = directory
	command.Stdin = input
	command.Stdout = output
	command.Stderr = errorOutput
	return command.Run()
}

// Options are what one run is asked to do.
type Options struct {
	// Repository is the root of the checkout.
	Repository string
	// Script is what `sh -eu` runs in the root of the sources.
	Script string
	// RebuildImage builds the image again even when one exists.
	RebuildImage bool
	// CPUs and Memory bound what a build and a run may use. A container
	// that takes every processor and all the memory of Podman's machine
	// takes them from the desktop it runs on.
	CPUs   int
	Memory string
	// Output and ErrorOutput receive what the container prints.
	Output      io.Writer
	ErrorOutput io.Writer
}

// Result is the outcome of one target.
type Result struct {
	Target string `json:"target"`
	Passed bool   `json:"passed"`
	Error  string `json:"error,omitempty"`
}

// ImageName is the tag of a target's image. It holds a digest of the build
// file, so that a change of the file is a new image and an unchanged file
// is never built twice.
func ImageName(target Target, containerfile []byte) string {
	digest := sha256.Sum256(bytes.ReplaceAll(containerfile, []byte("\r\n"), []byte("\n")))
	return fmt.Sprintf("%s%s:%x", imagePrefix, target.Name, digest[:6])
}

// CacheVolume is the volume that keeps a target's downloads and build output
// between runs: the Bazel output base, the Cabal store and the Go caches.
func CacheVolume(target Target) string {
	return volumePrefix + target.Name
}

// containerScript is what runs in the container: unpack the sources from
// standard input into a directory of their own, point every tool's cache at
// the volume, and run the script there. The sources are replaced on each
// run; the caches are what makes the second run short.
func containerScript(script string) string {
	return strings.Join([]string{
		"set -eu",
		"rm -rf /work/source",
		"mkdir -p /work/source /cache/home",
		"tar -xf - -C /work/source",
		"export HOME=/cache/home",
		"export GOFLAGS=-buildvcs=false",
		`export LLVM_ROOT="$(llvm-config --prefix)"`,
		"cd /work/source",
		script,
	}, "\n")
}

// runLimits are the options that bound a container.
func runLimits(options Options) []string {
	var limits []string
	if options.CPUs > 0 {
		limits = append(limits, "--cpus", fmt.Sprint(options.CPUs))
	}
	if options.Memory != "" {
		limits = append(limits, "--memory", options.Memory)
	}
	return limits
}

// buildLimits are the same bounds as an image build takes them: it has no
// count of processors, only a share of each scheduling period.
func buildLimits(options Options) []string {
	var limits []string
	if options.CPUs > 0 {
		limits = append(limits, "--cpu-period", "100000", "--cpu-quota", fmt.Sprint(options.CPUs*100000))
	}
	if options.Memory != "" {
		limits = append(limits, "--memory", options.Memory)
	}
	return limits
}

const (
	imagePrefix  = "localhost/tala-cross-"
	volumePrefix = "tala-cross-"
)

// Owned lists the images and the volumes this tool created.
func Owned(engine Engine, podman string) (images []string, volumes []string, err error) {
	listed, err := engine.Output("", podman, "images", "--format", "{{.Repository}}:{{.Tag}}\t{{.Size}}")
	if err != nil {
		return nil, nil, fmt.Errorf("Podman could not list its images: %w", err)
	}
	for _, line := range strings.Split(strings.ReplaceAll(listed, "\r\n", "\n"), "\n") {
		if strings.HasPrefix(line, imagePrefix) {
			images = append(images, line)
		}
	}
	listed, err = engine.Output("", podman, "volume", "ls", "--format", "{{.Name}}")
	if err != nil {
		return nil, nil, fmt.Errorf("Podman could not list its volumes: %w", err)
	}
	for _, line := range strings.Split(strings.ReplaceAll(listed, "\r\n", "\n"), "\n") {
		if strings.HasPrefix(line, volumePrefix) {
			volumes = append(volumes, strings.TrimSpace(line))
		}
	}
	return images, volumes, nil
}

// Usage prints what this tool keeps in Podman and how much room Podman's
// storage takes as a whole.
func Usage(engine Engine, output io.Writer) error {
	podman, err := EnsurePodman(engine)
	if err != nil {
		return err
	}
	images, volumes, err := Owned(engine, podman)
	if err != nil {
		return err
	}
	fmt.Fprintf(output, "Images of this tool: %d\n", len(images))
	for _, image := range images {
		fmt.Fprintf(output, "  %s\n", image)
	}
	fmt.Fprintf(output, "Cache volumes of this tool: %d\n", len(volumes))
	for _, volume := range volumes {
		fmt.Fprintf(output, "  %s\n", volume)
	}
	summary, err := engine.Output("", podman, "system", "df")
	if err != nil {
		return fmt.Errorf("Podman could not report its storage: %w", err)
	}
	fmt.Fprintf(output, "\nAll of Podman's storage:\n%s", summary)
	return nil
}

// Clean removes the images and the cache volumes this tool created, and the
// layers no image uses any more. Nothing else in Podman is touched. It
// returns how many images and volumes it removed.
func Clean(engine Engine, output io.Writer, errorOutput io.Writer) (int, int, error) {
	podman, err := EnsurePodman(engine)
	if err != nil {
		return 0, 0, err
	}
	images, volumes, err := Owned(engine, podman)
	if err != nil {
		return 0, 0, err
	}
	for _, image := range images {
		name := strings.SplitN(image, "\t", 2)[0]
		if err := engine.Run("", nil, output, errorOutput, podman, "rmi", "--force", name); err != nil {
			return 0, 0, fmt.Errorf("image %s could not be removed: %w", name, err)
		}
	}
	for _, volume := range volumes {
		if err := engine.Run("", nil, output, errorOutput, podman, "volume", "rm", "--force", volume); err != nil {
			return 0, 0, fmt.Errorf("volume %s could not be removed: %w", volume, err)
		}
	}
	// What the builds left behind: stages and layers without a name.
	if err := engine.Run("", nil, output, errorOutput, podman, "image", "prune", "--force"); err != nil {
		return 0, 0, fmt.Errorf("unused layers could not be removed: %w", err)
	}
	return len(images), len(volumes), nil
}

// EnsurePodman finds Podman and checks that it can start a container.
func EnsurePodman(engine Engine) (string, error) {
	podman, err := engine.LookPath("podman")
	if err != nil {
		return "", errors.New("required tool \"podman\" was not found; install it with `go run ./helpers/cmd/prebuild install`")
	}
	// `podman info` reaches the machine that runs the containers; the client
	// alone answers `podman version` even when there is none.
	if _, err := engine.Output("", podman, "info"); err != nil {
		return "", fmt.Errorf("Podman is installed but cannot start containers: %w\n"+
			"On Windows and macOS it needs its Linux machine: run `podman machine init` once and `podman machine start`.", err)
	}
	return podman, nil
}

// EnsureImage builds the image of a target unless it exists, and returns its
// name.
func EnsureImage(engine Engine, podman string, target Target, options Options) (string, error) {
	path := filepath.Join(options.Repository, filepath.FromSlash(target.Containerfile))
	containerfile, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("the build file of target %s is not readable: %w", target.Name, err)
	}
	image := ImageName(target, containerfile)
	if !options.RebuildImage {
		if _, err := engine.Output("", podman, "image", "exists", image); err == nil {
			return image, nil
		}
	}
	fmt.Fprintf(options.Output, "Building the image of %s; the first build downloads the toolchain and takes a while.\n", target.Name)
	arguments := []string{"build", "--tag", image, "--file", path}
	arguments = append(arguments, buildLimits(options)...)
	if options.RebuildImage {
		arguments = append(arguments, "--no-cache")
	}
	arguments = append(arguments, filepath.Dir(path))
	if err := engine.Run("", nil, options.Output, options.ErrorOutput, podman, arguments...); err != nil {
		return "", fmt.Errorf("the image of target %s could not be built: %w", target.Name, err)
	}
	return image, nil
}

// RunTarget sends the sources to a container of the target and runs the
// script there.
func RunTarget(engine Engine, podman string, target Target, files []string, options Options) error {
	image, err := EnsureImage(engine, podman, target, options)
	if err != nil {
		return err
	}
	reader, writer := io.Pipe()
	archived := make(chan error, 1)
	go func() {
		_, archiveErr := WriteArchive(writer, options.Repository, files)
		archived <- archiveErr
		writer.CloseWithError(archiveErr)
	}()
	arguments := []string{"run", "--rm", "--interactive"}
	arguments = append(arguments, runLimits(options)...)
	arguments = append(arguments,
		"--volume", CacheVolume(target)+":/cache",
		image, "sh", "-c", containerScript(options.Script))
	runErr := engine.Run("", reader, options.Output, options.ErrorOutput, podman, arguments...)
	// The container may stop before it has read everything; closing the
	// reading end lets the archiver finish instead of waiting forever.
	reader.Close()
	archiveErr := <-archived
	if runErr != nil {
		return fmt.Errorf("target %s failed: %w", target.Name, runErr)
	}
	if archiveErr != nil && !errors.Is(archiveErr, io.ErrClosedPipe) {
		return fmt.Errorf("the sources could not be sent to target %s: %w", target.Name, archiveErr)
	}
	return nil
}

// ListSources asks Git for what it would commit: tracked files, with those of
// checked-out submodules, and new files that are not ignored.
func ListSources(engine Engine, repository string) ([]string, error) {
	git, err := engine.LookPath("git")
	if err != nil {
		return nil, errors.New("required tool \"git\" was not found")
	}
	tracked, err := engine.Output(repository, git, "ls-files", "-z", "--cached", "--recurse-submodules")
	if err != nil {
		return nil, fmt.Errorf("git could not list the tracked files: %w", err)
	}
	untracked, err := engine.Output(repository, git, "ls-files", "-z", "--others", "--exclude-standard")
	if err != nil {
		return nil, fmt.Errorf("git could not list the new files: %w", err)
	}
	return SourceFiles(tracked + "\x00" + untracked)
}

// RunAll runs the script on every target and returns one result for each. A
// failure of one target does not stop the others: the point of the run is to
// learn where the sources fail.
func RunAll(engine Engine, targets []Target, options Options) ([]Result, error) {
	podman, err := EnsurePodman(engine)
	if err != nil {
		return nil, err
	}
	files, err := ListSources(engine, options.Repository)
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, errors.New("git lists no source file in this checkout")
	}
	results := make([]Result, 0, len(targets))
	for _, target := range targets {
		fmt.Fprintf(options.Output, "\n=== %s: %s ===\n", target.Name, target.Description)
		result := Result{Target: target.Name, Passed: true}
		if err := RunTarget(engine, podman, target, files, options); err != nil {
			result.Passed = false
			result.Error = err.Error()
			fmt.Fprintf(options.ErrorOutput, "%s\n", err)
		}
		results = append(results, result)
	}
	return results, nil
}
