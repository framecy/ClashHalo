// sampler.go — high-resolution stats sampling loop.
//
// Reads mihomo's in-process statistic manager and publishes samples to the
// mmap'd shared file for the GUI's Metal chart. Adaptive cadence: fast while
// traffic flows, slow when idle (power saving, per spec "10ms 负载 / 1s 空闲").

package main

import (
	"encoding/json"
	"net/http"
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

// startExternalStatsSampler samples an external kernel's controller (HTTP GET
// /connections returns a full snapshot incl. totals + memory) and writes the
// mmap stats file, so the GUI's Metal chart works in supervisor mode too.
func startExternalStatsSampler(p *stats.Pusher, ctlAddr, secret string) {
	go func() {
		client := &http.Client{Timeout: 3 * time.Second}
		url := "http://" + ctlAddr + "/connections"
		var lastUp, lastDown int64
		var lastT = time.Now()
		for {
			time.Sleep(500 * time.Millisecond)
			req, err := http.NewRequest("GET", url, nil)
			if err != nil {
				continue
			}
			if secret != "" {
				req.Header.Set("Authorization", "Bearer "+secret)
			}
			resp, err := client.Do(req)
			if err != nil {
				continue
			}
			var snap struct {
				DownloadTotal int64 `json:"downloadTotal"`
				UploadTotal   int64 `json:"uploadTotal"`
				Memory        int64 `json:"memory"`
				Connections   []struct{} `json:"connections"`
			}
			err = json.NewDecoder(resp.Body).Decode(&snap)
			resp.Body.Close()
			if err != nil {
				continue
			}
			now := time.Now()
			dt := now.Sub(lastT).Seconds()
			if dt <= 0 {
				dt = 0.5
			}
			upRate := int64(float64(snap.UploadTotal-lastUp) / dt)
			downRate := int64(float64(snap.DownloadTotal-lastDown) / dt)
			if upRate < 0 {
				upRate = 0
			}
			if downRate < 0 {
				downRate = 0
			}
			lastUp, lastDown, lastT = snap.UploadTotal, snap.DownloadTotal, now
			p.Push(stats.Sample{
				TsUnixNano:  now.UnixNano(),
				UpRateBps:   upRate,
				DownRateBps: downRate,
				UpTotal:     snap.UploadTotal,
				DownTotal:   snap.DownloadTotal,
				Conns:       int32(len(snap.Connections)),
				MemBytes:    snap.Memory,
			})
		}
	}()
}
