// IOSurfaceLayout.h
// Shared constants for the IOSurface ring buffer used for zero-copy
// statistics streaming from engine (Go) to GUI (Metal/Swift).
//
// This file is kept in sync with Engine/stats/pusher.go.

#pragma once

#import <stdint.h>

#define IOSURFACE_STATS_SIZE       4096
#define IOSURFACE_MAX_OUTBOUNDS    128
#define IOSURFACE_OUTBOUND_SLOT_SZ 12
#define IOSURFACE_HEADER_END       (0x18 + IOSURFACE_MAX_OUTBOUNDS * IOSURFACE_OUTBOUND_SLOT_SZ)

// Offsets within the IOSurface
#define IOSURFACE_OFF_WRITE_PTR    0x00  // uint32_t, atomic
#define IOSURFACE_OFF_TIMESTAMP    0x04  // int64_t, nanoseconds
#define IOSURFACE_OFF_TCP_RATE     0x0C  // float (bytes/sec)
#define IOSURFACE_OFF_UDP_RATE     0x10  // float (bytes/sec)
#define IOSURFACE_OFF_CONNECTIONS  0x14  // uint32_t
#define IOSURFACE_OFF_OUTBOUNDS    0x18  // array of OutboundStat

// Per-outbound stat layout (12 bytes each)
typedef struct {
    uint32_t outboundID;
    float    rate;      // bytes/sec
    uint32_t conns;
} OutboundStat;

// Snapshot slot layout in ring buffer (20 bytes each)
typedef struct {
    int64_t  timestamp;  // nanoseconds
    float    tcpRate;    // bytes/sec
    float    udpRate;    // bytes/sec
    uint32_t connections;
} StatsSnapshot;
