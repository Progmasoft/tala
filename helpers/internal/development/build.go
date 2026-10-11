// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package development

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

var nativeTargets = []string{
	"//Compiler/Artifact/Tests:source_path_tests",
	"//Compiler/ADTs/Tests:adt_tests",
	"//Compiler/Analysis/Tests:definite_initialization_tests",
	"//Compiler/Backend/LLVM/Tests:llvm_backend_tests",
	"//Compiler/Cli/Tests:cli_parser_tests",
	"//Compiler/Cli/Commands/Tests:execution_status_tests",
	"//Compiler/Cli/Commands/Tests:cli_command_tests",
	"//Compiler/Cli/Commands/Tests:executable_run_tests",
	"//Compiler/Core/Tests:callable_contract_tests",
	"//Compiler/Core/Tests:core_pipeline_tests",
	"//Compiler/Diagnostic/Tests:diagnostic_protocol_tests",
	"//Compiler/Driver/Tests:artifact_wire_tests",
	"//Compiler/Driver/Tests:closure_pipeline_tests",
	"//Compiler/Driver/Tests:project_artifact_tests",
	"//Compiler/Driver/Tests:scalar_pipeline_tests",
	"//Compiler/Codegen/Xmm/Tests:xmm_verifier_tests",
	"//Compiler/Codegen/Xpp/Tests:xpp_verifier_tests",
	"//Compiler/Runtime/AARC/Tests:aarc_runtime_tests",
	"//Compiler/Runtime/AARC/Tests:aarc_c_abi_tests",
	"//Compiler/Runtime/Text/Tests:text_runtime_tests",
	"//Compiler/Fuzzing:source_fuzz_smoke",
	"//Compiler/Fuzzing:source_execution_smoke",
	"//Compiler/Fuzzing:source_expression_smoke",
	"//Compiler/Fuzzing:source_feature_smoke",
	"//Compiler/Fuzzing:source_console_smoke",
	"//Compiler/Fuzzing/Tests:coreprep_parity_tests",
	"//Compiler/ProjectSystem/Bridge/Tests:project_registry_tests",
	"//Interactive/Tests:interactive_tests",
}

var nativePrograms = targetPrograms(nativeTargets)

var nativeBenchmarkTargets = []string{
	"//Compiler/Codegen/Xmm/Benches:xmm_benches",
	"//Compiler/Codegen/Xpp/Benches:xpp_benches",
	"//Compiler/Core/Benches:core_benches",
	"//Compiler/Core/CorePrep/Benches:coreprep_benches",
	"//Compiler/Driver/Benches:project_artifact_benches",
}

var nativeBenchmarkPrograms = targetPrograms(nativeBenchmarkTargets)

// Component-local executable paths follow their explicit Bazel labels. Derive
// them once so the build target and the program that is tested cannot drift.
func targetPrograms(targets []string) []string {
	programs := make([]string, len(targets))
	for index, target := range targets {
		programs[index] = strings.Replace(strings.TrimPrefix(target, "//"), ":", "/", 1)
	}
	return programs
}

// bundleFiles is deliberately explicit. A release must not accidentally absorb
// a stale license draft merely because it appeared under LICENSES/.
func buildTargets(repository string, runner commandRunner, config string, extra []string) error {
	frontendLibrary, err := buildFrontendLibrary(repository, runner)
	if err != nil {
		return err
	}
	bazel, err := findBazel(runner)
	if err != nil {
		return err
	}
	arguments := []string{"build"}
	if config != "" {
		arguments = append(arguments, "--config="+config)
	}
	arguments = append(arguments, "//Compiler/Cli:vxs")
	arguments = append(arguments, "//Interactive:vxsi")
	arguments = append(arguments, nativeTargets...)
	if runtimeLibraryTarget != "" {
		arguments = append(arguments, runtimeLibraryTarget)
	}
	arguments = append(arguments, extra...)
	fmt.Printf("Building compiler and %d native suites...\n", len(nativeTargets))
	if err := runner.Run(repository, nil, bazel, cachedBuild(arguments)...); err != nil {
		return fmt.Errorf("Bazel build failed: %w", err)
	}
	if err := stageFrontendForBuildOutputs(repository, frontendLibrary); err != nil {
		return err
	}
	return stageRuntimeForBuildOutputs(repository)
}

