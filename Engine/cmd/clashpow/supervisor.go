// supervisor.go — run a downloaded external mihomo kernel as a supervised child.
//
// When kernel.json selects an external kernel, the engine does NOT run the
// embedded mihomo; instead it execs the external binary (`mihomo -d <home>
// -f <runConfig>`), monitors it, restarts it on unexpected exit, and reloads
// its config via the kernel's own REST controller (hot reload, no restart).

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/metacubex/mihomo/log"
)

// kernelSelection is persisted by the GUI at <home>/kernel.json.
type kernelSelection struct {
	External string `json:"external"` // path to external mihomo binary; "" = embedded
	Tag      string `json:"tag"`
}

func readKernelSelection(home string) kernelSelection {
	var k kernelSelection
	if data, err := os.ReadFile(filepath.Join(home, "kernel.json")); err == nil {
		_ = json.Unmarshal(data, &k)
	}
	return k
}

type Supervisor struct {
	bin       string
	home      string
	runConfig string
	ctlAddr   string
	ctlSecret string

	mu       sync.Mutex
	cmd      *exec.Cmd
	stopping bool
}

func NewSupervisor(bin, home, runConfig, ctlAddr, ctlSecret string) *Supervisor {
	return &Supervisor{bin: bin, home: home, runConfig: runConfig, ctlAddr: ctlAddr, ctlSecret: ctlSecret}
}

// Start execs the external kernel and keeps it alive.
func (s *Supervisor) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd != nil {
		return fmt.Errorf("supervisor already running")
	}
	s.stopping = false
	return s.spawnLocked()
}

func (s *Supervisor) spawnLocked() error {
	cmd := exec.Command(s.bin, "-d", s.home, "-f", s.runConfig)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("exec %s: %w", s.bin, err)
	}
	s.cmd = cmd
	log.Infoln("supervisor: started external kernel pid=%d (%s)", cmd.Process.Pid, s.bin)
	go s.monitor(cmd)
	return nil
}

// monitor restarts the child if it exits unexpectedly (throttled).
func (s *Supervisor) monitor(cmd *exec.Cmd) {
	_ = cmd.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopping || s.cmd != cmd {
		return
	}
	log.Warnln("supervisor: external kernel exited; restarting in 2s")
	s.cmd = nil
	time.Sleep(2 * time.Second)
	if !s.stopping {
		_ = s.spawnLocked()
	}
}

// Stop terminates the child and disables restart.
func (s *Supervisor) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopping = true
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
		s.cmd = nil
	}
}

// Reload tells the running kernel to hot-reload from the given config path
// via its REST controller (no process restart, connections preserved).
func (s *Supervisor) Reload(path string) error {
	body, _ := json.Marshal(map[string]string{"path": path})
	req, err := http.NewRequest("PUT", "http://"+s.ctlAddr+"/configs?force=true", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if s.ctlSecret != "" {
		req.Header.Set("Authorization", "Bearer "+s.ctlSecret)
	}
	client := &http.Client{Timeout: 8 * time.Second}
	// The controller may take a moment to come up after first spawn; retry briefly.
	var lastErr error
	for i := 0; i < 10; i++ {
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode < 300 {
				return nil
			}
			lastErr = fmt.Errorf("controller reload HTTP %d", resp.StatusCode)
		} else {
			lastErr = err
		}
		time.Sleep(400 * time.Millisecond)
		req, _ = http.NewRequest("PUT", "http://"+s.ctlAddr+"/configs?force=true", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if s.ctlSecret != "" {
			req.Header.Set("Authorization", "Bearer "+s.ctlSecret)
		}
	}
	return lastErr
}
