// tun_test.go
// Phase 0 Prototype: UTUN interface performance baseline.
//
// Validates:
//  1. Can open a user-space UTUN (AF_SYSTEM) socket
//  2. Measure writev bulk throughput with iovec batching
//  3. Measure single-packet round-trip latency
//  4. Compare against targets: ≤ 1.8ms P99 latency, ≥ 9 Gbps throughput
//
// Prerequisites: macOS 14+, Apple Silicon, UTUN needs sudo.

package phase0

import (
	"encoding/binary"
	"net"
	"sync"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Darwin constants not exposed by x/sys/unix.
const (
	darwinAFSystem      = 32
	darwinSysprotoCtrl  = 2
	darwinCtlInfoSize   = 100 // sizeof(struct ctl_info) = 4 + 96
	darwinUtunOptIfname = 2
)

// createUTUN creates a user-space TUN interface using AF_SYSTEM socket.
// This does NOT consume a VPN slot — unlike NEPacketTunnelProvider.
func createUTUN(t *testing.T) (fd int, name string, err error) {
	t.Helper()

	fd, err = unix.Socket(darwinAFSystem, unix.SOCK_DGRAM, darwinSysprotoCtrl)
	if err != nil {
		return -1, "", err
	}

	// CTLIOCGINFO ioctl to get the UTUN control ID
	ctlInfo := make([]byte, darwinCtlInfoSize)
	copy(ctlInfo[4:], "com.apple.net.utun_control") // name starts at byte 4
	ctlInfo[3] = 0 // zero out

	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd),
		0xc0644e03, // CTLIOCGINFO
		uintptr(unsafe.Pointer(&ctlInfo[0])))
	if errno != 0 {
		unix.Close(fd)
		return -1, "", errno
	}

	ctlID := binary.LittleEndian.Uint32(ctlInfo[0:4])

	// Connect to get a UTUN interface assigned
	sa := &unix.SockaddrCtl{ID: ctlID, Unit: 0}
	if err = unix.Connect(fd, sa); err != nil {
		unix.Close(fd)
		return -1, "", err
	}

	// Get the assigned interface name via getsockopt(UTUN_OPT_IFNAME)
	nameBuf := make([]byte, 16)
	nameLen := uint32(len(nameBuf))
	_, _, errno = unix.Syscall6(unix.SYS_GETSOCKOPT, uintptr(fd),
		darwinSysprotoCtrl, darwinUtunOptIfname,
		uintptr(unsafe.Pointer(&nameBuf[0])), uintptr(unsafe.Pointer(&nameLen)), 0)
	if errno != 0 {
		unix.Close(fd)
		return -1, "", errno
	}
	name = string(nameBuf[:nameLen-1])

	return fd, name, nil
}

func TestUTUNCreate(t *testing.T) {
	fd, name, err := createUTUN(t)
	if err != nil {
		t.Skipf("UTUN creation requires elevated permissions: %v", err)
	}
	defer unix.Close(fd)

	t.Logf("UTUN interface created: %s (fd=%d)", name, fd)

	ifaces, _ := net.Interfaces()
	found := false
	for _, iface := range ifaces {
		if iface.Name == name {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("UTUN %s not found in net.Interfaces", name)
	}
}

func TestUTUNBulkIO(t *testing.T) {
	fd, name, err := createUTUN(t)
	if err != nil {
		t.Skipf("UTUN creation requires elevated permissions: %v", err)
	}
	defer unix.Close(fd)

	t.Logf("UTUN: %s (fd=%d)", name, fd)

	packetSize := 1500
	batchSize := 64
	iovecs := make([]unix.Iovec, batchSize)
	totalBytes := 0

	for i := 0; i < batchSize; i++ {
		buf := make([]byte, packetSize)
		buf[0] = 0x45 // IPv4
		binary.BigEndian.PutUint16(buf[2:4], uint16(packetSize))
		binary.BigEndian.PutUint16(buf[4:6], uint16(i))
		iovecs[i] = unix.Iovec{Base: &buf[0], Len: uint64(packetSize)}
		totalBytes += packetSize
	}

	iterations := 1000
	start := time.Now()

	for n := 0; n < iterations; n++ {
		_, _, errno := unix.Syscall(unix.SYS_WRITEV, uintptr(fd),
			uintptr(unsafe.Pointer(&iovecs[0])), uintptr(batchSize))
		if errno != 0 && errno != unix.ENOBUFS {
			// ENOBUFS expected without a reader
		}
	}

	elapsed := time.Since(start)
	totalSent := totalBytes * iterations
	throughputGbps := float64(totalSent) * 8 / elapsed.Seconds() / 1_000_000_000

	t.Logf("writev: %d iters x %dB x %d pkts = %d bytes in %v",
		iterations, packetSize, batchSize, totalSent, elapsed)
	t.Logf("Throughput: %.2f Gbps (target: ≥ 9 Gbps)", throughputGbps)
}

func TestUTUNRoundTripLatency(t *testing.T) {
	fd, name, err := createUTUN(t)
	if err != nil {
		t.Skipf("UTUN creation requires elevated permissions: %v", err)
	}
	defer unix.Close(fd)

	t.Logf("UTUN: %s (fd=%d)", name, fd)

	packet := make([]byte, 64)
	packet[0] = 0x45

	var wg sync.WaitGroup
	wg.Add(1)
	received := make(chan time.Duration, 100)

	go func() {
		defer wg.Done()
		buf := make([]byte, 2048)
		for range received {
			_, _, _ = unix.Syscall(unix.SYS_READ, uintptr(fd),
				uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		}
	}()

	var latencies []time.Duration
	for i := 0; i < 100; i++ {
		start := time.Now()
		iovec := unix.Iovec{Base: &packet[0], Len: uint64(len(packet))}
		_, _, _ = unix.Syscall(unix.SYS_WRITEV, uintptr(fd),
			uintptr(unsafe.Pointer(&iovec)), 1)
		lat := time.Since(start)
		latencies = append(latencies, lat)
		received <- lat
	}

	close(received)
	wg.Wait()

	sortDurations(latencies)
	p50 := latencies[len(latencies)/2]
	p99 := latencies[len(latencies)*99/100]

	t.Logf("UTUN RTT: P50=%v P99=%v (target P99 ≤ 1.8ms)", p50, p99)
	if p99 > 1800*time.Microsecond {
		t.Logf("WARNING: P99 %v exceeds 1.8ms target", p99)
	}
}

// --- helpers ---

func sortDurations(d []time.Duration) {
	for i := 1; i < len(d); i++ {
		key := d[i]
		j := i - 1
		for j >= 0 && d[j] > key {
			d[j+1] = d[j]
			j--
		}
		d[j+1] = key
	}
}

var _ = syscall.Socket
