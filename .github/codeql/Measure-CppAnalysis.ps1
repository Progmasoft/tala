# SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
# SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

<#
.SYNOPSIS
Measures what a CodeQL C++ database holds and how well it was understood.

.DESCRIPTION
Two questions are answered. How many of the native sources the repository
owns reached the database, and how much of what reached it the extractor
could compile: a source that is in the database with its includes unresolved
is analysed in name only.

The figures are written to the job summary and to the log. The step fails
when a figure is below its floor; a floor of zero is not enforced.
#>
param(
    [Parameter(Mandatory)] [string] $Database,
    [Parameter(Mandatory)] [string] $Codeql,
    [double] $SourceFloor = 95.0,
    [double] $IncludeFloor = 0.0,
    [double] $CompilationFloor = 0.0
)

$ErrorActionPreference = 'Stop'
$summary = $env:GITHUB_STEP_SUMMARY
if (-not $summary) { $summary = Join-Path ([System.IO.Path]::GetTempPath()) 'cpp-analysis-summary.md' }

# The native sources the repository owns.
$owned = @(git ls-files -- 'Talac/*.cpp' 'Talac/*.hpp' 'Talac/*.h' 'Talac/*.inc' `
        'Interactive/*.cpp' 'Interactive/*.hpp' 'Interactive/*.h' |
        Where-Object { $_ -notlike 'Talac/Haskell/*' })
if ($owned.Count -eq 0) { throw 'no native sources were found to compare with' }

# The sources the database holds: every file the extractor read is kept in
# its source archive.
$archive = Join-Path $Database 'src.zip'
if (-not (Test-Path -LiteralPath $archive)) { throw "the CodeQL database has no source archive at $archive" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
try { $held = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }) } finally { $zip.Dispose() }
$heldSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $held) {
    # An entry is an absolute path of the runner; every suffix that starts
    # at a directory is a path the repository could own.
    $parts = $entry.Split('/')
    for ($index = 0; $index -lt $parts.Count; $index++) {
        [void] $heldSet.Add(($parts[$index..($parts.Count - 1)] -join '/'))
    }
}

$missing = @($owned | Where-Object { -not $heldSet.Contains($_) })
$seen = $owned.Count - $missing.Count
$share = [math]::Round(100.0 * $seen / $owned.Count, 1)

"## C++ analysis coverage" >> $summary
"" >> $summary
"| Measure | Value | Floor |" >> $summary
"| --- | --- | --- |" >> $summary
"| Native sources in the repository | $($owned.Count) | |" >> $summary
"| Of them in the CodeQL database | $seen ($share %) | $SourceFloor % |" >> $summary

# What the extractor reports about itself. Each result set is one query of
# the CodeQL C++ pack; the names are the pack's.
$results = Join-Path $Database 'results'
$reports = @()
if (Test-Path -LiteralPath $results) {
    $reports = @(Get-ChildItem -LiteralPath $results -Recurse -Filter *.bqrs |
            Where-Object { $_.FullName -match '[\\/](Summary|Telemetry|Diagnostics)[\\/]' } | Sort-Object FullName)
}

# The quality report gives each figure as a row of a name and a percentage.
$quality = @{}
$decoded = @{}
foreach ($report in $reports) {
    $rows = @(& $Codeql bqrs decode --format=csv --rows=40 -- $report.FullName 2>$null)
    if ($LASTEXITCODE -ne 0 -or $rows.Count -eq 0) { continue }
    $decoded[$report.FullName] = $rows
    if ($report.BaseName -eq 'DatabaseQuality') {
        foreach ($row in $rows) {
            if ($row -match '^"(?<name>[^"]+)",(?<value>[0-9.]+)$') {
                $quality[$Matches['name']] = [double]::Parse($Matches['value'], [cultureinfo]::InvariantCulture)
            }
        }
    }
}

$includeName = 'Percentage of successfully resolved #include directives'
$compilationName = 'Percentage of compilations without errors'
$includes = if ($quality.ContainsKey($includeName)) { [math]::Round($quality[$includeName], 1) } else { $null }
$compilations = if ($quality.ContainsKey($compilationName)) { [math]::Round($quality[$compilationName], 1) } else { $null }
$shown = { param($value) if ($null -eq $value) { 'not reported' } else { "$value %" } }
$floorShown = { param($floor) if ($floor -gt 0) { "$floor %" } else { 'none' } }
"| Resolved ``#include`` directives | $(& $shown $includes) | $(& $floorShown $IncludeFloor) |" >> $summary
"| Compilations without errors | $(& $shown $compilations) | $(& $floorShown $CompilationFloor) |" >> $summary

if ($missing.Count -gt 0) {
    "" >> $summary
    "Not in the database:" >> $summary
    "" >> $summary
    $missing | Select-Object -First 50 | ForEach-Object { "- ``$_``" >> $summary }
}

foreach ($report in $reports) {
    if (-not $decoded.ContainsKey($report.FullName)) { continue }
    "" >> $summary
    "### $($report.Directory.Name) / $($report.BaseName)" >> $summary
    "" >> $summary
    '```text' >> $summary
    $decoded[$report.FullName] | ForEach-Object { $_ >> $summary }
    '```' >> $summary
}
if ($reports.Count -eq 0) {
    "" >> $summary
    "The database holds no summary or telemetry results to show." >> $summary
}

# The job summary is only shown on the page of the run. The log gets the
# same text, so that the figures can be read from it as well.
Get-Content -LiteralPath $summary | ForEach-Object { Write-Host $_ }
Write-Host "C++ analysis: $seen of $($owned.Count) native sources are in the database ($share %)."

$failures = @()
if ($share -lt $SourceFloor) {
    $failures += "CodeQL holds $share % of the native sources; the floor is $SourceFloor %."
}
foreach ($check in @(
        @{ Name = 'resolved #include directives'; Value = $includes; Floor = $IncludeFloor },
        @{ Name = 'compilations without errors'; Value = $compilations; Floor = $CompilationFloor })) {
    if ($check.Floor -le 0) { continue }
    if ($null -eq $check.Value) {
        $failures += "The database does not report its $($check.Name); the floor is $($check.Floor) %."
    }
    elseif ($check.Value -lt $check.Floor) {
        $failures += "The $($check.Name) are $($check.Value) %; the floor is $($check.Floor) %."
    }
}
if ($failures.Count -gt 0) { throw ($failures -join ' ') }
