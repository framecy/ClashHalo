// config.go — managed mihomo configuration with override + rollback.
//
// The engine owns the running config. On apply it:
//   1. overrides controller/ports/tun so the engine coexists predictably
//   2. parses via mihomo hub.Parse
//   3. on failure, rolls back to the last-known-good config
//
// This realizes the spec's "配置错误自动回滚至上一良好版本".

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/log"
	"gopkg.in/yaml.v3"
)

type configManager struct {
	mu             sync.Mutex
	path           string
	controllerAddr string
	secret         string
	devMode        bool // override ports + disable TUN for coexistence
	lastGood       []byte
}

func newConfigManager(controllerAddr, secret string, devMode bool) *configManager {
	cfgPath := os.Getenv("CLASHPOW_CONFIG")
	if cfgPath == "" {
		home, _ := os.UserHomeDir()
		cfgPath = filepath.Join(home, "Library", "Application Support", "ClashPow", "config.yaml")
	}
	return &configManager{path: cfgPath, controllerAddr: controllerAddr, secret: secret, devMode: devMode}
}

// override injects controller/secret (always) and, in dev mode, relocates
// inbound ports and disables TUN so the engine never fights an existing kernel.
func (c *configManager) override(raw []byte) ([]byte, error) {
	var m map[string]any
	if err := yaml.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("yaml parse: %w", err)
	}
	if m == nil {
		m = map[string]any{}
	}
	m["external-controller"] = c.controllerAddr
	m["secret"] = c.secret
	if c.devMode {
		m["mixed-port"] = 7892
		m["socks-port"] = 7893
		m["port"] = 0
		m["redir-port"] = 0
		m["tproxy-port"] = 0
		if tun, ok := m["tun"].(map[string]any); ok {
			tun["enable"] = false
			m["tun"] = tun
		}
	}
	return yaml.Marshal(m)
}

// apply overrides + parses raw config. On failure rolls back to lastGood.
func (c *configManager) apply(raw []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	out, err := c.override(raw)
	if err != nil {
		return err
	}
	if err := hub.Parse(out); err != nil {
		log.Errorln("config apply failed: %v", err)
		if c.lastGood != nil {
			log.Warnln("rolling back to last-good config")
			_ = hub.Parse(c.lastGood)
		}
		return err
	}
	c.lastGood = out
	return nil
}

// loadInitial reads the config file (or a minimal fallback) and applies it.
func (c *configManager) loadInitial() error {
	// Set mihomo's home dir so providers/cache/geo resolve under our app dir.
	home := filepath.Dir(c.path)
	_ = os.MkdirAll(filepath.Join(home, "providers"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, "ruleset"), 0o755)
	C.SetHomeDir(home)

	raw, err := os.ReadFile(c.path)
	if err != nil {
		log.Warnln("config %s not found, using minimal fallback", c.path)
		raw = []byte(fmt.Sprintf(
			"mixed-port: 7892\nmode: rule\nlog-level: info\nexternal-controller: %s\nsecret: %s\n",
			c.controllerAddr, c.secret))
		// best-effort: write the fallback so the user has a file to edit
		_ = os.MkdirAll(filepath.Dir(c.path), 0o755)
		_ = os.WriteFile(c.path, raw, 0o644)
	}
	return c.apply(raw)
}
