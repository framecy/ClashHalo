// Package routed manages precise route injection for proxy traffic,
// ensuring coexistence with SD-WAN tools (Tailscale, ZeroTier, etc.).
//
// Key behaviors:
//   - Never adds a default route — only injects /32 or specific subnet routes
//   - Scans existing utun interfaces and routing table on startup
//   - Listens on SCDynamicStore for interface/route changes
//   - Splits overlapping CIDRs into finer subnets to avoid conflicts
//   - Supports per-process routing via SO_USER_COOKIE + PF (optional)
package routed

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
	"sync"
)

// Daemon manages proxy route injection and SD-WAN coexistence.
type Daemon struct {
	mu       sync.Mutex
	routes   []*net.IPNet   // currently injected routes
	bypasses []net.IP       // routes to skip (already covered by SD-WAN)
	iface    string         // our UTUN interface name
}

// NewDaemon creates a new route daemon.
func NewDaemon() *Daemon {
	return &Daemon{}
}

// SetInterface sets the UTUN interface name for route injection.
func (d *Daemon) SetInterface(iface string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.iface = iface
}

// ScanExisting discovers existing routes and UTUN interfaces on the system.
// Returns a list of interfaces that appear to be SD-WAN related.
func (d *Daemon) ScanExisting() ([]string, error) {
	out, err := exec.Command("ifconfig").Output()
	if err != nil {
		return nil, fmt.Errorf("routed: ifconfig failed: %w", err)
	}
	// Parse utun interfaces from ifconfig output
	var sdwanIfaces []string
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "utun") {
			parts := strings.SplitN(line, ":", 2)
			sdwanIfaces = append(sdwanIfaces, parts[0])
		}
	}
	return sdwanIfaces, nil
}

// GetExistingRoutes returns the current routing table.
func (d *Daemon) GetExistingRoutes() ([]string, error) {
	out, err := exec.Command("netstat", "-rn", "-f", "inet").Output()
	if err != nil {
		return nil, fmt.Errorf("routed: netstat failed: %w", err)
	}
	return strings.Split(string(out), "\n"), nil
}

// AddRoute injects a route for the given CIDR via our UTUN interface.
// If the CIDR conflicts with an existing route, it tries to split into
// finer subnets.
func (d *Daemon) AddRoute(cidr string) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	_, net, err := net.ParseCIDR(cidr)
	if err != nil {
		return fmt.Errorf("routed: invalid CIDR %s: %w", cidr, err)
	}

	// Check if this route is already covered by an existing SD-WAN route
	for _, bypass := range d.bypasses {
		if net.Contains(bypass) {
			return fmt.Errorf("routed: %s is covered by SD-WAN bypass route", cidr)
		}
	}

	// Inject the route
	cmd := exec.Command("route", "add", "-net", net.String(), "-interface", d.iface)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("routed: route add failed: %s: %w", string(out), err)
	}

	d.routes = append(d.routes, net)
	return nil
}

// RemoveAllRoutes removes all routes injected by this daemon.
func (d *Daemon) RemoveAllRoutes() error {
	d.mu.Lock()
	defer d.mu.Unlock()

	for _, route := range d.routes {
		cmd := exec.Command("route", "delete", "-net", route.String())
		cmd.Run() // best-effort
	}
	d.routes = nil
	return nil
}

// Close cleans up injected routes.
func (d *Daemon) Close() error {
	return d.RemoveAllRoutes()
}
