// Package trie implements a compact binary Trie for IP/CIDR and domain
// rule matching. Nodes use relative offsets instead of pointers so the
// entire structure can be mmap'd without fixup.
package trie

import (
	"encoding/binary"
)

// Node types for the binary trie.
const (
	NodeTypeExact  = 0 // exact match terminal
	NodeTypePrefix = 1 // prefix match terminal
	NodeTypeSuffix = 2 // suffix match terminal
	NodeTypeBranch = 3 // internal branch node
)

// Node represents a single node in the serialized trie.
type Node struct {
	Type     uint8  // node type
	Child0   uint32 // relative offset to left child (0 if none)
	Child1   uint32 // relative offset to right child (0 if none)
	PolicyID uint32 // policy/outbound ID for terminal nodes
}

const nodeSize = 1 + 4 + 4 + 4 // 13 bytes, padded to 16 for alignment

// SerializeNode writes a node into a byte slice at the given offset.
func SerializeNode(buf []byte, offset int, n Node) {
	buf[offset] = n.Type
	binary.LittleEndian.PutUint32(buf[offset+4:], n.Child0)
	binary.LittleEndian.PutUint32(buf[offset+8:], n.Child1)
	binary.LittleEndian.PutUint32(buf[offset+12:], n.PolicyID)
}

// DeserializeNode reads a node from a byte slice at the given offset.
func DeserializeNode(buf []byte, offset int) Node {
	if offset+16 > len(buf) {
		return Node{}
	}
	return Node{
		Type:     buf[offset],
		Child0:   binary.LittleEndian.Uint32(buf[offset+4:]),
		Child1:   binary.LittleEndian.Uint32(buf[offset+8:]),
		PolicyID: binary.LittleEndian.Uint32(buf[offset+12:]),
	}
}

// AlignedNodeSize returns the aligned size of a serialized node.
func AlignedNodeSize() int {
	return 16 // 13 rounded up to alignment
}
