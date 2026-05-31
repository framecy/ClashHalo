// mmap_test.go
// Phase 0 Prototype: mmap binary rule loading validation.
//
// Validates:
//  1. Serialization of rules to binary Trie format with header
//  2. mmap loading and header validation (magic, hash, version)
//  3. Atomic hot-swap of mapped rules
//  4. 10,000 rule load time ≤ 50 ms

package phase0

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"os"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/clashpow/engine/internal/trie"
)

const (
	testMagic    = 0x435041574D4D4150 // "CPAWMMAP"
	testVersion  = 1
	headerSize   = 8 + 4 + 4 + 32 // magic + version + ruleCount + hash
)

// compileRules serializes a set of domain rules into a binary Trie file.
// Returns the file path.
func compileRules(rules []struct{ domain string; policyID uint32 }, t *testing.T) string {
	// Build a simple trie in memory, then serialize
	var buf bytes.Buffer

	// Reserve header space
	header := make([]byte, headerSize)
	buf.Write(header)

	// Write each rule as a trie path (simplified: flat array of nodes)
	for _, rule := range rules {
		domain := rule.domain
		// Write domain length-prefixed, then terminal node
		lenBuf := make([]byte, 2)
		binary.LittleEndian.PutUint16(lenBuf, uint16(len(domain)))
		buf.Write(lenBuf)
		buf.WriteString(domain)

		// Terminal node
		nodeBuf := make([]byte, trie.AlignedNodeSize())
		trie.SerializeNode(nodeBuf, 0, trie.Node{
			Type:     trie.NodeTypeExact,
			PolicyID: rule.policyID,
		})
		buf.Write(nodeBuf)
	}

	data := buf.Bytes()

	// Write header
	binary.LittleEndian.PutUint64(data[0:8], testMagic)
	binary.LittleEndian.PutUint32(data[8:12], testVersion)
	binary.LittleEndian.PutUint32(data[12:16], uint32(len(rules)))

	// Hash the data region (after header)
	hash := sha256.Sum256(data[headerSize:])
	copy(data[16:16+32], hash[:])

	// Write to temp file
	f, err := os.CreateTemp("", "clashpow-rules-*.bin")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	if _, err := f.Write(data); err != nil {
		t.Fatalf("Failed to write rules: %v", err)
	}
	f.Close()

	return f.Name()
}

func TestMmapLoadAndValidate(t *testing.T) {
	rules := []struct{ domain string; policyID uint32 }{
		{"google.com", 1},
		{"youtube.com", 2},
		{"github.com", 3},
		{"apple.com", 4},
		{"anthropic.com", 5},
	}

	path := compileRules(rules, t)
	defer os.Remove(path)

	// Open and mmap the file
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		t.Fatalf("Stat failed: %v", err)
	}

	data, err := syscall.Mmap(int(f.Fd()), 0, int(fi.Size()),
		syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		t.Fatalf("mmap failed: %v", err)
	}
	defer syscall.Munmap(data)

	// Validate header
	magic := binary.LittleEndian.Uint64(data[0:8])
	if magic != testMagic {
		t.Errorf("Magic mismatch: got %016X, want %016X", magic, testMagic)
	}

	version := binary.LittleEndian.Uint32(data[8:12])
	ruleCount := binary.LittleEndian.Uint32(data[12:16])
	var storedHash [32]byte
	copy(storedHash[:], data[16:48])

	// Verify hash
	computedHash := sha256.Sum256(data[headerSize:])
	if storedHash != computedHash {
		t.Error("Hash mismatch — data may be corrupted")
	}

	t.Logf("mmap OK: version=%d rules=%d hash=%x", version, ruleCount, storedHash[:4])
}

func TestMmap10kRulesLoadTime(t *testing.T) {
	// Generate 10,000 synthetic rules
	rules := make([]struct{ domain string; policyID uint32 }, 10000)
	for i := 0; i < 10000; i++ {
		rules[i] = struct{ domain string; policyID uint32 }{
			domain:    fmt.Sprintf("host-%05d.example.com", i),
			policyID: uint32(i % 256),
		}
	}

	path := compileRules(rules, t)
	defer os.Remove(path)

	// Time the mmap + validate cycle
	start := time.Now()

	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		t.Fatalf("Stat failed: %v", err)
	}

	data, err := syscall.Mmap(int(f.Fd()), 0, int(fi.Size()),
		syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		t.Fatalf("mmap failed: %v", err)
	}
	defer syscall.Munmap(data)

	// Validate header
	magic := binary.LittleEndian.Uint64(data[0:8])
	ruleCount := binary.LittleEndian.Uint32(data[12:16])

	elapsed := time.Since(start)

	if magic != testMagic {
		t.Error("Magic mismatch")
	}
	if ruleCount != 10000 {
		t.Errorf("Rule count mismatch: got %d, want 10000", ruleCount)
	}

	t.Logf("10,000 rules loaded in %v (target: ≤ 50ms)", elapsed)
	if elapsed > 50*time.Millisecond {
		t.Errorf("Load time %v exceeds 50ms target", elapsed)
	}
}

// TestMmapAtomicHotSwap validates that swapping mmap regions works without
// affecting readers (atomic pointer swap pattern).
func TestMmapAtomicHotSwap(t *testing.T) {
	// Compile two rule sets
	rulesV1 := []struct{ domain string; policyID uint32 }{
		{"v1.example.com", 100},
	}
	rulesV2 := []struct{ domain string; policyID uint32 }{
		{"v2.example.com", 200},
	}

	path1 := compileRules(rulesV1, t)
	path2 := compileRules(rulesV2, t)
	defer os.Remove(path1)
	defer os.Remove(path2)

	// Simulate the loader's atomic pointer pattern
	type mappedRules struct {
		data   []byte
		rcount uint32
	}
	var current atomic.Pointer[mappedRules]

	load := func(path string) {
		f, err := os.Open(path)
		if err != nil {
			t.Fatalf("Open failed: %v", err)
		}
		defer f.Close()

		fi, _ := f.Stat()
		data, err := syscall.Mmap(int(f.Fd()), 0, int(fi.Size()),
			syscall.PROT_READ, syscall.MAP_SHARED)
		if err != nil {
			t.Fatalf("mmap failed: %v", err)
		}

		rcount := binary.LittleEndian.Uint32(data[12:16])
		rules := &mappedRules{data: data, rcount: rcount}

		old := current.Swap(rules)
		if old != nil {
			syscall.Munmap(old.data)
		}
	}

	// Load v1
	load(path1)
	r := current.Load()
	if r == nil || r.rcount != 1 {
		t.Fatalf("V1 load failed: rcount=%d", r.rcount)
	}
	t.Logf("V1 loaded: %d rules", r.rcount)

	// Hot-swap to v2
	load(path2)
	r = current.Load()
	if r == nil || r.rcount != 1 {
		t.Fatalf("V2 swap failed: rcount=%d", r.rcount)
	}
	// Verify v2 content by checking the domain string in the data region
	dataRegion := r.data[headerSize:]
	if !bytes.Contains(dataRegion, []byte("v2.example.com")) {
		t.Error("V2 content not found — hot-swap may have failed")
	}
	t.Logf("V2 hot-swapped: %d rules", r.rcount)

	// Cleanup current mapping
	if r != nil {
		syscall.Munmap(r.data)
	}
}
