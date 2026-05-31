// Command gui: Phase 0 prototype — GUI-side IOSurface reader.
// Build: CGO_ENABLED=1 go build -o /tmp/clashpow-gui-test ./test/phase0/cmd/gui/
package main

/*
#cgo LDFLAGS: -framework CoreFoundation -framework IOSurface
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurface.h>
#include <stdint.h>
#include <stdio.h>

#define OFF_WRITE_PTR   0x00
#define OFF_TIMESTAMP   0x04
#define OFF_TCP_RATE    0x0C
#define OFF_UDP_RATE    0x10
#define OFF_CONNECTIONS 0x14

typedef struct {
    uint32_t writePtr;
    int64_t  timestamp;
    float    tcpRate;
    float    udpRate;
    uint32_t connections;
} StatsRead;

static StatsRead readSurface(uint32_t surfaceID) {
    StatsRead r = {0};
    IOSurfaceRef s = IOSurfaceLookup(surfaceID);
    if (!s) { fprintf(stderr, "IOSurfaceLookup(%u) returned NULL\n", surfaceID); return r; }
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(s);
    if (base) {
        r.writePtr    = *(uint32_t *)(base + OFF_WRITE_PTR);
        r.timestamp   = *(int64_t  *)(base + OFF_TIMESTAMP);
        r.tcpRate     = *(float    *)(base + OFF_TCP_RATE);
        r.udpRate     = *(float    *)(base + OFF_UDP_RATE);
        r.connections = *(uint32_t *)(base + OFF_CONNECTIONS);
    }
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    CFRelease(s);
    return r;
}
*/
import "C"
import (
	"fmt"
	"os"
	"strconv"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <IOSurfaceID>\n", os.Args[0])
		os.Exit(1)
	}
	surfaceID, _ := strconv.ParseUint(os.Args[1], 10, 32)

	fmt.Println("WritePtr | Timestamp          | TCP Rate    | UDP Rate    | Connections")
	fmt.Println("---------|-------------------|-------------|-------------|------------")

	var lastWritePtr C.uint32_t
	for i := 0; i < 6; i++ {
		r := C.readSurface(C.uint32_t(surfaceID))
		newData := r.writePtr != lastWritePtr
		marker := " "
		if newData { marker = "*" }
		fmt.Printf("%s %7d | %17d | %11.1f | %11.1f | %11d\n",
			marker, r.writePtr, r.timestamp, r.tcpRate, r.udpRate, r.connections)
		lastWritePtr = r.writePtr
		time.Sleep(100 * time.Millisecond)
	}
}
