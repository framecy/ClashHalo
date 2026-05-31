// main.go — ClashPow Engine (v0.4 foundation + supervisor mode)
//
//  Embedded mode (default): runs the embedded mihomo (hub.Parse in-process),
//  high-res stats from the in-process statistic manager.
//
//  Supervisor mode (kernel.json selects an external kernel): execs the
//  downloaded mihomo binary as a supervised child, hot-reloads it via its REST
//  controller, and samples stats by polling that controller.
//
//  Either way the GUI talks to the same controller (127.0.0.1:9092) + the UDS
//  control channel; launchd supervises the engine process itself.

package main

import (
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/metacubex/mihomo/log"

	"github.com/clashpow/engine/logstream"
	"github.com/clashpow/engine/mmap"
	"github.com/clashpow/engine/routed"
	"github.com/clashpow/engine/stats"
	"github.com/clashpow/engine/xpc"
)

const (
	controllerAddr = "127.0.0.1:9092"
	controllerKey  = "clashpow"
	devCoexist     = true
)

func main() {
	log.Infoln("ClashPow Engine starting…")

	ruleLoader := mmap.NewLoader()
	statsPusher := stats.NewPusher()
	routeDaemon := routed.NewDaemon()
	logWriter := logstream.NewWriter()
	if err := logWriter.Start(); err != nil {
		log.Warnln("log stream socket failed: %v", err)
	}

	cm := newConfigManager(controllerAddr, controllerKey, devCoexist)
	home := filepath.Dir(cm.path)

	server := xpc.NewServer(xpc.Dependencies{
		RuleLoader:  ruleLoader,
		StatsPusher: statsPusher,
		RouteDaemon: routeDaemon,
		LogWriter:   logWriter,
	})
	server.SetConfigApplier(cm.apply)
	server.SetConfigPatcher(cm.patch)
	server.SetController(controllerAddr, controllerKey)

	// Choose kernel: external (supervisor) if selected + present, else embedded.
	sel := readKernelSelection(home)
	external := false
	if sel.External != "" {
		if _, err := os.Stat(sel.External); err == nil {
			external = true
		} else {
			log.Warnln("selected external kernel missing (%s); using embedded", sel.External)
		}
	}

	if external {
		// set the home dir so geodata/cache resolve consistently for the child
		_ = os.MkdirAll(filepath.Join(home, "providers"), 0o755)
		_ = os.MkdirAll(filepath.Join(home, "ruleset"), 0o755)
		if err := cm.prepareRunConfig(); err != nil {
			log.Errorln("prepare run config: %v", err)
		}
		sup := NewSupervisor(sel.External, home, cm.runPath, controllerAddr, controllerKey)
		cm.setExternal(sup)
		if err := sup.Start(); err != nil {
			log.Errorln("supervisor start failed (%v); falling back to embedded", err)
			cm.setExternal(nil)
			external = false
		} else {
			log.Infoln("running external kernel %s (%s)", sel.Tag, sel.External)
			startExternalStatsSampler(statsPusher, controllerAddr, controllerKey)
		}
	}

	if !external {
		if err := cm.loadInitial(); err != nil {
			log.Errorln("initial config: %v", err)
		} else {
			log.Infoln("mihomo controller ready on %s (embedded)", controllerAddr)
		}
		startStatsSampler(statsPusher)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		for sig := range sigCh {
			if sig == syscall.SIGHUP {
				log.Infoln("SIGHUP — reload via config file")
				_ = cm.loadInitial()
				continue
			}
			log.Infoln("shutting down…")
			if cm.external != nil {
				cm.external.Stop()
			}
			server.Shutdown()
			statsPusher.Close()
			ruleLoader.Close()
			routeDaemon.Close()
			logWriter.Close()
			os.Exit(0)
		}
	}()

	server.Run()
}