// The runtime library a native executable is linked with. The compiler looks
// for it beside its own executable under the name it is installed by. Native
// executables are linked on Windows only, so the library exists there only.
const runtimeLibraryName = "vxs-runtime.lib"

var runtimeLibraryTarget = func() string {
	if runtime.GOOS == "windows" {
		return "//Compiler/Runtime/Freestanding:vxs_runtime"
	}
	return ""
}()

// builtRuntimeLibrary is where Bazel leaves the archive of runtimeLibraryTarget.
func builtRuntimeLibrary(repository string) string {
	return filepath.Join(repository, "bazel-bin", "Compiler", "Runtime", "Freestanding", "vxs_runtime.lib")
}

// stageRuntimeForBuildOutputs puts the runtime library beside every program
// that may link a native executable: the compiler, and the suites that drive
// it in their own process.
func stageRuntimeForBuildOutputs(repository string) error {
	if runtimeLibraryTarget == "" {
		return nil
	}
	library := builtRuntimeLibrary(repository)
	if _, err := os.Stat(library); err != nil {
		return fmt.Errorf("Bazel did not produce the runtime library: %w", err)
	}
	executablePaths := append([]string{"Compiler/Cli/vxs", "Interactive/vxsi"}, nativePrograms...)
	for _, relative := range executablePaths {
		directory := filepath.Dir(filepath.Join(repository, "bazel-bin", filepath.FromSlash(relative)))
		if err := copyFile(library, filepath.Join(directory, runtimeLibraryName), 0o644); err != nil {
			return fmt.Errorf("cannot stage the runtime library beside %s: %w", relative, err)
		}
	}
	return nil
}

func buildFrontendLibrary(repository string, runner commandRunner) (string, error) {
	cabal, err := runner.LookPath("cabal")
	if err != nil {
		return "", errors.New("required tool \"cabal\" was not found; install the pinned GHCup toolchain")
	}
	if _, err := runner.LookPath("ghc"); err != nil {
		return "", errors.New("required tool \"ghc\" was not found; install the pinned GHCup toolchain")
	}
	compilerDirectory := filepath.Join(repository, "Compiler")
	fmt.Println("Building the in-process Haskell frontend shared library...")
	if err := runner.Run(compilerDirectory, criterionEnvironment(), cabal, "build", "visual-xsharp-compiler"); err != nil {
		return "", fmt.Errorf("Haskell frontend shared-library build failed: %w", err)
	}
	return locateFrontendLibrary(compilerDirectory)
}

func locateFrontendLibrary(compilerDirectory string) (string, error) {
	name := "libvxs-frontend.so"
	switch runtime.GOOS {
	case "windows":
		name = "vxs-frontend.dll"
	case "darwin":
		name = "libvxs-frontend.dylib"
	}
	searchRoot := filepath.Join(compilerDirectory, "dist-newstyle", "build")
	var candidates []string
	err := filepath.WalkDir(searchRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			if os.IsNotExist(walkErr) {
				return nil
			}
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		if entry.Name() == name && strings.Contains(filepath.ToSlash(path), "/f/vxs-frontend/") {
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if info.Mode().IsRegular() {
				candidates = append(candidates, path)
			}
		}
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("cannot locate the Cabal frontend library: %w", err)
	}
	if len(candidates) == 0 {
		return "", fmt.Errorf("Cabal did not produce %s under %s", name, searchRoot)
	}
	// Cabal may retain several compiler profiles. The newest completed artifact
	// is selected; it is copied beside each executable, so no PATH search occurs.
	sort.Slice(candidates, func(left int, right int) bool {
		leftInfo, leftErr := os.Stat(candidates[left])
		rightInfo, rightErr := os.Stat(candidates[right])
		return leftErr == nil && (rightErr != nil || leftInfo.ModTime().After(rightInfo.ModTime()))
	})
	return candidates[0], nil
}

func executableSuffix() string {
	if runtime.GOOS == "windows" {
		return ".exe"
	}
	return ""
}

func stageFrontendForBuildOutputs(repository string, frontendLibrary string) error {
	frontendName := filepath.Base(frontendLibrary)
	executablePaths := append([]string{"Compiler/Cli/vxs", "Interactive/vxsi"}, nativePrograms...)
	for _, relative := range executablePaths {
		executable := filepath.Join(repository, "bazel-bin", filepath.FromSlash(relative)+executableSuffix())
		if _, err := os.Stat(executable); err != nil {
			return fmt.Errorf("Bazel did not produce expected executable %s: %w", relative, err)
		}
		if err := copyFile(frontendLibrary, filepath.Join(filepath.Dir(executable), frontendName), 0o755); err != nil {
			return fmt.Errorf("cannot stage frontend beside %s: %w", relative, err)
		}
	}
	return nil
}

