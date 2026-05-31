// tun.go — User-space UTUN interface lifecycle (AF_SYSTEM, no VPN slot)
// Called by the XPC server's handleStartTUN / handleStopTUN.
package xpc

import (
	"fmt"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Darwin constants for AF_SYSTEM UTUN.
const (
	afSystem           = 32
	sysprotoCtrl       = 2
	ctlIocGInfo        = 0xc0644e03
	utunOptIfname      = 2
	ctlInfoSize        = 100
	utunControlName    = "com.apple.net.utun_control"
)

// TUNManager handles a single UTUN interface.
type TUNManager struct {
	mu       sync.Mutex
	fd       int
	name     string
	running  bool
	stopCh   chan struct{}
}

// NewTUNManager creates a new TUN manager.
func NewTUNManager() *TUNManager {
	return &TUNManager{}
}

// Start creates a UTUN interface and brings it up.
// Does NOT add a default route — that's the RouteDaemon's job.
func (t *TUNManager) Start() error {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.running {
		return fmt.Errorf("TUN already running: %s", t.name)
	}

	fd, err := unix.Socket(afSystem, unix.SOCK_DGRAM, sysprotoCtrl)
	if err != nil {
		return fmt.Errorf("TUN socket: %w", err)
	}

	// Get UTUN control ID
	ctlInfo := make([]byte, ctlInfoSize)
	copy(ctlInfo[4:], utunControlName)

	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd),
		ctlIocGInfo, uintptr(unsafe.Pointer(&ctlInfo[0])))
	if errno != 0 {
		unix.Close(fd)
		return fmt.Errorf("TUN ioctl(CTLIOCGINFO): %v", errno)
	}

	ctlID := *(*uint32)(unsafe.Pointer(&ctlInfo[0]))

	// Connect to get a UTUN unit assigned
	sa := &unix.SockaddrCtl{ID: ctlID, Unit: 0}
	if err := unix.Connect(fd, sa); err != nil {
		unix.Close(fd)
		return fmt.Errorf("TUN connect: %w", err)
	}

	// Get the assigned interface name
	nameBuf := make([]byte, 16)
	nameLen := uint32(len(nameBuf))
	_, _, errno = unix.Syscall6(unix.SYS_GETSOCKOPT, uintptr(fd),
		sysprotoCtrl, utunOptIfname,
		uintptr(unsafe.Pointer(&nameBuf[0])), uintptr(unsafe.Pointer(&nameLen)), 0)
	if errno != 0 {
		unix.Close(fd)
		return fmt.Errorf("TUN getsockopt(IFNAME): %v", errno)
	}
	t.name = string(nameBuf[:nameLen-1])
	t.fd = fd
	t.running = true
	t.stopCh = make(chan struct{})

	// Bring the interface up
	if out, err := exec.Command("ifconfig", t.name, "up").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "TUN: ifconfig %s up: %s (non-fatal)\n", t.name, string(out))
	}

	fmt.Fprintf(os.Stderr, "TUN started: %s (fd=%d)\n", t.name, t.fd)

	// Start reader goroutine (prevents kernel buffer overflow)
	go t.readLoop()

	return nil
}

// Stop tears down the UTUN interface.
func (t *TUNManager) Stop() error {
	t.mu.Lock()
	defer t.mu.Unlock()

	if !t.running {
		return nil
	}

	t.running = false
	close(t.stopCh)

	if t.fd > 0 {
		unix.Close(t.fd)
		t.fd = -1
	}

	fmt.Fprintf(os.Stderr, "TUN stopped: %s\n", t.name)
	return nil
}

// Name returns the UTUN interface name (e.g., "utun4").
func (t *TUNManager) Name() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.name
}

// IsRunning returns whether the TUN interface is active.
func (t *TUNManager) IsRunning() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.running
}

// readLoop drains incoming packets from the UTUN to prevent ENOMEM.
func (t *TUNManager) readLoop() {
	buf := make([]byte, 65536)
	for {
		select {
		case <-t.stopCh:
			return
		default:
		}
		n, _, errno := unix.Syscall(unix.SYS_READ, uintptr(t.fd),
			uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		if errno != 0 {
			if errno == syscall.EINTR {
				continue
			}
			return
		}
		_ = n // packets processed by mihomo tunnel
	}
}

// Ensure unused imports don't error.
var _ = fmt.Sprintf
var _ = unsafe.Pointer(nil)
