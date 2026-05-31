// Package xpc implements the engine-side RPC server.
//
// Transport: Unix Domain Socket with JSON-RPC 2.0 framing.
// The launchd plist registers this socket path; the GUI process
// connects via NSXPCConnection → Mach → launchd → UDS.
//
// For development/direct mode, the GUI can also connect directly
// to the UDS at /tmp/clashpow-engine.sock.
//
// Protocol methods:
//   - set_config(yaml) → {ok, error}
//   - compile_rules(yaml, output_dir) → {ok, binary_path, error}
//   - start_tun() → {ok}
//   - stop_tun() → {ok}
//   - reload_rules(binary_path) → {ok}
//   - get_status() → {running, tun_enabled, connections, uptime_sec, version, iosurface_id}
//   - get_log_socket_path() → {path}
//   - shutdown()

package xpc

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"sync"
	"time"

	"github.com/clashpow/engine/logstream"
	"github.com/clashpow/engine/mmap"
	"github.com/clashpow/engine/routed"
	"github.com/clashpow/engine/stats"
)

// ── Types ────────────────────────────────────────────────────────────

// Dependencies holds references to all engine extension modules.
type Dependencies struct {
	RuleLoader  *mmap.Loader
	StatsPusher *stats.Pusher
	RouteDaemon *routed.Daemon
	LogWriter   *logstream.Writer
}

// Server handles incoming JSON-RPC requests from the GUI process.
type Server struct {
	deps          Dependencies
	mu            sync.Mutex
	configApplier func([]byte) error
	listener      net.Listener
	running       bool
	sockPath      string
	startTime     time.Time
	tun           *TUNManager
	pf            *routed.PFManager
	ctlAddr       string // mihomo external-controller addr (GUI data plane)
	ctlSecret     string
}

// SetController records the embedded mihomo controller endpoint so the GUI
// can discover where to reach the REST/WS data plane.
func (s *Server) SetController(addr, secret string) {
	s.mu.Lock(); defer s.mu.Unlock()
	s.ctlAddr = addr; s.ctlSecret = secret
}

// ── RPC types ────────────────────────────────────────────────────────

// jsonRPCRequest is a standard JSON-RPC 2.0 request.
type jsonRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	ID      int64           `json:"id"`
}

type jsonRPCResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	Result  interface{} `json:"result,omitempty"`
	Error   *rpcError   `json:"error,omitempty"`
	ID      int64       `json:"id"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Method parameter types
type setConfigParams struct {
	ConfigYAML string `json:"config_yaml"`
}

type compileRulesParams struct {
	RulesYAML string `json:"rules_yaml"`
	OutputDir string `json:"output_dir"`
}

type reloadRulesParams struct {
	BinaryPath string `json:"binary_path"`
}

// StatusSnapshot carries point-in-time status for the GUI.
type StatusSnapshot struct {
	Running        bool   `json:"running"`
	TUNEnabled     bool   `json:"tun_enabled"`
	Connections    int    `json:"connections"`
	UptimeSec      int64  `json:"uptime_sec"`
	Version        string `json:"version"`
	IOSurfaceID    int32  `json:"iosurface_id"`
	LogSocketPath  string `json:"log_socket_path"`
	ControllerAddr string `json:"controller_addr"`
	ControllerKey  string `json:"controller_secret"`
}

const (
	socketPath        = "/tmp/clashpow-engine.sock"
	engineVersion     = "0.1.0-dev"
	rpcCodeParseError = -32700
	rpcCodeMethodNotFound = -32601
)

// ── Constructor ──────────────────────────────────────────────────────

// NewServer creates a new XPC/RPC server.
func NewServer(deps Dependencies) *Server {
	return &Server{
		deps:      deps,
		sockPath:  socketPath,
		startTime: time.Now(),
		tun:       NewTUNManager(),
		pf:        routed.NewPFManager(),
	}
}

// SetConfigApplier sets the mihomo config reload function.
func (s *Server) SetConfigApplier(fn func([]byte) error) {
	s.configApplier = fn
}

// ── Lifecycle ────────────────────────────────────────────────────────

// Run starts the Unix Domain Socket listener and blocks.
func (s *Server) Run() {
	os.Remove(s.sockPath)

	l, err := net.Listen("unix", s.sockPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "xpc: listen %s: %v\n", s.sockPath, err)
		os.Exit(1)
	}
	s.listener = l
	s.running = true

	fmt.Printf("ClashPow Engine RPC listening on %s\n", s.sockPath)

	for s.running {
		conn, err := l.Accept()
		if err != nil {
			if s.running {
				continue
			}
			return
		}
		go s.handleConn(conn)
	}
}

// Shutdown gracefully stops the RPC server.
func (s *Server) Shutdown() {
	s.mu.Lock()
	s.running = false
	s.mu.Unlock()

	if s.listener != nil {
		s.listener.Close()
	}
	os.Remove(s.sockPath)
}

// ── Connection handler ───────────────────────────────────────────────

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()

	dec := json.NewDecoder(conn)
	enc := json.NewEncoder(conn)

	for {
		var req jsonRPCRequest
		if err := dec.Decode(&req); err != nil {
			return // client disconnected or malformed
		}

		resp := s.dispatch(req)
		if err := enc.Encode(resp); err != nil {
			return
		}
	}
}

// ── Method dispatch ──────────────────────────────────────────────────

func (s *Server) dispatch(req jsonRPCRequest) jsonRPCResponse {
	switch req.Method {
	case "set_config":
		return s.handleSetConfig(req)
	case "compile_rules":
		return s.handleCompileRules(req)
	case "start_tun":
		return s.handleStartTUN(req)
	case "stop_tun":
		return s.handleStopTUN(req)
	case "reload_rules":
		return s.handleReloadRules(req)
	case "get_status":
		return s.handleGetStatus(req)
	case "get_log_socket_path":
		return s.handleGetLogSocketPath(req)
	case "shutdown":
		return s.handleShutdown(req)
	default:
		return jsonRPCResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &rpcError{Code: rpcCodeMethodNotFound, Message: "method not found: " + req.Method},
		}
	}
}

// ── Handler implementations ──────────────────────────────────────────

func (s *Server) handleSetConfig(req jsonRPCRequest) jsonRPCResponse {
	var p setConfigParams
	if err := json.Unmarshal(req.Params, &p); err != nil {
		return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: rpcCodeParseError, Message: err.Error()}}
	}

	if s.configApplier != nil {
		if err := s.configApplier([]byte(p.ConfigYAML)); err != nil {
			return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -1, Message: err.Error()}}
		}
	}

	return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]bool{"ok": true}}
}

func (s *Server) handleCompileRules(req jsonRPCRequest) jsonRPCResponse {
	var p compileRulesParams
	if err := json.Unmarshal(req.Params, &p); err != nil {
		return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: rpcCodeParseError, Message: err.Error()}}
	}

	// Build a simple policy map from the config applier's current state.
	// In production, this reads from mihomo's proxy/adapter registry.
	policyMap := map[string]uint32{
		"DIRECT": 0,
		"REJECT": 1,
		"Proxy":  2,
	}

	path, err := CompileRules(p.RulesYAML, p.OutputDir, policyMap)
	if err != nil {
		return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]interface{}{
			"ok": false, "error": err.Error(),
		}}
	}

	return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]interface{}{
		"ok":          true,
		"binary_path": path,
	}}
}

func (s *Server) handleStartTUN(req jsonRPCRequest) jsonRPCResponse {
	if err := s.tun.Start(); err != nil {
		return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -1, Message: err.Error()}}
	}
	return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]bool{"ok": true}}
}

func (s *Server) handleStopTUN(req jsonRPCRequest) jsonRPCResponse {
	if err := s.tun.Stop(); err != nil {
		return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -1, Message: err.Error()}}
	}
	return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]bool{"ok": true}}
}

func (s *Server) handleReloadRules(req jsonRPCRequest) jsonRPCResponse {
	var p reloadRulesParams
	if err := json.Unmarshal(req.Params, &p); err != nil {
		return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: rpcCodeParseError, Message: err.Error()}}
	}

	if err := s.deps.RuleLoader.Load(p.BinaryPath); err != nil {
		return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -1, Message: err.Error()}}
	}

	return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]bool{"ok": true}}
}

func (s *Server) handleGetStatus(req jsonRPCRequest) jsonRPCResponse {
	s.mu.Lock(); addr, key := s.ctlAddr, s.ctlSecret; s.mu.Unlock()
	status := StatusSnapshot{
		Running:        true,
		TUNEnabled:     s.tun.IsRunning(),
		Version:        engineVersion,
		UptimeSec:      int64(time.Since(s.startTime).Seconds()),
		IOSurfaceID:    0,
		LogSocketPath:  s.deps.LogWriter.SockPath(),
		ControllerAddr: addr,
		ControllerKey:  key,
	}
	return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: status}
}

func (s *Server) handleGetLogSocketPath(req jsonRPCRequest) jsonRPCResponse {
	return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]string{
		"path": s.deps.LogWriter.SockPath(),
	}}
}

func (s *Server) handleShutdown(req jsonRPCRequest) jsonRPCResponse {
	go func() {
		time.Sleep(100 * time.Millisecond) // allow response to be sent
		s.Shutdown()
		os.Exit(0)
	}()
	return jsonRPCResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]bool{"ok": true}}
}

var _ = fmt.Sprintf
