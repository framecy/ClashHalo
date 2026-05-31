// main.go — ClashPow Engine
//
// Integrated entry point that:
//  1. Starts extension modules (mmap loader, stats pusher, route daemon, log stream)
//  2. Initializes mihomo kernel with full feature parity
//  3. Exposes control via JSON-RPC over Unix Domain Socket to the GUI process
//
// We import mihomo as a library and call hub/executor APIs directly.
// Extensions are injected as custom packages without modifying mihomo source.

package main

import (
	"os"
	"os/signal"
	"syscall"

	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/log"

	"github.com/clashpow/engine/logstream"
	"github.com/clashpow/engine/mmap"
	"github.com/clashpow/engine/routed"
	"github.com/clashpow/engine/stats"
	"github.com/clashpow/engine/xpc"
)

func main() {
	log.Infoln("ClashPow Engine starting...")

	// Extension modules
	ruleLoader := mmap.NewLoader()
	statsPusher := stats.NewPusher()
	routeDaemon := routed.NewDaemon()
	logWriter := logstream.NewWriter()

	if err := logWriter.Start(); err != nil {
		log.Warnln("Log stream socket failed to start: %v", err)
	}

	// RPC server
	server := xpc.NewServer(xpc.Dependencies{
		RuleLoader:  ruleLoader,
		StatsPusher: statsPusher,
		RouteDaemon: routeDaemon,
		LogWriter:   logWriter,
	})
	server.SetConfigApplier(func(cfgBytes []byte) error {
		return hub.Parse(cfgBytes)
	})

	// Signal handlers
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	go func() {
		for sig := range sigCh {
			switch sig {
			case syscall.SIGHUP:
				log.Infoln("SIGHUP received — config reload via XPC only")
			default:
				log.Infoln("Shutting down...")
				server.Shutdown()
				statsPusher.Close()
				ruleLoader.Close()
				routeDaemon.Close()
				logWriter.Close()
				os.Exit(0)
			}
		}
	}()

	server.Run()
}
