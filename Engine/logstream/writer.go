// Package logstream provides a high-performance structured log writer
// over a Unix Domain Socket, consumed by the GUI process for real-time
// log display.
package logstream

import (
	"encoding/json"
	"net"
	"os"
	"sync"
	"time"
)

// Writer sends structured JSON log lines over a Unix Domain Socket.
// Uses a ring buffer internally to batch writes and reduce syscall overhead.
type Writer struct {
	mu       sync.Mutex
	listener net.Listener
	conns    []net.Conn
	sockPath string
	running  bool
	buf      []byte // ring buffer
	bufPos   int
	batchSz  int
}

// LogEntry is a single structured log event.
type LogEntry struct {
	Timestamp time.Time `json:"ts"`
	Level     string    `json:"level"`  // debug, info, warn, error
	Message   string    `json:"msg"`
	Module    string    `json:"module,omitempty"`
}

const (
	defaultSockPath = "/tmp/clashpow-log.sock"
	defaultBufSize  = 1 << 20 // 1MB ring buffer
	defaultBatchSz  = 4096
)

// NewWriter creates a new log stream writer.
func NewWriter() *Writer {
	return &Writer{
		sockPath: defaultSockPath,
		buf:      make([]byte, defaultBufSize),
		batchSz:  defaultBatchSz,
	}
}

// NewWriterWithPath creates a writer with a custom socket path.
func NewWriterWithPath(sockPath string) *Writer {
	return &Writer{
		sockPath: sockPath,
		buf:      make([]byte, defaultBufSize),
		batchSz:  defaultBatchSz,
	}
}

// SockPath returns the Unix Domain Socket path the GUI should connect to.
func (w *Writer) SockPath() string {
	return w.sockPath
}

// Start begins listening on the Unix Domain Socket.
// GUI processes connect as clients to receive log streams.
func (w *Writer) Start() error {
	w.mu.Lock()
	defer w.mu.Unlock()

	// Remove stale socket file
	os.Remove(w.sockPath)

	l, err := net.Listen("unix", w.sockPath)
	if err != nil {
		return err
	}
	w.listener = l
	w.running = true

	go w.acceptLoop()
	go w.flushLoop()

	return nil
}

// acceptLoop accepts incoming GUI connections.
func (w *Writer) acceptLoop() {
	for w.running {
		conn, err := w.listener.Accept()
		if err != nil {
			if w.running {
				continue
			}
			return
		}
		w.mu.Lock()
		w.conns = append(w.conns, conn)
		w.mu.Unlock()
	}
}

// Write appends a log entry to the ring buffer.
// Non-blocking; if buffer is full, the oldest entry is dropped.
func (w *Writer) Write(entry LogEntry) {
	b, err := json.Marshal(entry)
	if err != nil {
		return
	}
	b = append(b, '\n')

	w.mu.Lock()
	defer w.mu.Unlock()

	if w.bufPos+len(b) > len(w.buf) {
		w.bufPos = 0
	}
	copy(w.buf[w.bufPos:], b)
	w.bufPos += len(b)

	// If buffer near full, trigger flush
	if w.bufPos > len(w.buf)-w.batchSz {
		go w.flush()
	}
}

// flushLoop periodically flushes the ring buffer to all connected clients.
func (w *Writer) flushLoop() {
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	for range ticker.C {
		if !w.running {
			return
		}
		w.flush()
	}
}

// flush writes buffered data to all connected clients.
func (w *Writer) flush() {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.bufPos == 0 {
		return
	}

	data := make([]byte, w.bufPos)
	copy(data, w.buf[:w.bufPos])
	w.bufPos = 0

	// Write to all connected clients; remove dead connections
	alive := w.conns[:0]
	for _, conn := range w.conns {
		if _, err := conn.Write(data); err != nil {
			conn.Close()
			continue
		}
		alive = append(alive, conn)
	}
	w.conns = alive
}

// Close stops the writer and cleans up.
func (w *Writer) Close() error {
	w.mu.Lock()
	w.running = false
	w.mu.Unlock()

	if w.listener != nil {
		w.listener.Close()
	}
	for _, conn := range w.conns {
		conn.Close()
	}
	return os.Remove(w.sockPath)
}
