package main

import "C"
import (
	"log"
	"os"


	"github.com/clashpow/engine/logstream"
	"github.com/clashpow/engine/mmap"
	"github.com/clashpow/engine/routed"
	"github.com/clashpow/engine/stats"
	"github.com/clashpow/engine/xpc"
)

var (
	server      *xpc.Server
	statsPusher *stats.Pusher
	ruleLoader  *mmap.Loader
	routeDaemon *routed.Daemon
	logWriter   *logstream.Writer
)

//export StartEngine
func StartEngine(homeDir *C.char) C.int {
	home := C.GoString(homeDir)
	log.Printf("CGO: Starting ClashPow engine in %s\n", home)
	os.Setenv("MIHOMO_BASEDIR", home)

	ruleLoader = mmap.NewLoader()
	statsPusher = stats.NewPusher()
	routeDaemon = routed.NewDaemon()
	logWriter = logstream.NewWriter()
	_ = logWriter.Start()

	// For simplicity, we just use the embedded mihomo
	// and start the XPC JSON-RPC server so the main app can connect via UDS.
	// This minimizes Swift-side changes while giving us the CGO embedding.
	server = xpc.NewServer(xpc.Dependencies{
		RuleLoader:  ruleLoader,
		StatsPusher: statsPusher,
		RouteDaemon: routeDaemon,
		LogWriter:   logWriter,
	})
	
	// TODO: Replace with proper config manager
	// server.SetConfigApplier(...)
	
	go server.Run()
	return 0
}

//export StopEngine
func StopEngine() {
	if server != nil {
		server.Shutdown()
	}
	if statsPusher != nil {
		statsPusher.Close()
	}
	if ruleLoader != nil {
		ruleLoader.Close()
	}
	if routeDaemon != nil {
		routeDaemon.Close()
	}
	if logWriter != nil {
		logWriter.Close()
	}
}

func main() {}
