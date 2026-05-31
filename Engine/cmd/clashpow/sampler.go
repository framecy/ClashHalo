// sampler.go — high-resolution stats sampling loop.
//
// Reads mihomo's in-process statistic manager and publishes samples to the
// mmap'd shared file for the GUI's Metal chart. Adaptive cadence: fast while
// traffic flows, slow when idle (power saving, per spec "10ms 负载 / 1s 空闲").

package main

import (
	"time"

	"github.com/metacubex/mihomo/tunnel/statistic"

	"github.com/clashpow/engine/stats"
)

func startStatsSampler(p *stats.Pusher) {
	go func() {
		var lastUp, lastDown int64
		var lastT = time.Now()
		fast := 50 * time.Millisecond
		slow := 1000 * time.Millisecond
		interval := slow
		timer := time.NewTimer(interval)
		defer timer.Stop()

		for range timer.C {
			mgr := statistic.DefaultManager
			if mgr == nil {
				timer.Reset(slow)
				continue
			}
			up, down := mgr.Total()
			now := time.Now()
			dt := now.Sub(lastT).Seconds()
			if dt <= 0 {
				dt = 0.05
			}
			dUp := up - lastUp
			dDown := down - lastDown
			upRate := int64(float64(dUp) / dt)
			downRate := int64(float64(dDown) / dt)
			lastUp, lastDown, lastT = up, down, now

			var conns int32
			mgr.Range(func(statistic.Tracker) bool { conns++; return true })

			p.Push(stats.Sample{
				TsUnixNano:  now.UnixNano(),
				UpRateBps:   upRate,
				DownRateBps: downRate,
				UpTotal:     up,
				DownTotal:   down,
				Conns:       conns,
				MemBytes:    int64(mgr.Memory()),
			})

			// Adaptive cadence
			if dUp+dDown > 0 {
				interval = fast
			} else if interval == fast {
				interval = slow
			}
			timer.Reset(interval)
		}
	}()
}
