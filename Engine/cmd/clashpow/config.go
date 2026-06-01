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
	"os/exec"
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
	external       *Supervisor // non-nil → run external kernel instead of embedded
	runPath        string      // overridden config the external kernel reads
}

// setExternal switches the manager into supervisor (external-kernel) mode.
func (c *configManager) setExternal(s *Supervisor) {
	c.mu.Lock(); defer c.mu.Unlock()
	c.external = s
}

func newConfigManager(controllerAddr, secret string, devMode bool) *configManager {
	cfgPath := os.Getenv("CLASHPOW_CONFIG")
	if cfgPath == "" {
		home, _ := os.UserHomeDir()
		cfgPath = filepath.Join(home, "Library", "Application Support", "ClashPow", "config.yaml")
	}
	return &configManager{
		path:           cfgPath,
		controllerAddr: controllerAddr,
		secret:         secret,
		devMode:        devMode,
		runPath:        filepath.Join(filepath.Dir(cfgPath), "config.run.yaml"),
	}
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

	// Strictly enforce CDN GEO defaults
	geo := map[string]string{
		"mmdb":    "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/country.mmdb",
		"asn":     "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb",
		"geosite": "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat",
		"geoip":   "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat",
	}
	m["geox-url"] = geo

	// TUN requires root to create the utun + manage routes (no Network Extension
	// entitlement per spec). When NOT running as root we force TUN off so the
	// user-level engine never errors on it; as a root LaunchDaemon we leave TUN
	// as authored so the embedded mihomo brings the utun up itself.
	if os.Geteuid() != 0 {
		if tun, ok := m["tun"].(map[string]any); ok {
			tun["enable"] = false
			m["tun"] = tun
		}
	} else {
		// Clean up stale route 1.0.0.0/8 and 198.18.0.0/15 which block TUN startup
		if tun, ok := m["tun"].(map[string]any); ok && tun["enable"] == true {
			exec.Command("/sbin/route", "-n", "delete", "-net", "1.0.0.0/8").Run()
			exec.Command("/sbin/route", "-n", "delete", "-net", "198.18.0.0/15").Run()
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
	// External (supervisor) mode: write the run config + hot-reload the child.
	if c.external != nil {
		if err := os.WriteFile(c.runPath, out, 0o644); err != nil {
			return err
		}
		if err := c.external.Reload(c.runPath); err != nil {
			log.Errorln("external reload failed: %v", err)
			if c.lastGood != nil {
				_ = os.WriteFile(c.runPath, c.lastGood, 0o644)
				_ = c.external.Reload(c.runPath)
			}
			return err
		}
		c.lastGood = out
		return nil
	}
	// Embedded mode: parse in-process with rollback.
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

// prepareRunConfig writes the current source config (overridden) to runPath so
// the external kernel can be launched with -f runPath before any apply call.
func (c *configManager) prepareRunConfig() error {
	raw, err := os.ReadFile(c.path)
	if err != nil {
		raw = []byte(fmt.Sprintf("mixed-port: 7892\nmode: rule\nexternal-controller: %s\nsecret: %s\n", c.controllerAddr, c.secret))
	}
	out, err := c.override(raw)
	if err != nil {
		return err
	}
	c.lastGood = out
	return os.WriteFile(c.runPath, out, 0o644)
}

// patch deep-merges overrides into the source config file, persists it, and
// re-applies with rollback. The primitive behind every settings form.
func (c *configManager) patch(overrides map[string]any) error {
	c.mu.Lock()
	path := c.path
	c.mu.Unlock()

	raw, err := os.ReadFile(path)
	if err != nil {
		raw = []byte("{}")
	}
	var m map[string]any
	if err := yaml.Unmarshal(raw, &m); err != nil || m == nil {
		m = map[string]any{}
	}
	deepMerge(m, overrides)
	out, err := yaml.Marshal(m)
	if err != nil {
		return err
	}
	_ = os.WriteFile(path, out, 0o644)
	return c.apply(out)
}

// deepMerge recursively merges src into dst (maps merge; scalars/slices replace).
func deepMerge(dst, src map[string]any) {
	for k, v := range src {
		if sv, ok := v.(map[string]any); ok {
			if dv, ok := dst[k].(map[string]any); ok {
				deepMerge(dv, sv)
				continue
			}
		}
		dst[k] = v
	}
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
			"mixed-port: 7890\nmode: rule\nlog-level: info\nexternal-controller: %s\nsecret: %s\n"+
				"geox-url:\n"+
				"  mmdb: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/country.mmdb\n"+
				"  asn: https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb\n"+
				"  geosite: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat\n"+
				"  geoip: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat\n",
			c.controllerAddr, c.secret))
		// best-effort: write the fallback so the user has a file to edit
		_ = os.MkdirAll(filepath.Dir(c.path), 0o755)
		_ = os.WriteFile(c.path, raw, 0o644)
	}
	return c.apply(raw)
}
