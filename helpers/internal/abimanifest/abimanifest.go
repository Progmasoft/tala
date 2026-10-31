// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

// Package abimanifest compares Documents/abi-manifest.json with the sources
// it describes.
//
// The manifest states the binary interfaces of the compiler in one place:
// the C functions of the frontend library and of the runtime, the numbers
// those functions exchange, the versions of the wire formats, and how an
// executable is entered and linked. Each of those facts is written in a
// header, a module-definition file, a Haskell module or a C++ source. A
// manifest that is maintained by hand beside them would drift, so nothing
// here is trusted: every entry is read back from where it is defined, and a
// difference in either direction is an error.
package abimanifest

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Manifest is Documents/abi-manifest.json.
type Manifest struct {
	Schema          int    `json:"schema"`
	Description     string `json:"description"`
	FrontendLibrary struct {
		AbiVersion  int               `json:"abi_version"`
		Header      string            `json:"header"`
		Libraries   map[string]string `json:"libraries"`
		Symbols     []string          `json:"symbols"`
		OutputKinds map[string]int    `json:"output_kinds"`
		Statuses    map[string]int    `json:"statuses"`
	} `json:"frontend_library"`
	Runtime struct {
		Ownership struct {
			AbiVersion   int      `json:"abi_version"`
			Header       string   `json:"header"`
			Symbols      []string `json:"symbols"`
			TypeMetadata []string `json:"type_metadata"`
		} `json:"ownership"`
		Text struct {
			Header    string         `json:"header"`
			Symbols   []string       `json:"symbols"`
			Constants map[string]int `json:"constants"`
		} `json:"text"`
	} `json:"runtime"`
	WireFormats []WireFormat `json:"wire_formats"`
	Executable  struct {
		Extensions    map[string]string        `json:"extensions"`
		SourceEntry   string                   `json:"source_entry"`
		EntrySymbols  map[string]string        `json:"entry_symbols"`
		ObjectFormats map[string]string        `json:"object_formats"`
		NativeLinking map[string]NativeLinking `json:"native_linking"`
	} `json:"executable"`
}

// WireFormat is one serialized intermediate representation.
type WireFormat struct {
	Name    string `json:"name"`
	Magic   string `json:"magic"`
	Version int    `json:"version"`
}

// NativeLinking is how an executable is linked on one platform.
type NativeLinking struct {
	Linker               string              `json:"linker"`
	RuntimeLibrary       string              `json:"runtime_library"`
	SharedRuntimeLibrary string              `json:"shared_runtime_library"`
	SystemImports        map[string][]string `json:"system_imports,omitempty"`
}

// Path is where the manifest lives in the repository.
const Path = "Documents/abi-manifest.json"

// Load reads and decodes the manifest. A field the manifest has and this
// package does not know is an error: it would be a statement nothing checks.
func Load(repository string) (Manifest, error) {
	var manifest Manifest
	content, err := os.ReadFile(filepath.Join(repository, filepath.FromSlash(Path)))
	if err != nil {
		return manifest, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return manifest, fmt.Errorf("%s is not a manifest this tool understands: %w", Path, err)
	}
	return manifest, nil
}

// sources reads the files of the repository the manifest is compared with.
type sources struct {
	repository string
	problems   []string
}

func (source *sources) read(path string) string {
	content, err := os.ReadFile(filepath.Join(source.repository, filepath.FromSlash(path)))
	if err != nil {
		source.problems = append(source.problems, fmt.Sprintf("%s could not be read: %v", path, err))
		return ""
	}
	return strings.ReplaceAll(string(content), "\r\n", "\n")
}

// readAny reads the first of the paths that exists.
func (source *sources) readAny(paths ...string) string {
	for _, path := range paths {
		if _, err := os.Stat(filepath.Join(source.repository, filepath.FromSlash(path))); err == nil {
			return source.read(path)
		}
	}
	source.problems = append(source.problems, fmt.Sprintf("none of %s exists", strings.Join(paths, ", ")))
	return ""
}

func (source *sources) differ(what string, stated any, found any) {
	source.problems = append(source.problems, fmt.Sprintf("%s: the manifest says %v, the sources say %v", what, stated, found))
}

func sorted(values []string) []string {
	copied := append([]string(nil), values...)
	sort.Strings(copied)
	return copied
}

