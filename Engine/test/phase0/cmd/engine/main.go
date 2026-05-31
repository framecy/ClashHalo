// Command engine: Phase 0 prototype — engine-side IOSurface writer.
// Creates an IOSurface, writes stats at 10ms intervals, prints the surface ID.
// Build: CGO_ENABLED=1 go build -o /tmp/clashpow-engine-test ./test/phase0/cmd/engine/
package main

/*
#cgo LDFLAGS: -framework CoreFoundation -framework IOSurface
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurface.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#define SURFACE_SIZE 4096
#define OFF_WRITE_PTR   0x00
#define OFF_TIMESTAMP   0x04
#define OFF_TCP_RATE    0x0C
#define OFF_UDP_RATE    0x10
#define OFF_CONNECTIONS 0x14

static IOSurfaceRef createSurface(uint32_t *outID) {
    int w = SURFACE_SIZE, h = 1, bpr = SURFACE_SIZE, pf = 0;
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef cw = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &w);
    CFNumberRef ch = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &h);
    CFNumberRef cbpr = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bpr);
    CFNumberRef cpf = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pf);
    CFDictionarySetValue(dict, kIOSurfaceWidth, cw);
    CFDictionarySetValue(dict, kIOSurfaceHeight, ch);
    CFDictionarySetValue(dict, kIOSurfaceBytesPerRow, cbpr);
    CFDictionarySetValue(dict, kIOSurfacePixelFormat, cpf);
    IOSurfaceRef s = IOSurfaceCreate(dict);
    CFRelease(cw); CFRelease(ch); CFRelease(cbpr); CFRelease(cpf); CFRelease(dict);
    if (s) *outID = IOSurfaceGetID(s);
    return s;
}

static void writeStats(IOSurfaceRef s, int64_t ts, float tcp, float udp, uint32_t conns) {
    IOSurfaceLock(s, 0, NULL);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(s);
    if (!base) { IOSurfaceUnlock(s, 0, NULL); return; }
    uint32_t *wp = (uint32_t *)(base + OFF_WRITE_PTR); (*wp)++;
    *(int64_t *)(base + OFF_TIMESTAMP) = ts;
    *(float *)(base + OFF_TCP_RATE) = tcp;
    *(float *)(base + OFF_UDP_RATE) = udp;
    *(uint32_t *)(base + OFF_CONNECTIONS) = conns;
    IOSurfaceUnlock(s, 0, NULL);
}
*/
import "C"
import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
	"unsafe"
)

func main() {
	var surfaceID C.uint32_t
	surface := C.createSurface(&surfaceID)
	if uintptr(unsafe.Pointer(surface)) == 0 {
		fmt.Fprintln(os.Stderr, "FATAL: Failed to create IOSurface (are you running sandboxed?)")
		os.Exit(1)
	}
	defer C.CFRelease(C.CFTypeRef(surface))

	fmt.Printf("IOSURFACE_ID=%d\n", surfaceID)
	fmt.Println("Engine writing stats every 10ms. Press Ctrl+C to stop.")

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	var conns uint32
	for {
		select {
		case <-sigCh:
			fmt.Println("\nShutting down.")
			return
		case t := <-ticker.C:
			conns++
			if conns > 999999 { conns = 0 }
			rate := 1000000.0 + float32(conns%100)*10000.0
			C.writeStats(surface, C.int64_t(t.UnixNano()),
				C.float(rate), C.float(rate*0.5), C.uint32_t(conns))
		}
	}
}
