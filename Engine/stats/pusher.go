// Package stats writes high-resolution (10ms) traffic statistics to a
// memory-mapped shared file. The GUI mmaps the same file read-only and
// samples it lock-free for a smooth 120fps Metal chart.
//
// Why a file (not IOSurface): the engine is a Go process; sharing an
// IOSurface to the Swift GUI requires passing its mach-port send-right,
// which a UDS cannot carry (UDS SCM_RIGHTS passes fds, not mach ports) and
// which Go cannot mint without heavy CGo/Mach plumbing. A POSIX mmap'd file
// is a genuine zero-copy shared region, trivially cross-process, and the
// payload here is a few KB — so it is the correct, robust equivalent.
//
// File layout (little-endian):
//
//	0x00  uint32  writePtr   (atomic, monotonically incrementing)
//	0x04  uint32  slotCount
//	0x08  uint32  slotSize
//	0x0C  uint32  reserved
//	0x10  ...     ring of `slotCount` slots, each `slotSize` bytes:
//	              int64 tsUnixNano | int64 upRateBps | int64 downRateBps |
//	              int64 upTotal    | int64 downTotal | int32 conns | int32 _ | int64 memBytes
package stats

import (
	"encoding/binary"
	"os"
	"sync/atomic"
	"syscall"
	"unsafe"
)

const (
	StatsFilePath = "/tmp/clashpow-stats.bin"
	headerSize    = 16
	slotSize      = 56 // 6×int64 + 2×int32
	slotCount     = 2048
	fileSize      = headerSize + slotSize*slotCount
)

// Pusher owns the mmap'd shared stats file.
type Pusher struct {
	data   []byte
	file   *os.File
	closed atomic.Bool
}

// NewPusher creates/truncates the shared stats file and mmaps it RW.
func NewPusher() *Pusher {
	f, err := os.OpenFile(StatsFilePath, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o666)
	if err != nil {
		return &Pusher{} // degraded: Push becomes a no-op
	}
	os.Chmod(StatsFilePath, 0666)
	if err := f.Truncate(int64(fileSize)); err != nil {
		f.Close()
		return &Pusher{}
	}
	data, err := syscall.Mmap(int(f.Fd()), 0, fileSize, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		f.Close()
		return &Pusher{}
	}
	binary.LittleEndian.PutUint32(data[4:], slotCount)
	binary.LittleEndian.PutUint32(data[8:], slotSize)
	return &Pusher{data: data, file: f}
}

// Sample is one high-resolution stats point.
type Sample struct {
	TsUnixNano  int64
	UpRateBps   int64
	DownRateBps int64
	UpTotal     int64
	DownTotal   int64
	Conns       int32
	MemBytes    int64
}

// Push writes a sample to the next ring slot and bumps the write pointer.
func (p *Pusher) Push(s Sample) {
	if p.closed.Load() || p.data == nil {
		return
	}
	wp := atomic.LoadUint32((*uint32)(unsafe.Pointer(&p.data[0])))
	slot := headerSize + int(wp%slotCount)*slotSize
	b := p.data[slot : slot+slotSize]
	binary.LittleEndian.PutUint64(b[0:], uint64(s.TsUnixNano))
	binary.LittleEndian.PutUint64(b[8:], uint64(s.UpRateBps))
	binary.LittleEndian.PutUint64(b[16:], uint64(s.DownRateBps))
	binary.LittleEndian.PutUint64(b[24:], uint64(s.UpTotal))
	binary.LittleEndian.PutUint64(b[32:], uint64(s.DownTotal))
	binary.LittleEndian.PutUint32(b[40:], uint32(s.Conns))
	binary.LittleEndian.PutUint64(b[48:], uint64(s.MemBytes))
	// Publish: bump write pointer last (readers see a complete slot).
	atomic.AddUint32((*uint32)(unsafe.Pointer(&p.data[0])), 1)
}

// Close unmaps and removes the shared file.
func (p *Pusher) Close() {
	if p.closed.Swap(true) {
		return
	}
	if p.data != nil {
		syscall.Munmap(p.data)
	}
	if p.file != nil {
		p.file.Close()
		os.Remove(StatsFilePath)
	}
}
