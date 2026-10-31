// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package development

import (
	"encoding/json"
	"sort"
)

// The SARIF this file writes is the part of the format code scanning reads:
// one run of one tool, its rules, and for each result a place, a message and
// the steps of the path as a code flow.

type sarifText struct {
	Text string `json:"text"`
}

type sarifRegion struct {
	StartLine   int `json:"startLine"`
	StartColumn int `json:"startColumn,omitempty"`
}

type sarifArtifact struct {
	URI       string `json:"uri"`
	URIBaseID string `json:"uriBaseId"`
}

type sarifPhysical struct {
	ArtifactLocation sarifArtifact `json:"artifactLocation"`
	Region           sarifRegion   `json:"region"`
}

type sarifLocation struct {
	PhysicalLocation sarifPhysical `json:"physicalLocation"`
	Message          *sarifText    `json:"message,omitempty"`
}

type sarifThreadLocation struct {
	Location sarifLocation `json:"location"`
}

type sarifThreadFlow struct {
	Locations []sarifThreadLocation `json:"locations"`
}

type sarifCodeFlow struct {
	ThreadFlows []sarifThreadFlow `json:"threadFlows"`
}

type sarifResult struct {
	RuleID    string          `json:"ruleId"`
	Level     string          `json:"level"`
	Message   sarifText       `json:"message"`
	Locations []sarifLocation `json:"locations"`
	CodeFlows []sarifCodeFlow `json:"codeFlows,omitempty"`
}

type sarifConfiguration struct {
	Level string `json:"level"`
}

type sarifRule struct {
	ID                   string             `json:"id"`
	Name                 string             `json:"name"`
	ShortDescription     sarifText          `json:"shortDescription"`
	HelpURI              string             `json:"helpUri"`
	DefaultConfiguration sarifConfiguration `json:"defaultConfiguration"`
	Properties           map[string]any     `json:"properties"`
}

type sarifDriver struct {
	Name           string      `json:"name"`
	Version        string      `json:"version,omitempty"`
	InformationURI string      `json:"informationUri"`
	Rules          []sarifRule `json:"rules"`
}

type sarifTool struct {
	Driver sarifDriver `json:"driver"`
}

type sarifRun struct {
	Tool    sarifTool     `json:"tool"`
	Results []sarifResult `json:"results"`
}

type sarifDocument struct {
	Schema  string     `json:"$schema"`
	Version string     `json:"version"`
	Runs    []sarifRun `json:"runs"`
}

// analyzerLevel is how a finding is shown: one of a stable checker as a
// warning, one of a checker in development as a note.
func analyzerLevel(advisory bool) string {
	if advisory {
		return "note"
	}
	return "warning"
}

func sarifPlace(file string, line int, column int) sarifPhysical {
	if line < 1 {
		line = 1
	}
	return sarifPhysical{
		ArtifactLocation: sarifArtifact{URI: file, URIBaseID: "%SRCROOT%"},
		Region:           sarifRegion{StartLine: line, StartColumn: column},
	}
}

// analyzerSarif writes findings as one SARIF run. The document is the same
// for the same findings, whatever order they were found in.
func analyzerSarif(findings []analyzerFinding, version string) ([]byte, error) {
	rules := map[string]sarifRule{}
	results := make([]sarifResult, 0, len(findings))
	for _, finding := range uniqueFindings(findings) {
		level := analyzerLevel(finding.advisory())
		if _, known := rules[finding.Checker]; !known {
			precision := "high"
			if finding.advisory() {
				precision = "low"
			}
			rules[finding.Checker] = sarifRule{
				ID:                   finding.Checker,
				Name:                 finding.Checker,
				ShortDescription:     sarifText{Text: "Clang Static Analyzer checker " + finding.Checker},
				HelpURI:              "https://clang.llvm.org/docs/analyzer/checkers.html",
				DefaultConfiguration: sarifConfiguration{Level: level},
				Properties:           map[string]any{"precision": precision, "tags": []string{"clang-static-analyzer"}},
			}
		}
		result := sarifResult{
			RuleID:    finding.Checker,
			Level:     level,
			Message:   sarifText{Text: finding.Message},
			Locations: []sarifLocation{{PhysicalLocation: sarifPlace(finding.File, finding.Line, finding.Column)}},
		}
		if len(finding.Steps) != 0 {
			var flow sarifThreadFlow
			for _, step := range finding.Steps {
				flow.Locations = append(flow.Locations, sarifThreadLocation{Location: sarifLocation{
					PhysicalLocation: sarifPlace(step.File, step.Line, step.Column),
					Message:          &sarifText{Text: step.Message},
				}})
			}
			result.CodeFlows = []sarifCodeFlow{{ThreadFlows: []sarifThreadFlow{flow}}}
		}
		results = append(results, result)
	}
	ordered := make([]sarifRule, 0, len(rules))
	for _, rule := range rules {
		ordered = append(ordered, rule)
	}
	sort.Slice(ordered, func(left, right int) bool { return ordered[left].ID < ordered[right].ID })
	document := sarifDocument{
		Schema:  "https://json.schemastore.org/sarif-2.1.0.json",
		Version: "2.1.0",
		Runs: []sarifRun{{
			Tool: sarifTool{Driver: sarifDriver{
				Name:           "Clang Static Analyzer",
				Version:        version,
				InformationURI: "https://clang.llvm.org/docs/ClangStaticAnalyzer.html",
				Rules:          ordered,
			}},
			Results: results,
		}},
	}
	return json.MarshalIndent(document, "", "  ")
}
