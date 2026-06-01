// ui.jsx — shared UI atoms

function latColor(ms) {
  if (ms == null) return 'var(--text-faint)';
  if (ms <= 0) return 'var(--text-faint)';
  if (ms < 80) return 'var(--good)';
  if (ms < 160) return 'var(--warn)';
  return 'var(--bad)';
}

function LatencyBadge({ ms, testing }) {
  if (testing) return <span className="lat lat-testing">测速中…</span>;
  if (ms == null) return <span className="lat" style={{ color: 'var(--text-faint)' }}>—</span>;
  return <span className="lat" style={{ color: latColor(ms) }}>{ms} ms</span>;
}

function RegionChip({ region }) {
  if (!region) return null;
  const r = REGIONS[region];
  const hue = r ? r.hue : 200;
  return (
    <span className="region-chip" style={{
      color: `oklch(0.72 0.15 ${hue})`,
      background: `oklch(0.72 0.15 ${hue} / 0.14)`,
      borderColor: `oklch(0.72 0.15 ${hue} / 0.30)`,
    }}>{region}</span>
  );
}

const PROTO_HUE = {
  Trojan: 25, VMess: 200, VLESS: 265, Shadowsocks: 150, Hysteria2: 320,
  TUIC: 300, WireGuard: 100, Direct: 145, Reject: 25, Group: 220,
};
function ProtoTag({ type }) {
  const hue = PROTO_HUE[type] ?? 220;
  return <span className="proto-tag" style={{ color: `oklch(0.7 0.04 ${hue})` }}>{type}</span>;
}

function Toggle({ on, onChange, size = 'md' }) {
  const W = size === 'sm' ? 30 : 38, H = size === 'sm' ? 18 : 22, D = H - 4;
  return (
    <button className="toggle" onClick={() => onChange(!on)} style={{
      width: W, height: H, borderRadius: H,
      background: on ? 'var(--accent)' : 'var(--toggle-off)',
    }} aria-pressed={on}>
      <span style={{
        width: D, height: D, borderRadius: '50%', background: '#fff',
        transform: `translateX(${on ? W - H : 0}px)`,
        transition: 'transform .18s cubic-bezier(.3,.9,.4,1)',
        boxShadow: '0 1px 2px rgba(0,0,0,0.3)',
      }} />
    </button>
  );
}

function StatCard({ label, value, unit, sub, accent, children }) {
  return (
    <div className="stat-card">
      <div className="stat-label">{label}</div>
      <div className="stat-value" style={accent ? { color: 'var(--accent)' } : null}>
        {value}{unit && <span className="stat-unit">{unit}</span>}
      </div>
      {sub && <div className="stat-sub">{sub}</div>}
      {children}
    </div>
  );
}

function Card({ title, right, children, pad = true, style }) {
  return (
    <div className="card" style={style}>
      {title && (
        <div className="card-head">
          <span className="card-title">{title}</span>
          <span style={{ flex: 1 }} />
          {right}
        </div>
      )}
      <div style={pad ? { padding: 12 } : null}>{children}</div>
    </div>
  );
}

function TBtn({ icon, label, on, active, onClick, danger, accent }) {
  return (
    <button className={'tbtn' + (active ? ' tbtn-active' : '')} onClick={onClick}
      style={danger ? { color: 'var(--bad)' } : accent ? { color: 'var(--accent)' } : null}>
      {icon && <Icon name={icon} size={14} />}
      {label && <span>{label}</span>}
    </button>
  );
}

function Seg({ options, value, onChange }) {
  return (
    <div className="seg">
      {options.map((o) => (
        <button key={o.v} className={'seg-item' + (value === o.v ? ' seg-on' : '')}
          onClick={() => onChange(o.v)}>
          {o.icon && <Icon name={o.icon} size={13} />}
          {o.label}
        </button>
      ))}
    </div>
  );
}

function PageHead({ title, desc, children }) {
  return (
    <div className="page-head">
      <div>
        <h1>{title}</h1>
        {desc && <p>{desc}</p>}
      </div>
      <span style={{ flex: 1 }} />
      <div className="page-head-actions">{children}</div>
    </div>
  );
}

function Dot({ color, pulse }) {
  return <span className={'sdot' + (pulse ? ' pulse' : '')} style={{ background: color }} />;
}

Object.assign(window, {
  latColor, LatencyBadge, RegionChip, ProtoTag, Toggle, StatCard,
  Card, TBtn, Seg, PageHead, Dot,
});

async function copyText(txt, toast) {
  let ok = false;
  try { await navigator.clipboard.writeText(txt); ok = true; } catch (e) {}
  if (!ok) {
    const ta = document.createElement('textarea');
    ta.value = txt; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.focus(); ta.select();
    try { document.execCommand('copy'); ok = true; } catch (e) {}
    document.body.removeChild(ta);
  }
  if (toast) toast('已复制 · ' + (txt.length > 46 ? txt.slice(0, 46) + '…' : txt));
}
window.copyText = copyText;
