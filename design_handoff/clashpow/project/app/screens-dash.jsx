// screens-dash.jsx — Dashboard + Proxies

function DashboardScreen({ S }) {
  const m = S.traffic;
  const dl = m.down[m.down.length - 1];
  const ul = m.up[m.up.length - 1];
  const conns = S.connections.length;

  const outbounds = [
    { id: 'hk01', name: '香港 IEPL 01', region: 'HK', share: 0.46, series: m.down.slice(-40).map((v) => v * 0.46) },
    { id: 'sg01', name: '新加坡 IPLC 01', region: 'SG', share: 0.28, series: m.down.slice(-40).map((v) => v * 0.28) },
    { id: 'us01', name: '美国 洛杉矶 01', region: 'US', share: 0.16, series: m.down.slice(-40).map((v) => v * 0.16) },
    { id: 'DIRECT', name: '直连', region: null, share: 0.10, series: m.down.slice(-40).map((v) => v * 0.10) },
  ];

  return (
    <div>
      <PageHead title="仪表盘" desc="实时转发、引擎与系统能效一览">
        <Seg value={S.mode} onChange={S.setMode} options={[
          { v: 'rule', label: '规则', icon: 'sliders' },
          { v: 'global', label: '全局', icon: 'globe' },
          { v: 'direct', label: '直连', icon: 'compass' },
        ]} />
        <TBtn icon={S.running ? 'pause' : 'playfill'} label={S.running ? '暂停代理' : '恢复代理'}
          active={!S.running} onClick={S.togglePause} />
      </PageHead>

      <div className="stat-grid" style={{ marginBottom: 'var(--gap)' }}>
        <StatCard label="实时下载" value={fmtRate(dl).split(' ')[0]} unit={fmtRate(dl).split(' ')[1]} accent
          sub={'▼ ' + fmtBytes(STATS.totalDown) + ' 累计'} />
        <StatCard label="实时上传" value={fmtRate(ul).split(' ')[0]} unit={fmtRate(ul).split(' ')[1]}
          sub={'▲ ' + fmtBytes(STATS.totalUp) + ' 累计'} />
        <StatCard label="活跃连接" value={conns} sub={'TCP ' + Math.round(conns * 0.78) + ' · UDP ' + Math.round(conns * 0.22)} />
        <StatCard label="转发延迟 P99" value={STATS.fwdLatency} unit="ms" sub={'吞吐 ' + STATS.throughput + ' Gbps'} />
      </div>

      <div className="grid2" style={{ marginBottom: 'var(--gap)' }}>
        <Card title="实时流量 · Metal 120 fps" pad={false}
          right={<div className="row-flex" style={{ fontSize: 11 }}>
            <span className="row-flex" style={{ gap: 5 }}><Dot color="var(--accent)" />下载</span>
            <span className="row-flex" style={{ gap: 5 }}><Dot color="oklch(0.7 0.13 250)" />上传</span>
          </div>}>
          <div style={{ padding: '6px 8px' }}>
            <TrafficChart model={m} accent={accentHex(S.accent)} accent2="#5b8cff"
              grid="var(--border)" text="var(--text-faint)" height={236} />
          </div>
        </Card>
        <Card title="引擎 · 系统能效">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 11 }}>
            <Vital label="内存占用" value={(STATS.memEngine + STATS.memGui)} unit="MB"
              detail={`引擎 ${STATS.memEngine} · GUI ${STATS.memGui}`} pct={(STATS.memEngine + STATS.memGui) / 180} />
            <Vital label="整机功耗增量" value={STATS.power} unit="mW" detail="空载 ≤ 20 mW 目标" pct={STATS.power / 20} good />
            <Vital label="UI 帧率" value={STATS.fps} unit="fps" detail="Metal HUD · 无掉帧" pct={1} good />
            <Vital label="规则集" value={STATS.ruleCount.toLocaleString()} unit="条" detail={`mmap 加载 ${STATS.ruleLoadMs} ms`} pct={0.62} />
            <div className="form-row" style={{ borderBottom: 'none', paddingBottom: 0 }}>
              <span style={{ color: 'var(--text-dim)', fontSize: 12 }}>运行时长</span>
              <span style={{ flex: 1 }} />
              <span className="mono" style={{ fontSize: 12 }}>{STATS.uptime}</span>
            </div>
          </div>
        </Card>
      </div>

      <div className="grid2">
        <Card title="当前链路" right={<span className="pg-kind">{({ rule: '规则模式', global: '全局模式', direct: '直连模式' })[S.mode]}</span>}>
          <ChainView S={S} />
        </Card>
        <Card title="出口流量分布">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            {outbounds.map((o) => (
              <div key={o.id} className="row-flex" style={{ padding: '5px 2px' }}>
                <RegionChip region={o.region} />
                <span style={{ fontSize: 12, fontWeight: 600 }}>{o.name}</span>
                <span style={{ flex: 1 }} />
                <Sparkline values={o.series} color={accentHex(S.accent)} w={70} h={20} />
                <span className="mono" style={{ fontSize: 11, color: 'var(--text-dim)', width: 38, textAlign: 'right' }}>
                  {Math.round(o.share * 100)}%</span>
              </div>
            ))}
          </div>
        </Card>
      </div>
    </div>
  );
}