func unique(values []string) []string {
	seen := map[string]bool{}
	var result []string
	for _, value := range values {
		if !seen[value] {
			seen[value] = true
			result = append(result, value)
		}
	}
	return sorted(result)
}

func (source *sources) sameSet(what string, stated []string, found []string) {
	if strings.Join(sorted(stated), ",") != strings.Join(unique(found), ",") {
		source.differ(what, sorted(stated), unique(found))
	}
	if len(unique(stated)) != len(stated) {
		source.problems = append(source.problems, what+": the manifest names an entry twice")
	}
}

func (source *sources) sameNumbers(what string, stated map[string]int, found map[string]int) {
	names := map[string]bool{}
	for name := range stated {
		names[name] = true
	}
	for name := range found {
		names[name] = true
	}
	var ordered []string
	for name := range names {
		ordered = append(ordered, name)
	}
	sort.Strings(ordered)
	for _, name := range ordered {
		statedValue, isStated := stated[name]
		foundValue, isFound := found[name]
		switch {
		case !isStated:
			source.problems = append(source.problems, fmt.Sprintf("%s: %s = %d is in the sources and not in the manifest", what, name, foundValue))
		case !isFound:
			source.problems = append(source.problems, fmt.Sprintf("%s: %s is in the manifest and not in the sources", what, name))
		case statedValue != foundValue:
			source.differ(what+" "+name, statedValue, foundValue)
		}
	}
}

var (
	declaredFunction = regexp.MustCompile(`(?m)^\s*(tala_[a-z0-9_]+)\(`)
	enumerator       = regexp.MustCompile(`(?m)^\s*(TALA_FRONTEND_[A-Z_]+) = (\d+),?$`)
	integerMacro     = regexp.MustCompile(`(?m)^#define (TALA_[A-Z_]+) (?:U?INT(?:32|64)_C)\((-?\d+)\)$`)
	definitionExport = regexp.MustCompile(`(?m)^\s+(tala_[a-z0-9_]+)\s*$`)
	quotedName       = regexp.MustCompile(`"([A-Za-z0-9_]+)"`)
	structField      = regexp.MustCompile(`(?m)^\s+[A-Za-z_][A-Za-z0-9_ ]*?[ \*]([A-Za-z][A-Za-z0-9]*);`)
)

func functions(text string) []string {
	var names []string
	for _, match := range declaredFunction.FindAllStringSubmatch(text, -1) {
		names = append(names, match[1])
	}
	return names
}

func numbers(pattern *regexp.Regexp, text string, keep func(string) bool) map[string]int {
	result := map[string]int{}
	for _, match := range pattern.FindAllStringSubmatch(text, -1) {
		if keep != nil && !keep(match[1]) {
			continue
		}
		value, _ := strconv.Atoi(match[2])
		result[match[1]] = value
	}
	return result
}

// number finds the one integer a pattern captures, or reports that it is
// not there.
func (source *sources) number(what string, text string, pattern string) int {
	match := regexp.MustCompile(pattern).FindStringSubmatch(text)
	if match == nil {
		source.problems = append(source.problems, what+" was not found in the sources")
		return -1
	}
	value, _ := strconv.Atoi(match[1])
	return value
}

// between returns the text from the first occurrence of start to the next
// occurrence of end.
func between(text string, start string, end string) string {
	from := strings.Index(text, start)
	if from < 0 {
		return ""
	}
	rest := text[from+len(start):]
	to := strings.Index(rest, end)
	if to < 0 {
		return ""
	}
	return rest[:to]
}

// magic reads a wire magic written as character literals: 'T', 'A', 'M', 'M'.
func magic(text string, after string) string {
	from := strings.Index(text, after)
	if from < 0 {
		return ""
	}
	rest := text[from:]
	if end := strings.Index(rest, "}"); end >= 0 {
		rest = rest[:end]
	}
	var letters strings.Builder
	for _, match := range regexp.MustCompile(`'([A-Z])'`).FindAllStringSubmatch(rest, -1) {
		letters.WriteString(match[1])
	}
	return letters.String()
}

