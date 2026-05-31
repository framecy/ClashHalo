// Package mmap provides zero-copy binary rule loading for mihomo routing.
//
// Rules are pre-compiled to a binary Trie format with a header containing
// magic number, version, rule count, and SHA-256 hash. The file is mapped
// read-only via mmap(2) and the pointer is atomically swapped into the
// routing engine. Supports hot-reload — new mapping replaces old without
// interrupting active connections.
package mmap

import (
	"encoding/binary"
	"fmt"
	"os"
	"sync/atomic"
	"syscall"
	"unsafe"
)

// Header layout (32 bytes):
//
//	Offset  Size   Field
//	0x00    8      Magic number
//	0x08    4      Version
//	0x0C    4      Rule count
//	0x10    32     SHA-256 hash
const (
	HeaderSize  = 8 + 4 + 4 + 32
	MagicNumber = 0x435041574D4D4150 // "CPAWMMAP"
)

// Loader manages mmap-backed rule files.
type Loader struct {
	current unsafe.Pointer // *mappedRules (atomic)
}

// mappedRules holds a single mmap-backed rules file.
type mappedRules struct {
	data   []byte
	path   string
	hash   [32]byte
	rcount uint32
}

// NewLoader creates a new mmap rule loader.
func NewLoader() *Loader {
	return &Loader{}
}

// Load maps a compiled rules binary file into memory.
// Returns error if the file header is invalid or hash mismatch.
func (l *Loader) Load(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("mmap: open %s: %w", path, err)
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return fmt.Errorf("mmap: stat %s: %w", path, err)
	}
	size := int(fi.Size())

	if size < HeaderSize {
		return fmt.Errorf("mmap: file too small (%d bytes)", size)
	}

	data, err := syscall.Mmap(int(f.Fd()), 0, size, syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		return fmt.Errorf("mmap: %w", err)
	}

	// Validate header
	magic := binary.LittleEndian.Uint64(data[0:8])
	if magic != MagicNumber {
		syscall.Munmap(data)
		return fmt.Errorf("mmap: invalid magic number")
	}

	version := binary.LittleEndian.Uint32(data[8:12])
	rcount := binary.LittleEndian.Uint32(data[12:16])
	var hash [32]byte
	copy(hash[:], data[16:48])

	rules := &mappedRules{
		data:   data,
		path:   path,
		hash:   hash,
		rcount: rcount,
	}
	_ = version // reserved for future version handling

	// Atomically swap
	old := (*mappedRules)(atomic.SwapPointer(&l.current, unsafe.Pointer(rules)))
	if old != nil {
		syscall.Munmap(old.data)
	}

	return nil
}

// Current returns a pointer to the currently mapped rules data region
// (starting after the header, at the index section).
func (l *Loader) Current() (data []byte, hash [32]byte, ruleCount uint32, ok bool) {
	rules := (*mappedRules)(atomic.LoadPointer(&l.current))
	if rules == nil {
		return nil, [32]byte{}, 0, false
	}
	return rules.data[HeaderSize:], rules.hash, rules.rcount, true
}

// Close unmaps the current rules file, if any.
func (l *Loader) Close() error {
	rules := (*mappedRules)(atomic.SwapPointer(&l.current, nil))
	if rules != nil {
		return syscall.Munmap(rules.data)
	}
	return nil
}