function Vital({ label, value, unit, detail, pct, good }) {
  return (
    <div>
      <div className="row-flex" style={{ marginBottom: 4 }}>
        <span style={{ fontSize: 12, color: 'var(--text-dim)', fontWeight: 600 }}>{label}</span>
        <span style={{ flex: 1 }} />
        <span style={{ fontSize: 13, fontWeight: 700 }}>{value}<span className="stat-unit">{unit}</span></span>
      </div>
      <div style={{ height: 5, borderRadius: 3, background: 'var(--input)', overflow: 'hidden' }}>
        <div style={{ width: Math.min(100, pct * 100) + '%', height: '100%', borderRadius: 3,
          background: good ? 'var(--good)' : 'var(--accent)' }} />
      </div>
      <div style={{ fontSize: 10, color: 'var(--text-faint)', marginTop: 3, fontFamily: 'var(--mono)' }}>{detail}</div>
    </div>
  );
}

function ChainView({ S }) {
  // resolve a representative chain: 节点选择 -> 自动选择 -> hk01
  const sel = S.sel['g_select'];
  const chain = [];
  let cur = sel; let guard = 0;
  while (cur && guard++ < 6) {
    const g = GROUPS.find((x) => x.id === cur);
    if (g) { chain.push({ kind: 'group', name: g.name }); cur = S.sel[g.id]; }
    else { const n = resolveProxy(cur); chain.push({ kind: 'node', node: n }); break; }
  }
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
      <span className="pg-ico" style={{ width: 24, height: 24 }}><Icon name="globe" size={14} /></span>
      <span style={{ fontSize: 12, color: 'var(--text-dim)' }}>本机</span>
      {chain.map((c, i) => (
        <React.Fragment key={i}>
          <Icon name="chevR" size={13} style={{ color: 'var(--text-faint)' }} />
          {c.kind === 'group'
            ? <span className="route-cidr" style={{ color: 'var(--text)' }}>{c.name}</span>
            : <span className="row-flex" style={{ gap: 6 }}>
                <RegionChip region={c.node.region} />
                <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--accent)' }}>{c.node.name}</span>
                <LatencyBadge ms={S.lat[c.node.id]} />
              </span>}
        </React.Fragment>
      ))}
      <Icon name="chevR" size={13} style={{ color: 'var(--text-faint)' }} />
      <span style={{ fontSize: 12, color: 'var(--text-dim)' }}>目标</span>
    </div>
  );
}

// ---------------- PROXIES ----------------
function ProxiesScreen({ S }) {
  const [open, setOpen] = React.useState({ g_select: true, g_auto: true });
  const testGroup = (g) => S.testNodes(g.members.filter((id) => NODE_BY_ID[id]));

  return (
    <div>
      <PageHead title="代理" desc="代理组与节点 · 点击切换，闪电图标测速">
        <TBtn icon="bolt" label="全部测速" accent onClick={() => S.testNodes(NODES.map((n) => n.id))} />
        <TBtn icon="refresh" label="刷新" onClick={() => {}} />
      </PageHead>

      {GROUPS.map((g) => {
        const isOpen = open[g.id];
        const nowId = S.sel[g.id] || g.now;
        const nowP = resolveProxy(nowId);
        return (
          <div className="pg-card" key={g.id}>
            <div className="pg-head" onClick={() => setOpen({ ...open, [g.id]: !isOpen })}>
              <span className="pg-ico"><Icon name={g.icon} size={16} /></span>
              <div>
                <div className="row-flex" style={{ gap: 8 }}>
                  <span className="pg-name">{g.name}</span>
                  <span className="pg-kind">{g.kind}</span>
                </div>
                <div className="pg-now">当前 · <b>{nowP.name}</b>{g.members.length ? ` · ${g.members.length} 个节点` : ''}</div>
              </div>
              <span style={{ flex: 1 }} />
              <button className="icon-btn" onClick={(e) => { e.stopPropagation(); testGroup(g); }} title="组内测速">
                <Icon name="bolt" size={14} />
              </button>
              <Icon name={isOpen ? 'chevD' : 'chevR'} size={16} style={{ color: 'var(--text-faint)' }} />
            </div>
            {isOpen && (
              <div className="pg-grid">
                {g.members.map((id) => {
                  const p = resolveProxy(id);
                  const on = nowId === id;
                  const testing = S.testing.has(id);
                  return (
                    <div key={id} className={'node' + (on ? ' on' : '')}
                      onClick={() => S.selectNode(g.id, id)}>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div className="node-name">{p.name}</div>
                        <div className="node-meta">
                          {p.region && <RegionChip region={p.region} />}
                          <ProtoTag type={p.type} />
                          {!p.isGroup && <LatencyBadge ms={S.lat[id]} testing={testing} />}
                          {p.isGroup && <span className="lat" style={{ color: 'var(--text-faint)' }}>↳ {resolveProxy(S.sel[id] || p.now).name}</span>}
                        </div>
                      </div>
                      {on && <span className="node-check"><Icon name="check" size={15} /></span>}
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

Object.assign(window, { DashboardScreen, ProxiesScreen });
