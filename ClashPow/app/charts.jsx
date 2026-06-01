// charts.jsx — canvas-based live traffic graph + sparkline

// Shared rolling traffic model so dashboard graph + menubar mini agree.
function useTrafficModel(running) {
  const ref = React.useRef({
    down: Array(180).fill(0).map(() => 2.0e6 + Math.random() * 1.2e6),
    up: Array(180).fill(0).map(() => 4.0e5 + Math.random() * 3e5),
    t: 0,
  });
  const [, tick] = React.useState(0);
  React.useEffect(() => {
    let raf, last = performance.now(), n = 0;
    const loop = (now) => {
      raf = requestAnimationFrame(loop);
      if (now - last < 100) return; // 10Hz data push
      last = now;
      const m = ref.current;
      if (running) {
        m.t += 1;
        const wobble = (base, amp, prev) => {
          const target = base + Math.sin(m.t / 7) * amp * 0.5 + (Math.random() - 0.5) * amp;
          return Math.max(0, prev * 0.6 + target * 0.4);
        };
        const burst = Math.random() < 0.06 ? 1 : 0;
        m.down.push(wobble(2.6e6, 1.6e6, m.down[m.down.length - 1]) + burst * 5e6);
        m.up.push(wobble(5e5, 4e5, m.up[m.up.length - 1]) + burst * 8e5);
      } else {
        m.down.push(m.down[m.down.length - 1] * 0.82);
        m.up.push(m.up[m.up.length - 1] * 0.82);
      }
      m.down.shift(); m.up.shift();
      if (++n % 3 === 0) tick((x) => (x + 1) % 1e6); // ~3Hz numeric refresh
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, [running]);
  return ref.current;
}

function fmtRate(bps) {
  if (bps >= 1e9) return (bps / 1e9).toFixed(2) + ' GB/s';
  if (bps >= 1e6) return (bps / 1e6).toFixed(1) + ' MB/s';
  if (bps >= 1e3) return (bps / 1e3).toFixed(0) + ' KB/s';
  return Math.round(bps) + ' B/s';
}
function fmtBytes(b) {
  if (b >= 1e12) return (b / 1e12).toFixed(2) + ' TB';
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' GB';
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB';
  if (b >= 1e3) return (b / 1e3).toFixed(0) + ' KB';
  return b + ' B';
}

function TrafficChart({ model, accent, accent2, grid, text, height = 220 }) {
  const cv = React.useRef(null);
  const props = React.useRef({});
  props.current = { accent, accent2, grid, text };
  React.useEffect(() => {
    const canvas = cv.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    let raf;
    const draw = () => {
    raf = requestAnimationFrame(draw);
    const { accent, accent2, grid, text } = props.current;
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) { canvas.width = w * dpr; canvas.height = h * dpr; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const data = model.down, data2 = model.up;
    const cs = getComputedStyle(canvas);
    const gridC = (cs.getPropertyValue('--border') || 'rgba(255,255,255,0.08)').trim();
    const textC = (cs.getPropertyValue('--text-faint') || 'rgba(255,255,255,0.3)').trim();
    const peak = Math.max(6e6, ...data, ...data2) * 1.15;
    const padB = 18, padT = 8;
    const plotH = h - padB - padT;
    const xAt = (i) => (i / (data.length - 1)) * w;
    const yAt = (v) => padT + plotH - (v / peak) * plotH;

    // grid
    ctx.strokeStyle = gridC; ctx.lineWidth = 1; ctx.font = '10px ui-monospace, monospace';
    ctx.fillStyle = textC; ctx.textBaseline = 'middle';
    for (let g = 0; g <= 3; g++) {
      const y = padT + (plotH / 3) * g;
      ctx.globalAlpha = 0.5; ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
      ctx.globalAlpha = 0.6;
      ctx.fillText(fmtRate(peak * (1 - g / 3)), 4, y - 6);
    }
    ctx.globalAlpha = 1;

    const drawSeries = (arr, color) => {
      // area
      const grad = ctx.createLinearGradient(0, padT, 0, h - padB);
      grad.addColorStop(0, color + '55');
      grad.addColorStop(1, color + '00');
      ctx.beginPath();
      ctx.moveTo(0, h - padB);
      arr.forEach((v, i) => ctx.lineTo(xAt(i), yAt(v)));
      ctx.lineTo(w, h - padB); ctx.closePath();
      ctx.fillStyle = grad; ctx.fill();
      // line
      ctx.beginPath();
      arr.forEach((v, i) => (i ? ctx.lineTo(xAt(i), yAt(v)) : ctx.moveTo(xAt(i), yAt(v))));
      ctx.strokeStyle = color; ctx.lineWidth = 1.8;
      ctx.shadowColor = color; ctx.shadowBlur = 6; ctx.stroke(); ctx.shadowBlur = 0;
      // head dot
      const lx = xAt(arr.length - 1), ly = yAt(arr[arr.length - 1]);
      ctx.beginPath(); ctx.arc(lx, ly, 2.6, 0, 7); ctx.fillStyle = color; ctx.fill();
    };
    drawSeries(data2, accent2);
    drawSeries(data, accent);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, []);
  return <canvas ref={cv} style={{ width: '100%', height, display: 'block' }} />;
}

function Sparkline({ values, color, w = 80, h = 22 }) {
  const cv = React.useRef(null);
  React.useEffect(() => {
    const c = cv.current; if (!c) return;
    const ctx = c.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    c.width = w * dpr; c.height = h * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    const peak = Math.max(1, ...values) * 1.1;
    ctx.beginPath();
    values.forEach((v, i) => {
      const x = (i / (values.length - 1)) * w;
      const y = h - (v / peak) * (h - 2) - 1;
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    });
    ctx.strokeStyle = color; ctx.lineWidth = 1.4; ctx.stroke();
  });
  return <canvas ref={cv} style={{ width: w, height: h, display: 'block' }} />;
}

Object.assign(window, { useTrafficModel, TrafficChart, Sparkline, fmtRate, fmtBytes });
