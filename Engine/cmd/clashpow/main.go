// main.go — ClashPow Engine (v0.4 foundation)
//
//  1. Embeds the mihomo kernel (imported as a Go library)
//  2. Loads a managed config with controller override + rollback
//  3. Exposes a UDS typed-RPC control channel to the GUI
//  4. Hosts mihomo's REST API on a private controller for the data plane
//
// Lifecycle is supervised by launchd (KeepAlive). The GUI discovers the
// controller endpoint via the get_status RPC.

package main

import (
	"os"
	"os/signal"
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
	devCoexist     = true // override ports + disable TUN while a user kernel may run
)

func main() {
	log.Infoln("ClashPow Engine starting…")

	// Extension modules (used by later versions; wired now for stability)
	ruleLoader := mmap.NewLoader()
	statsPusher := stats.NewPusher()
	routeDaemon := routed.NewDaemon()
	logWriter := logstream.NewWriter()
	if err := logWriter.Start(); err != nil {
		log.Warnln("log stream socket failed: %v", err)
	}

	// Managed config (override + rollback)
	cm := newConfigManager(controllerAddr, controllerKey, devCoexist)

	// RPC server
	server := xpc.NewServer(xpc.Dependencies{
		RuleLoader:  ruleLoader,
		StatsPusher: statsPusher,
		RouteDaemon: routeDaemon,
		LogWriter:   logWriter,
	})
	server.SetConfigApplier(cm.apply)
	server.SetController(controllerAddr, controllerKey)

	// Initial config load (brings up mihomo + its REST controller)
	if err := cm.loadInitial(); err != nil {
		log.Errorln("initial config: %v", err)
	} else {
		log.Infoln("mihomo controller ready on %s", controllerAddr)
	}

	// High-resolution stats sampler → mmap shared file for the GUI Metal chart
	startStatsSampler(statsPusher)

	// Signals
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