func runBenchmarks(repository string, currentHost host, runner commandRunner, bazelArguments []string, options benchmarkOptions) error {
	results, err := options.resultDirectory()
	if err != nil {
		return err
	}
	if !options.haskellOnly {
		if err := runNativeBenchmarks(repository, currentHost, runner, bazelArguments, options, results); err != nil {
			return err
		}
	}
	if !options.nativeOnly {
		if err := runHaskellBenchmarks(repository, runner, options, results); err != nil {
			return err
		}
	}
	if results != "" {
		fmt.Printf("\nBenchmark results written to %s.\n", results)
	}
	return nil
}

func runNativeBenchmarks(repository string, currentHost host, runner commandRunner, bazelArguments []string, options benchmarkOptions, results string) error {
	bazel, err := findBazel(runner)
	if err != nil {
		return err
	}
	// Fastbuild is excellent for iteration but distorts microbenchmarks with
	// debug libraries and disabled optimization. The benchmark command owns an
	// optimized profile so every recorded result has the same basic contract.
	arguments := append([]string{"build", "-c", "opt"}, nativeBenchmarkTargets...)
	arguments = append(arguments, bazelArguments...)
	fmt.Printf("Building %d native benchmark programs...\n", len(nativeBenchmarkTargets))
	if err := runner.Run(repository, nil, bazel, cachedBuild(arguments)...); err != nil {
		return fmt.Errorf("native benchmark build failed: %w", err)
	}
	for index, program := range nativeBenchmarkPrograms {
		path := filepath.Join(repository, "bazel-bin", filepath.FromSlash(program)) + currentHost.executable
		fmt.Printf("\n[%d/%d] %s\n", index+1, len(nativeBenchmarkPrograms), filepath.Base(program))
		if err := runner.Run(repository, nil, path, options.nativeArguments(results, filepath.Base(program))...); err != nil {
			return fmt.Errorf("native benchmark %s failed: %w", filepath.Base(program), err)
		}
	}
	return nil
}

func runHaskellBenchmarks(repository string, runner commandRunner, options benchmarkOptions, results string) error {
	cabal, err := runner.LookPath("cabal")
	if err != nil {
		return errors.New("required tool \"cabal\" was not found; install GHCup's Cabal tool to run Haskell benchmarks")
	}
	fmt.Println("\nRunning Criterion Core and CorePrep benchmarks...")
	compilerDirectory := filepath.Join(repository, "Compiler")
	benchmarkEnvironment := criterionEnvironment()
	if results != "" {
		// Criterion appends to a report that is already there; a result set
		// holds one run.
		if err := os.Remove(filepath.Join(results, haskellBenchmarkReport)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("cannot replace the earlier Haskell benchmark report: %w", err)
		}
	}
	arguments := append([]string{"bench", "visual-xsharp-core:core-benches", "--enable-benchmarks"}, options.criterionArguments(results)...)
	if err := runner.Run(compilerDirectory, benchmarkEnvironment, cabal, arguments...); err != nil {
		return fmt.Errorf("Haskell benchmark run failed: %w", err)
	}
	return nil
}

func criterionEnvironment() []string {
	// Criterion prints the microsecond symbol even when the benchmark names are
	// otherwise ASCII. Force a Unicode-capable GHC handle encoding so Windows
	// consoles cannot abort an otherwise valid benchmark after measurements.
	return []string{"GHC_CHARENC=UTF-8"}
}

func runTests(repository string, currentHost host, runner commandRunner, environment []string) error {
	for index, program := range nativePrograms {
		path := filepath.Join(repository, "bazel-bin", filepath.FromSlash(program)) + currentHost.executable
		fmt.Printf("[%d/%d] %s\n", index+1, len(nativePrograms), filepath.Base(program))
		if err := runner.Run(repository, environment, path); err != nil {
			return fmt.Errorf("native suite %s failed: %w", filepath.Base(program), err)
		}
	}
	fmt.Printf("\nAll %d native suites passed.\n", len(nativePrograms))
	return nil
}
