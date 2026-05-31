// Package stats pushes real-time proxy statistics to an IOSurface shared
// memory region, allowing the GUI process to read them with zero CPU copy
// via Metal's CVMetalTextureCache.
package stats

import (
	"encoding/binary"
	"math"
	"sync/atomic"
	"time"
	"unsafe"
)

// IOSurface data layout (4096 bytes ring buffer).
//
// Offset  Size   Field
// 0x00    4      Write pointer (uint32, atomic)
// 0x04    8      Timestamp (int64, nanoseconds)
// 0x0C    4      TCP total rate (float32, bytes/sec)
// 0x10    4      UDP total rate (float32, bytes/sec)
// 0x14    4      Current connection count (uint32)
// 0x18    ...    Per-outbound array (12 bytes each: 4B ID + 4B rate + 4B conns)
const (
	SurfaceSize      = 4096
	MaxOutbounds     = 128
	OutboundSlotSize = 12
	HeaderEnd        = 0x18 + MaxOutbounds*OutboundSlotSize
)

// Snapshot is a point-in-time stats sample.
type Snapshot struct {
	Timestamp   time.Time
	TcpRate     float32 // bytes/sec
	UdpRate     float32 // bytes/sec
	Connections uint32
	Outbounds   []OutboundStat
}

// OutboundStat holds per-outbound proxy statistics.
type OutboundStat struct {
	ID   uint32
	Rate float32 // bytes/sec
}

// Pusher manages the IOSurface shared memory region for stats.
type Pusher struct {
	buf    []byte
	bufPtr unsafe.Pointer // points to buf[0] for atomic access to header fields
	closed atomic.Bool
}

// NewPusher creates a new stats pusher backed by a 4096-byte buffer.
// In production, this will be backed by an IOSurface allocated via
// IOSurfaceCreate(); for now, we use an in-memory buffer for testing.
func NewPusher() *Pusher {
	buf := make([]byte, SurfaceSize)
	return &Pusher{
		buf:    buf,
		bufPtr: unsafe.Pointer(&buf[0]),
	}
}

// NewPusherWithData creates a pusher wrapping an existing byte slice
// (backed by IOSurface or shared memory).
func NewPusherWithData(data []byte) *Pusher {
	return &Pusher{
		buf:    data,
		bufPtr: unsafe.Pointer(&data[0]),
	}
}

// Push writes a snapshot into the ring buffer and advances the write pointer.
func (p *Pusher) Push(s Snapshot) {
	if p.closed.Load() {
		return
	}

	// Write pointer: which slot in the ring buffer to use next
	wp := atomic.AddUint32((*uint32)(unsafe.Add(p.bufPtr, 0x00)), 1)

	// Ring buffer slots start after HeaderEnd
	slotCount := (SurfaceSize - HeaderEnd) / slotSize()
	slotIdx := wp % uint32(slotCount)
	slotOffset := HeaderEnd + slotIdx*uint32(slotSize())

	// Write snapshot data into the slot
	slot := unsafe.Add(p.bufPtr, slotOffset)
	binary.LittleEndian.PutUint64(unsafe.Slice((*byte)(unsafe.Add(slot, 0)), 8), uint64(s.Timestamp.UnixNano()))
	binary.LittleEndian.PutUint32(unsafe.Slice((*byte)(unsafe.Add(slot, 8)), 4), math.Float32bits(s.TcpRate))
	binary.LittleEndian.PutUint32(unsafe.Slice((*byte)(unsafe.Add(slot, 12)), 4), math.Float32bits(s.UdpRate))
	binary.LittleEndian.PutUint32(unsafe.Slice((*byte)(unsafe.Add(slot, 16)), 4), s.Connections)
	// Outbounds encoded in the per-outbound array at header
	for i, ob := range s.Outbounds {
		if i >= MaxOutbounds {
			break
		}
		obOff := uint32(0x18) + uint32(i)*OutboundSlotSize
		binary.LittleEndian.PutUint32(unsafe.Slice((*byte)(unsafe.Add(p.bufPtr, obOff)), 4), ob.ID)
		binary.LittleEndian.PutUint32(unsafe.Slice((*byte)(unsafe.Add(p.bufPtr, obOff+4)), 4), math.Float32bits(ob.Rate))
	}
}

// BasePtr returns a pointer to the underlying buffer for sharing via XPC.
func (p *Pusher) BasePtr() unsafe.Pointer {
	return p.bufPtr
}

// Size returns the buffer size in bytes.
func (p *Pusher) Size() int {
	return SurfaceSize
}

// Close marks the pusher as closed.
func (p *Pusher) Close() {
	p.closed.Store(true)
}

func slotSize() int {
	return 8 + 4 + 4 + 4 // timestamp + tcp + udp + conns
}
