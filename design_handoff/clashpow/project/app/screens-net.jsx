// screens-net.jsx — Connections + DNS + Logs

function ConnectionsScreen({ S }) {
  const [q, setQ] = React.useState('');
  const [filter, setFilter] = React.useState('all');
  const [, tick] = React.useState(0);
  React.useEffect(() => { const t = setInterval(() => tick((x) => x + 1), 1300); return () => clearInterval(t); }, []);

  const cat = (c) => c.node === 'DIRECT' ? 'direct' : c.node === 'REJECT' ? 'reject' : 'proxy';
  const rows = S.connections.filter((c) => {
    if (filter !== 'all' && cat(c) !== filter) return false;
    if (!q) return true;
    const s = (c.host + c.ip + c.proc + c.chain + c.rule).toLowerCase();
    return s.includes(q.toLowerCase());
  });
  const jit = (v) => Math.max(0, Math.round(v * (0.5 + Math.random())));

  const counts = {
    all: S.connections.length,
    proxy: S.connections.filter((c) => cat(c) === 'proxy').length,
    direct: S.connections.filter((c) => cat(c) === 'direct').length,
    reject: S.connections.filter((c) => cat(c) === 'reject').length,
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <PageHead title="连接监控" desc={`${S.connections.length} 个活跃连接 · 实时速率`}>
        <TBtn icon="x" label="全部断开" danger onClick={() => {}} />
      </PageHead>
      <div className="row-flex" style={{ marginBottom: 12, gap: 12 }}>
        <div className="search">
          <Icon name="search" size={14} />
          <input placeholder="搜索 域名 / IP / 进程 / 规则…" value={q} onChange={(e) => setQ(e.target.value)} />
          {q && <Icon name="x" size={13} style={{ cursor: 'pointer' }} onClick={() => setQ('')} />}
        </div>
        <div className="chips">
          {[['all', '全部'], ['proxy', '代理'], ['direct', '直连'], ['reject', '拒绝']].map(([k, lbl]) => (
            <button key={k} className={'chip' + (filter === k ? ' on' : '')} onClick={() => setFilter(k)}>
              {lbl} <span style={{ opacity: .7 }}>{counts[k]}</span>
            </button>
          ))}
        </div>
        <span style={{ flex: 1 }} />
        <span style={{ fontSize: 11, color: 'var(--text-faint)' }}>{rows.length} 条匹配</span>
      </div>

      <Card pad={false} style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
        <div className="scrollbox" style={{ overflow: 'auto', flex: 1 }}>
          <table className="tbl">
            <thead><tr>
              <th>目标</th><th>进程</th><th>类型</th><th>规则</th><th>代理链</th>
              <th className="num">↑ 速率</th><th className="num">↓ 速率</th><th className="num">总量</th>
            </tr></thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.id}>
                  <td>
                    <div style={{ fontWeight: 600 }}>{c.host}</div>
                    <div className="mono dim" style={{ fontSize: 10 }}>{c.ip}:{c.port}</div>
                  </td>
                  <td className="dim">{c.proc}</td>
                  <td><span className="proto-tag" style={{ color: c.net === 'UDP' ? 'var(--warn)' : 'var(--text-dim)' }}>{c.net}</span></td>
                  <td className="mono dim" style={{ fontSize: 10.5 }}>{c.rule}</td>
                  <td>
                    <span className="row-flex" style={{ gap: 6 }}>
                      <span style={{ fontSize: 11.5, fontWeight: 600,
                        color: c.node === 'REJECT' ? 'var(--bad)' : c.node === 'DIRECT' ? 'var(--text-dim)' : 'var(--accent)' }}>{c.chain}</span>
                      <span className="mono dim" style={{ fontSize: 10 }}>{c.node}</span>
                    </span>
                  </td>
                  <td className="num dim">{c.node === 'REJECT' ? '—' : fmtRate(jit(c.ulSpeed))}</td>
                  <td className="num" style={{ color: c.node === 'REJECT' ? 'var(--text-faint)' : 'var(--text)' }}>
                    {c.node === 'REJECT' ? '阻断' : fmtRate(jit(c.dlSpeed))}</td>
                  <td className="num dim">{fmtBytes(c.up + c.down)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

// ---------------- DNS ----------------
function DnsScreen({ S }) {
  const [fakeip, setFakeip] = React.useState(true);
  const [cache, setCache] = React.useState(DNS_CACHE);
  React.useEffect(() => {
    const t = setInterval(() => setCache((cs) => cs.map((c) => ({ ...c, ttl: c.ttl > 1 ? c.ttl - 1 : (c.direct ? 3600 : 300) }))), 1000);
    return () => clearInterval(t);
  }, []);
  const totalHits = cache.reduce((a, c) => a + c.hits, 0);

  return (
    <div>
      <PageHead title="DNS 缓存" desc="内置 DNS 服务器 · Fake‑IP 映射与缓存条目">
        <TBtn icon="refresh" label="刷新缓存" onClick={() => setCache(DNS_CACHE.map((c) => ({ ...c })))} />
        <TBtn icon="x" label="清空" onClick={() => setCache([])} />
      </PageHead>
      <div className="stat-grid" style={{ marginBottom: 'var(--gap)' }}>
        <StatCard label="缓存条目" value={cache.length} sub="内存常驻" />
        <StatCard label="Fake‑IP 池" value="198.18.0.0/15" sub={cache.filter((c) => !c.direct).length + ' 个已分配'} accent />
        <StatCard label="命中次数" value={totalHits.toLocaleString()} sub="缓存命中率 96.4%" />
        <StatCard label="平均解析" value="0.4" unit="ms" sub="DoH · 1.1.1.1" />
      </div>
      <Card title="DNS 模式" style={{ marginBottom: 'var(--gap)' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          <SwitchRow label="Fake‑IP 模式" hint="为代理域名返回保留段虚拟 IP，避免 DNS 泄漏" on={fakeip} onChange={setFakeip} />
          <SwitchRow label="DNS 劫持 (TUN)" hint="拦截 53 端口请求，强制走内置解析器" on={true} onChange={() => {}} />
          <SwitchRow label="分流 DNS" hint="国内域名走 UDP 223.5.5.5，国外走 DoH" on={true} onChange={() => {}} last />
        </div>
      </Card>
      <Card title={`缓存条目 (${cache.length})`} pad={false}>
        <div className="scrollbox" style={{ maxHeight: 360, overflow: 'auto' }}>
          <table className="tbl">
            <thead><tr><th>域名</th><th>Fake‑IP</th><th>真实 IP</th><th>类型</th><th>上游</th><th className="num">TTL</th><th className="num">命中</th></tr></thead>
            <tbody>
              {cache.map((c, i) => (
                <tr key={i}>
                  <td style={{ fontWeight: 600 }}>{c.host}</td>
                  <td className="mono" style={{ color: c.direct ? 'var(--text-faint)' : 'var(--accent)' }}>{c.fakeip}</td>
                  <td className="mono dim">{c.real}</td>
                  <td className="mono dim">{c.type}</td>
                  <td><span className="proto-tag" style={{ color: c.direct ? 'var(--text-dim)' : 'oklch(0.7 0.12 250)' }}>{c.src}</span></td>
                  <td className="num mono" style={{ color: c.ttl < 30 ? 'var(--warn)' : 'var(--text-dim)' }}>{c.ttl}s</td>
                  <td className="num mono dim">{c.hits}</td>
                </tr>
              ))}
              {!cache.length && <tr><td colSpan={7} style={{ textAlign: 'center', color: 'var(--text-faint)', padding: 28 }}>缓存为空</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

function SwitchRow({ label, hint, on, onChange, last }) {
  return (
    <div className="form-row" style={last ? { borderBottom: 'none' } : null}>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 13, fontWeight: 600 }}>{label}</div>
        {hint && <div style={{ fontSize: 11, color: 'var(--text-faint)', marginTop: 2 }}>{hint}</div>}
      </div>
      <Toggle on={on} onChange={onChange} />
    </div>
  );
}

// ---------------- LOGS ----------------
let LOG_ID = 0;
function LogsScreen({ S }) {
  const [logs, setLogs] = React.useState(() => seedLogs(40));
  const [paused, setPaused] = React.useState(false);
  const [level, setLevel] = React.useState('all');
  const [q, setQ] = React.useState('');
  const boxRef = React.useRef(null);
  const stick = React.useRef(true);

  React.useEffect(() => {
    if (paused) return;
    const t = setInterval(() => setLogs((ls) => [...ls.slice(-220), makeLog()]), 750);
    return () => clearInterval(t);
  }, [paused]);

  React.useLayoutEffect(() => {
    const el = boxRef.current; if (el && stick.current) el.scrollTop = el.scrollHeight;
  });
  const onScroll = () => {
    const el = boxRef.current; if (!el) return;
    stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  };

  const shown = logs.filter((l) => (level === 'all' || l.lvl === level) && (!q || l.msg.toLowerCase().includes(q.toLowerCase())));

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <PageHead title="日志" desc="结构化日志 · 经 Unix Domain Socket 流式推送">
        <TBtn icon={paused ? 'playfill' : 'pause'} label={paused ? '继续' : '暂停'} active={paused} onClick={() => setPaused((p) => !p)} />
        <TBtn icon="x" label="清空" onClick={() => setLogs([])} />
        <TBtn icon="cloud" label="导出" onClick={() => {}} />
      </PageHead>
      <div className="row-flex" style={{ marginBottom: 12, gap: 12 }}>
        <div className="search" style={{ minWidth: 240 }}>
          <Icon name="search" size={14} />
          <input placeholder="过滤日志内容…" value={q} onChange={(e) => setQ(e.target.value)} />
        </div>
        <div className="chips">
          {[['all', '全部'], ['info', 'INFO'], ['debug', 'DEBUG'], ['warning', 'WARN'], ['error', 'ERROR']].map(([k, lbl]) => (
            <button key={k} className={'chip' + (level === k ? ' on' : '')} onClick={() => setLevel(k)}>{lbl}</button>
          ))}
        </div>
        <span style={{ flex: 1 }} />
        <span className="row-flex" style={{ fontSize: 11, color: 'var(--text-faint)', gap: 6 }}>
          <Dot color={paused ? 'var(--text-faint)' : 'var(--accent)'} pulse={!paused} />{paused ? '已暂停' : '实时'} · {shown.length} 行
        </span>
      </div>
      <div ref={boxRef} onScroll={onScroll} className="log-stream scrollbox" style={{ flex: 1 }}>
        {shown.map((l) => (
          <div className="log-line" key={l.id}>
            <span className="log-time">{l.time}</span>
            <span className={'log-lvl lvl-' + l.lvl}>{l.lvl.toUpperCase()}</span>
            <span className="log-msg">{l.msg}</span>
          </div>
        ))}
        {!shown.length && <div style={{ color: 'var(--text-faint)', padding: 20 }}>无匹配日志</div>}
      </div>
    </div>
  );
}

function ts() { const d = new Date(); return d.toTimeString().slice(0, 8) + '.' + String(d.getMilliseconds()).padStart(3, '0'); }
function makeLog() {
  const [lvl, tpl] = LOG_TEMPLATES[Math.floor(Math.random() * LOG_TEMPLATES.length)];
  const h = HOSTS_FOR_LOG[Math.floor(Math.random() * HOSTS_FOR_LOG.length)];
  const msg = tpl.replace('{h}', h).replace('{n}', Math.floor(Math.random() * 250)).replace('{x}', Math.floor(Math.random() * 65535).toString(16));
  return { id: ++LOG_ID, time: ts(), lvl, msg };
}
function seedLogs(n) {
  const arr = Array.from({ length: n }, makeLog);
  const base = Date.now() - n * 750;
  arr.forEach((l, i) => { const d = new Date(base + i * 750); l.time = d.toTimeString().slice(0, 8) + '.' + String(d.getMilliseconds()).padStart(3, '0'); });
  return arr;
}
const HOSTS_FOR_LOG = ['raw.githubusercontent.com', 'api.openai.com', 'i.ytimg.com', 't.me', 'dn.figma.com', 'speed.cloudflare.com', 'registry-1.docker.io'];

Object.assign(window, { ConnectionsScreen, DnsScreen, LogsScreen });