// Verify compares the manifest with the sources of the repository and
// returns every difference it finds.
func Verify(repository string) ([]string, error) {
	manifest, err := Load(repository)
	if err != nil {
		return nil, err
	}
	source := &sources{repository: repository}
	if manifest.Schema != 1 {
		source.problems = append(source.problems, fmt.Sprintf("schema %d is not one this tool reads", manifest.Schema))
	}

	// The frontend library.
	frontend := manifest.FrontendLibrary
	header := source.read(frontend.Header)
	source.sameSet("frontend functions in "+frontend.Header, frontend.Symbols, functions(header))
	source.sameSet("frontend exports in tala-frontend.def", frontend.Symbols,
		func() []string {
			var names []string
			for _, match := range definitionExport.FindAllStringSubmatch(source.read("Talac/Haskell/Host/ffi/tala-frontend.def"), -1) {
				names = append(names, match[1])
			}
			return names
		}())
	kinds := between(header, "enum tala_frontend_output_kind", "};")
	statuses := between(header, "enum tala_frontend_status", "};")
	source.sameNumbers("frontend output kind", frontend.OutputKinds, numbers(enumerator, kinds, nil))
	source.sameNumbers("frontend status", frontend.Statuses, numbers(enumerator, statuses, nil))
	ffi := source.read("Talac/Haskell/Host/src/Progmasoft/Tala/Driver/FFI.hs")
	if found := source.number("the frontend ABI version", ffi, `(?m)^frontendAbiVersion = pure (\d+)$`); found != frontend.AbiVersion {
		source.differ("frontend ABI version", frontend.AbiVersion, found)
	}
	for _, platform := range []string{"windows", "macos", "linux"} {
		if frontend.Libraries[platform] == "" {
			source.problems = append(source.problems, "the frontend library has no name for "+platform)
		}
	}
	loader := source.read("Talac/Cli/Commands/Frontend.cpp")
	for platform, library := range frontend.Libraries {
		if !strings.Contains(loader, `"`+library+`"`) {
			source.problems = append(source.problems, fmt.Sprintf("the frontend library of %s, %s, is not what Talac/Cli/Commands/Frontend.cpp loads", platform, library))
		}
	}

	// The runtime.
	ownership := manifest.Runtime.Ownership
	aarc := source.read(ownership.Header)
	source.sameSet("ownership functions in "+ownership.Header, ownership.Symbols, functions(aarc))
	if found := source.number("TALA_AARC_ABI_VERSION", aarc, `(?m)^#define TALA_AARC_ABI_VERSION UINT32_C\((\d+)\)$`); found != ownership.AbiVersion {
		source.differ("ownership ABI version", ownership.AbiVersion, found)
	}
	var fields []string
	for _, match := range structField.FindAllStringSubmatch(between(aarc, "typedef struct TalaAarcTypeMetadata", "} TalaAarcTypeMetadata;"), -1) {
		fields = append(fields, match[1])
	}
	if strings.Join(fields, ",") != strings.Join(ownership.TypeMetadata, ",") {
		source.differ("the fields of TalaAarcTypeMetadata, in order", ownership.TypeMetadata, fields)
	}
	text := manifest.Runtime.Text
	textHeader := source.read(text.Header)
	source.sameSet("text functions in "+text.Header, text.Symbols, functions(textHeader))
	source.sameNumbers("text constant", text.Constants, numbers(integerMacro, textHeader, nil))
	// What a host of generated code exports is the same list.
	var exported []string
	for _, match := range quotedName.FindAllStringSubmatch(between(source.read("Talac/Runtime/host.bzl"), "_ENTRY_POINTS = [", "]"), -1) {
		exported = append(exported, match[1])
	}
	source.sameSet("runtime entry points in Talac/Runtime/host.bzl", append(append([]string(nil), ownership.Symbols...), text.Symbols...), exported)

	// The wire formats.
	type wire struct {
		version int
		magic   string
	}
	coreHeader := source.read("Talac/Headers/Progmasoft/Tala/Core/Wire.hpp")
	coreHaskell := source.read("Talac/Haskell/Core/src/Progmasoft/Tala/Core/Wire.hs")
	prepHeader := source.read("Talac/Headers/Progmasoft/Tala/Core/CorePrep/Wire/Format.hpp")
	prepHaskell := source.read("Talac/Haskell/Core/src/Progmasoft/Tala/Core/CorePrep/Wire/Format.hs")
	found := map[string][]wire{
		"Core": {
			{source.number("the native Core wire version", coreHeader, `kCurrentVersion = (\d+)`), between(coreHeader, "does not match ", ".")},
			{source.number("the frontend Core wire version", coreHaskell, `(?m)^currentCoreWireVersion = CoreWireVersion (\d+)$`), between(coreHaskell, `magic = map (fromIntegral . fromEnum) "`, `"`)},
		},
		"CorePrep": {
			{source.number("the native CorePrep wire version", prepHeader, `current_version = (\d+)`), magic(prepHeader, "magic[]")},
			{source.number("the frontend CorePrep wire version", prepHaskell, `(?m)^currentWireVersion = WireVersion (\d+)$`), between(prepHaskell, `wireMagic = map (fromIntegral . fromEnum) "`, `"`)},
		},
		"Xpp": {
			{source.number("the Xpp wire version", source.read("Talac/Headers/Progmasoft/Tala/Xpp/Wire.hpp"), `kCurrentVersion = (\d+)U?`), magic(source.read("Talac/Codegen/Xpp/Wire.cpp"), "kMagic{")},
		},
		"Xmm": {
			{source.number("the Xmm wire version", source.read("Talac/Headers/Progmasoft/Tala/Xmm/Wire.hpp"), `kCurrentVersion = (\d+)U?`), magic(source.read("Talac/Codegen/Xmm/Wire.cpp"), "kMagic{")},
		},
	}
	stated := map[string]bool{}
	for _, format := range manifest.WireFormats {
		stated[format.Name] = true
		definitions, known := found[format.Name]
		if !known {
			source.problems = append(source.problems, "wire format "+format.Name+" is in the manifest and this tool knows no source for it")
			continue
		}
		for _, definition := range definitions {
			if definition.version != format.Version {
				source.differ("version of the "+format.Name+" wire format", format.Version, definition.version)
			}
			if definition.magic != format.Magic {
				source.differ("magic of the "+format.Name+" wire format", format.Magic, definition.magic)
			}
		}
	}
	for name := range found {
		if !stated[name] {
			source.problems = append(source.problems, "wire format "+name+" is not in the manifest")
		}
	}

	// The executable.
	executable := manifest.Executable
	generator := source.readAny("Talac/Backend/LLVM/Generator.cpp", "Talac/Backend/LLVM/Codegen.cpp")
	entry := regexp.MustCompile(`triple\.isOSWindows\(\) \? "([A-Za-z_]+)" : "([A-Za-z_]+)"`).FindStringSubmatch(generator)
	if entry == nil {
		source.problems = append(source.problems, "the entry symbols were not found in the LLVM generator")
	} else {
		for platform, symbol := range executable.EntrySymbols {
			want := entry[2]
			if platform == "windows" {
				want = entry[1]
			}
			if symbol != want {
				source.differ("entry symbol on "+platform, symbol, want)
			}
		}
	}
	// The plan of a link names the programs and libraries; the linker
	// that runs it lists the system imports of Windows.
	linker := source.read("Talac/Linker/NativeLinker.cpp") + "\n" + source.read("Talac/Linker/LinkPlan.cpp")
	// An executable takes the extension the host gives its programs: the one
	// the command line names for Windows, and none elsewhere.
	options := source.read("Talac/Cli/Arguments/Options.cpp")
	extension := regexp.MustCompile(`(?s)#if defined\(_WIN32\)\s+constexpr const char \*kExecutable = "([^"]*)";\s+#else\s+constexpr const char \*kExecutable = "([^"]*)";`).FindStringSubmatch(options)
	if extension == nil {
		source.problems = append(source.problems, "the executable extensions were not found in the command line")
	} else {
		for _, platform := range []string{"windows", "linux", "macos"} {
			want := extension[2]
			if platform == "windows" {
				want = extension[1]
			}
			written, present := executable.Extensions[platform]
			if !present || written != want {
				source.differ("executable extension on "+platform, written, want)
			}
		}
	}
	for _, platform := range []string{"windows", "linux", "macos"} {
		if executable.EntrySymbols[platform] == "" || executable.ObjectFormats[platform] == "" {
			source.problems = append(source.problems, "the executable has no entry symbol or object format for "+platform)
		}
	}
	if windows, linked := executable.NativeLinking["windows"]; linked {
		if !strings.Contains(linker, `kWindowsLinker = "`+windows.Linker+`"`) {
			source.problems = append(source.problems, "the Windows linker "+windows.Linker+" is not what the native linker starts")
		}
		if !strings.Contains(linker, `kWindowsRuntimeLibrary = "`+windows.RuntimeLibrary+`"`) {
			source.problems = append(source.problems, "the Windows runtime library "+windows.RuntimeLibrary+" is not what the native linker looks for")
		}
		if !strings.Contains(linker, `kWindowsSharedRuntime = "`+windows.SharedRuntimeLibrary+`"`) {
			source.problems = append(source.problems, "the Windows shared runtime library "+windows.SharedRuntimeLibrary+" is not what the native linker looks for")
		}
		// What an executable imports from the shared library is the C ABI
		// of the runtime and the memory functions generated code calls; the
		// DLL exports the same.
		runtimeImports := between(linker, "std::string_view kRuntimeImports", ";")
		if !strings.Contains(runtimeImports, "LIBRARY "+windows.SharedRuntimeLibrary+`\n`) {
			source.problems = append(source.problems, "the import library of the shared runtime does not name "+windows.SharedRuntimeLibrary)
		}
		var imported []string
		for _, match := range regexp.MustCompile(`"\s+([A-Za-z0-9_]+)\\n"`).FindAllStringSubmatch(runtimeImports, -1) {
			imported = append(imported, match[1])
		}
		wanted := append(append(append([]string(nil), ownership.Symbols...), text.Symbols...), "memcpy", "memmove", "memset")
		source.sameSet("functions imported from "+windows.SharedRuntimeLibrary, wanted, imported)
		imports := between(linker, "kSystemImports = ", ";")
		library := regexp.MustCompile(`LIBRARY ([A-Za-z0-9_.]+)`).FindStringSubmatch(imports)
		var names []string
		for _, match := range regexp.MustCompile(`"\s+([A-Za-z0-9_]+)\\n"`).FindAllStringSubmatch(imports, -1) {
			names = append(names, match[1])
		}
		if library == nil || len(windows.SystemImports) != 1 {
			source.problems = append(source.problems, "the Windows system imports name one library in the sources; the manifest must name that one")
		} else {
			source.sameSet("functions imported from "+library[1], windows.SystemImports[library[1]], names)
		}
	} else {
		source.problems = append(source.problems, "the manifest does not say how an executable is linked on Windows")
	}
	// Linux and macOS share one branch of the linker: the C compiler of the
	// system as the driver, and one name for the runtime library.
	driver := regexp.MustCompile(`kLinkerDriver = "([A-Za-z0-9_+-]+)"`).FindStringSubmatch(linker)
	shared := map[string]string{"linux": "kElfSharedRuntime", "macos": "kMachOSharedRuntime"}
	library := regexp.MustCompile(`kRuntimeLibraryName = "([A-Za-z0-9_.+-]+)"`).FindStringSubmatch(linker)
	for _, platform := range []string{"linux", "macos"} {
		stated, linked := executable.NativeLinking[platform]
		switch {
		case !linked:
			source.problems = append(source.problems, "the manifest does not say how an executable is linked on "+platform)
		case driver == nil || library == nil:
			source.problems = append(source.problems, "the linker driver or the runtime library of "+platform+" was not found in the native linker")
		default:
			if stated.Linker != driver[1] {
				source.differ("linker on "+platform, stated.Linker, driver[1])
			}
			if stated.RuntimeLibrary != library[1] {
				source.differ("runtime library on "+platform, stated.RuntimeLibrary, library[1])
			}
			if !strings.Contains(linker, shared[platform]+` = "`+stated.SharedRuntimeLibrary+`"`) {
				source.problems = append(source.problems, "the shared runtime library "+stated.SharedRuntimeLibrary+" on "+platform+" is not what the native linker looks for")
			}
			if len(stated.SystemImports) != 0 {
				source.problems = append(source.problems, "system imports are stated for "+platform+", where the C library is linked whole and none are listed")
			}
		}
	}
	for platform := range executable.NativeLinking {
		if platform != "windows" && platform != "linux" && platform != "macos" {
			source.problems = append(source.problems, "native linking is stated for "+platform+", which this tool knows no source for")
		}
	}
	return source.problems, nil
}
