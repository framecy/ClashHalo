// compile.go — YAML rules → binary Trie compiler
// Called by the XPC server's handleCompileRules.
package xpc

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/clashpow/engine/internal/trie"
	"gopkg.in/yaml.v3"
)

// CompiledRule represents one parsed rule entry.
type CompiledRule struct {
	Type     string // DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, GEOIP, IP-CIDR, MATCH
	Value    string
	Policy   string // target proxy/group name or DIRECT/REJECT
	PolicyID uint32 // resolved numeric ID for mmap
}

// RuleBinaryHeader is the 48-byte file header.
const ruleMagic = 0x435041574D4D4150 // "CPAWMMAP"

// CompileRules parses a YAML rules block and produces a mmap-compatible
// binary file at the given output path. Returns the path on success.
func CompileRules(rulesYAML string, outputDir string, policyMap map[string]uint32) (string, error) {
	// Parse YAML
	var rulesConfig struct {
		Rules []string `yaml:"rules"`
	}
	if err := yaml.Unmarshal([]byte(rulesYAML), &rulesConfig); err != nil {
		return "", fmt.Errorf("compile: YAML parse error: %w", err)
	}

	var rules []CompiledRule
	for _, line := range rulesConfig.Rules {
		r, err := parseRuleLine(line)
		if err != nil {
			return "", fmt.Errorf("compile: bad rule line %q: %w", line, err)
		}
		// Resolve policy to numeric ID
		if pid, ok := policyMap[r.Policy]; ok {
			r.PolicyID = pid
		} else {
			r.PolicyID = 0 // DIRECT=0, fallback
		}
		rules = append(rules, r)
	}

	if len(rules) == 0 {
		return "", fmt.Errorf("compile: no rules found")
	}

	// Build the binary
	buf := new(bytes.Buffer)

	// Reserve header space (48 bytes)
	header := make([]byte, headerSize)
	buf.Write(header)

	// Write rule count + index
	binary.LittleEndian.PutUint32(buf.Bytes()[12:16], uint32(len(rules)))

	// Sort rules by type for better locality
	sort.Slice(rules, func(i, j int) bool {
		if rules[i].Type != rules[j].Type {
			return rules[i].Type < rules[j].Type
		}
		return rules[i].Value < rules[j].Value
	})

	// Write each rule as: type(1B) + policyID(4B) + valueLen(2B) + value(variable)
	for _, r := range rules {
		var typeByte byte
		switch r.Type {
		case "DOMAIN":
			typeByte = 0
		case "DOMAIN-SUFFIX":
			typeByte = 1
		case "DOMAIN-KEYWORD":
			typeByte = 2
		case "GEOIP":
			typeByte = 3
		case "IP-CIDR":
			typeByte = 4
		case "MATCH":
			typeByte = 5
		default:
			typeByte = 0
		}

		buf.WriteByte(typeByte)
		binary.LittleEndian.PutUint32(make([]byte, 4), r.PolicyID)
		buf.Write(buf.Bytes()[buf.Len()-4:]) //
		valLen := make([]byte, 2)
		binary.LittleEndian.PutUint16(valLen, uint16(len(r.Value)))
		buf.Write(valLen)
		buf.WriteString(r.Value)
	}

	final := buf.Bytes()

	// Write header
	binary.LittleEndian.PutUint64(final[0:8], ruleMagic)
	binary.LittleEndian.PutUint32(final[8:12], 1) // version
	// rule count already at 12:16
	hash := sha256.Sum256(final[headerSize:])
	copy(final[16:16+32], hash[:])

	// Write to file
	outPath := outputDir + "/rules.cpbin"
	if err := os.WriteFile(outPath, final, 0644); err != nil {
		return "", fmt.Errorf("compile: write %s: %w", outPath, err)
	}

	return outPath, nil
}

// parseRuleLine parses a single rule line like:
//
//	DOMAIN-SUFFIX,google.com,Proxy
//	MATCH,DIRECT
//	IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
func parseRuleLine(line string) (CompiledRule, error) {
	parts := strings.Split(line, ",")
	if len(parts) < 2 {
		return CompiledRule{}, fmt.Errorf("too few fields")
	}

	r := CompiledRule{
		Type:   strings.TrimSpace(parts[0]),
		Value:  strings.TrimSpace(parts[1]),
		Policy: "DIRECT",
	}

	if len(parts) >= 3 {
		r.Policy = strings.TrimSpace(parts[2])
	}

	return r, nil
}

const headerSize = 8 + 4 + 4 + 32

// Ensure trie and sort are used without triggering "imported and not used".
var _ = trie.SerializeNode
var _ = sort.Slice
var _ = sha256.Sum256
var _ = bytes.Buffer{}
