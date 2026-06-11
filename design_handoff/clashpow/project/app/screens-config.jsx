// screens-config.jsx — Config editor (YAML <-> form), Subscriptions, MenuBar panel

const CFG_DEFAULT = {
  'mixed-port': 7890, 'socks-port': 7891, 'allow-lan': false, mode: 'rule',
  'log-level': 'info', ipv6: true,
  tun_enable: true, tun_stack: 'gvisor', tun_autoroute: false,
  dns_enable: true, dns_mode: 'fake-ip', sniffer: true,
};

function buildYaml(c, profile) {
  return [
    ['c', `# ClashPow · 配置文件「${profile ? profile.name : '默认'}」 · ${profile && profile.source === 'remote' ? '远程订阅' : '本地导入'}`],
    ['c', `# 来源: ${profile ? profile.from : '—'}`],
    ['kv', 'mixed-port', c['mixed-port'], 'n'],
    ['kv', 'socks-port', c['socks-port'], 'n'],
    ['kv', 'allow-lan', String(c['allow-lan']), 'd'],
    ['kv', 'mode', c.mode, 'v'],
    ['kv', 'log-level', c['log-level'], 'v'],
    ['kv', 'ipv6', String(c.ipv6), 'd'],
    ['blank'],
    ['k', 'tun:'],
    ['kv2', 'enable', String(c.tun_enable), 'd'],
    ['kv2', 'stack', c.tun_stack, 'v'],
    ['kv2', 'auto-route', String(c.tun_autoroute), 'd'],
    ['kv2', 'auto-detect-interface', 'true', 'd'],
    ['kv2', 'device', 'utun4', 'v', '  # 用户态 UTUN，与 SD-WAN 无冲突'],
    ['blank'],
    ['k', 'dns:'],
    ['kv2', 'enable', String(c.dns_enable), 'd'],
    ['kv2', 'enhanced-mode', c.dns_mode, 'v'],
    ['kv2', 'fake-ip-range', '198.18.0.1/15', 'v'],
    ['l2', 'nameserver:'],
    ['li', 'https://1.1.1.1/dns-query'],
    ['li', 'tls://8.8.8.8'],
    ['blank'],
    ['k', 'sniffer:'],
    ['kv2', 'enable', String(c.sniffer), 'd'],
    ['l2', 'sniff:', '  # HTTP / TLS / QUIC'],
    ['li2', 'TLS', 'QUIC', 'HTTP'],
    ['blank'],
    ['k', 'profile:'],
    ['kv2', 'store-selected', 'true', 'd'],
    ['kv2', 'rule-mmap', 'true', 'd', '  # 预编译二进制规则 mmap 加载'],
  ];
}

function YamlView({ cfg, profile }) {
  const lines = buildYaml(cfg, profile);
  return (
    <div className="yaml scrollbox" style={{ height: 'auto', minHeight: 440 }}>
      {lines.map((ln, i) => {
        if (ln[0] === 'blank') return <div key={i}>&nbsp;</div>;
        if (ln[0] === 'c') return <div key={i}><span className="yc">{ln[1]}</span></div>;
        if (ln[0] === 'k') return <div key={i}><span className="yk">{ln[1]}</span></div>;
        if (ln[0] === 'kv') return <div key={i}><span className="yk">{ln[1]}</span>: <span className={'y' + ln[3]}>{ln[2]}</span>{ln[4] && <span className="yc">{ln[4]}</span>}</div>;
        if (ln[0] === 'kv2') return <div key={i}>{'  '}<span className="yk">{ln[1]}</span>: <span className={'y' + ln[3]}>{ln[2]}</span>{ln[4] && <span className="yc">{ln[4]}</span>}</div>;
        if (ln[0] === 'l2') return <div key={i}>{'  '}<span className="yk">{ln[1]}</span>{ln[2] && <span className="yc">{ln[2]}</span>}</div>;
        if (ln[0] === 'li') return <div key={i}>{'    '}- <span className="yv">{ln[1]}</span></div>;
        if (ln[0] === 'li2') return <div key={i}>{'    '}- {ln.slice(1).map((x, j) => (<React.Fragment key={j}>{j ? ', ' : ''}<span className="yv">{x}</span></React.Fragment>))}</div>;
        return null;
      })}
    </div>
  );
}

let IMPORT_N = 0;
function ConfigScreen({ S }) {
  const [view, setView] = React.useState('form');
  const [profiles, setProfiles] = React.useState(PROFILES);
  const [activeId, setActiveId] = React.useState('p1');
  const [selectedId, setSelectedId] = React.useState('p1');
  const [cfgs, setCfgs] = React.useState(() => Object.fromEntries(PROFILES.map((p) => [p.id, { ...CFG_DEFAULT, ...(p.cfg || {}) }])));
  const [url, setUrl] = React.useState('');

  const cfg = cfgs[selectedId] || CFG_DEFAULT;
  const profile = profiles.find((p) => p.id === selectedId);
  const set = (k, v) => setCfgs((m) => ({ ...m, [selectedId]: { ...m[selectedId], [k]: v } }));

  const addProfile = (p) => {
    setProfiles((ps) => [...ps, p]);
    setCfgs((m) => ({ ...m, [p.id]: { ...CFG_DEFAULT, ...(p.cfg || {}) } }));
    setSelectedId(p.id);
  };
  const importRemote = () => {
    const u = url.trim(); if (!u) { S.toast('请输入订阅链接'); return; }
    const id = 'imp' + (++IMPORT_N);
    let host = u; try { host = new URL(u).hostname; } catch (e) {}
    addProfile({ id, name: host || '远程订阅', source: 'remote', from: u, nodes: 12 + Math.floor(Math.random() * 60), size: (20 + Math.floor(Math.random() * 200)) + ' KB', updated: '刚刚', interval: 24, cfg: {} });
    setUrl('');
    S.toast('已拉取并解析订阅 · 新增配置文件');
  };
  const importLocal = () => {
    const id = 'imp' + (++IMPORT_N);
    addProfile({ id, name: 'config-' + (IMPORT_N) + '.yaml', source: 'local', from: '~/Downloads/config-' + IMPORT_N + '.yaml', nodes: 8, size: '18 KB', updated: '刚刚', cfg: {} });
    S.toast('已从本地文件导入配置');
  };
  const activate = (id) => {
    setActiveId(id); setSelectedId(id);
    S.toast('已切换生效配置「' + profiles.find((p) => p.id === id).name + '」并热重载');
  };
  const removeProfile = (id) => {
    if (id === activeId) { S.toast('无法删除生效中的配置'); return; }
    setProfiles((ps) => ps.filter((p) => p.id !== id));
    if (selectedId === id) setSelectedId(activeId);
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <PageHead title="配置编辑" desc="多配置选择 · 远程订阅 / 本地导入 · 表单与 YAML 双向同步">
        <Seg value={view} onChange={setView} options={[
          { v: 'form', label: '表单', icon: 'form' },
          { v: 'yaml', label: 'YAML', icon: 'code' },
        ]} />
        <span className="row-flex" style={{ gap: 6, fontSize: 11, color: 'var(--good)' }}><Icon name="check" size={14} />校验通过</span>
        <TBtn icon="check" accent label="应用并热重载" onClick={() => activate(selectedId)} />
      </PageHead>

      <div className="scrollbox" style={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
        {/* ---- multi-config profile selector + import ---- */}
        <Card title="配置文件 · 多配置选择" style={{ marginBottom: 'var(--gap)' }}
          right={<span style={{ fontSize: 11, color: 'var(--text-faint)' }}>{profiles.length} 个配置</span>}>
          <div className="import-row">
            <div className="search" style={{ flex: 1, minWidth: 0 }}>
              <Icon name="cloud" size={14} />
              <input placeholder="粘贴远程订阅链接 (https://…/clash)" value={url}
                onChange={(e) => setUrl(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && importRemote()} />
            </div>
            <TBtn icon="cloud" accent label="导入订阅" onClick={importRemote} />
            <TBtn icon="form" label="本地导入" onClick={importLocal} />
          </div>
          <div className="prof-grid">
            {profiles.map((p) => (
              <ProfileCard key={p.id} p={p} active={activeId === p.id} selected={selectedId === p.id}
                onSelect={() => setSelectedId(p.id)} onActivate={() => activate(p.id)}
                onRefresh={() => S.toast('已更新「' + p.name + '」(' + p.nodes + ' 节点)')}
                onRemove={() => removeProfile(p.id)} />
            ))}
          </div>
        </Card>

        {/* ---- editor for the selected profile ---- */}
        <div className="row-flex" style={{ marginBottom: 8, gap: 8 }}>
          <Icon name={profile && profile.source === 'remote' ? 'cloud' : 'form'} size={14} style={{ color: 'var(--accent)' }} />
          <span style={{ fontSize: 12.5, fontWeight: 700 }}>正在编辑 · {profile ? profile.name : '—'}</span>
          {activeId === selectedId
            ? <span className="iface-tag" style={{ color: 'var(--accent)', background: 'color-mix(in oklch, var(--accent) 16%, transparent)' }}>生效中</span>
            : <span className="iface-tag" style={{ color: 'var(--text-dim)', background: 'var(--elev)' }}>未生效 · 编辑后点「应用」切换</span>}
        </div>

        {view === 'yaml'
          ? <YamlView cfg={cfg} profile={profile} />
          : <div>
              <div className="grid-half">
                <Card title="入站 / 基础">
                  <FormNum label="混合端口" k="mixed-port" v={cfg['mixed-port']} on={(x) => set('mixed-port', x)} />
                  <FormNum label="SOCKS 端口" k="socks-port" v={cfg['socks-port']} on={(x) => set('socks-port', x)} />
                  <FormSel label="运行模式" k="mode" v={cfg.mode} on={(x) => set('mode', x)} opts={[['rule', '规则'], ['global', '全局'], ['direct', '直连']]} />
                  <FormSel label="日志级别" k="log-level" v={cfg['log-level']} on={(x) => set('log-level', x)} opts={[['info', 'info'], ['debug', 'debug'], ['warning', 'warning'], ['error', 'error'], ['silent', 'silent']]} />
                  <FormTog label="允许局域网" k="allow-lan" v={cfg['allow-lan']} on={(x) => set('allow-lan', x)} />
                  <FormTog label="启用 IPv6" k="ipv6" v={cfg.ipv6} on={(x) => set('ipv6', x)} last />
                </Card>
                <Card title="TUN 入站">
                  <FormTog label="启用 TUN" k="tun.enable" v={cfg.tun_enable} on={(x) => set('tun_enable', x)} />
                  <FormSel label="协议栈" k="tun.stack" v={cfg.tun_stack} on={(x) => set('tun_stack', x)} opts={[['gvisor', 'gVisor'], ['system', 'System'], ['mixed', 'Mixed']]} />
                  <FormTog label="自动路由" k="tun.auto-route" v={cfg.tun_autoroute} on={(x) => set('tun_autoroute', x)} hint="关闭以避免抢占 SD-WAN 默认路由" last />
                </Card>
                <Card title="DNS">
                  <FormTog label="启用 DNS" k="dns.enable" v={cfg.dns_enable} on={(x) => set('dns_enable', x)} />
                  <FormSel label="增强模式" k="dns.enhanced-mode" v={cfg.dns_mode} on={(x) => set('dns_mode', x)} opts={[['fake-ip', 'fake-ip'], ['redir-host', 'redir-host']]} last />
                </Card>
                <Card title="嗅探 Sniffer">
                  <FormTog label="启用嗅探" k="sniffer.enable" v={cfg.sniffer} on={(x) => set('sniffer', x)} hint="从 TLS/QUIC/HTTP 提取域名" last />
                </Card>
              </div>
              <div style={{ fontSize: 11, color: 'var(--text-faint)', marginTop: 10, fontFamily: 'var(--mono)' }}>
                切到 YAML 视图查看上述更改如何实时写入源码 ↔ 双向同步
              </div>
            </div>}
      </div>
    </div>
  );
}

function ProfileCard({ p, active, selected, onSelect, onActivate, onRefresh, onRemove }) {
  const remote = p.source === 'remote';
  return (
    <div className={'prof-card' + (selected ? ' sel' : '')} onClick={onSelect}>
      <div className="row-flex" style={{ gap: 7, alignItems: 'flex-start' }}>
        <span className="prof-ico" style={active ? { background: 'var(--accent)', color: 'var(--accent-ink)' } : null}>
          <Icon name={remote ? 'cloud' : 'form'} size={15} />
        </span>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 13, fontWeight: 700, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.name}</div>
          <div className="row-flex" style={{ gap: 6, marginTop: 2 }}>
            <span className="proto-tag" style={{ color: remote ? 'oklch(0.7 0.12 250)' : 'var(--text-dim)' }}>{remote ? '远程' : '本地'}</span>
            <span style={{ fontSize: 10.5, color: 'var(--text-faint)' }}>{p.nodes} 节点 · {p.size}</span>
          </div>
        </div>
        {active
          ? <span className="iface-tag" style={{ color: 'var(--accent)', background: 'color-mix(in oklch, var(--accent) 16%, transparent)', flexShrink: 0 }}>生效中</span>
          : <span className="prof-radio" />}
      </div>
      <div className="mono" style={{ fontSize: 10, color: 'var(--text-faint)', marginTop: 9, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.from}</div>
      <div className="prof-foot">
        <span style={{ fontSize: 10.5, color: 'var(--text-faint)' }}>更新 {p.updated}{remote && p.interval ? ` · 每 ${p.interval}h` : ''}</span>
        <span style={{ flex: 1 }} />
        {!active && <button className="prof-act" onClick={(e) => { e.stopPropagation(); onActivate(); }}>设为生效</button>}
        {remote && <button className="prof-mini" title="更新订阅" onClick={(e) => { e.stopPropagation(); onRefresh(); }}><Icon name="refresh" size={13} /></button>}
        {!active && <button className="prof-mini" title="删除" onClick={(e) => { e.stopPropagation(); onRemove(); }}><Icon name="x" size={13} /></button>}
      </div>
    </div>
  );
}

function FieldLabel({ label, k, hint }) {
  return (<div className="form-label"><div className="fl-name">{label}</div><div className="fl-key">{k}</div>{hint && <div style={{ fontSize: 10, color: 'var(--text-faint)', marginTop: 1 }}>{hint}</div>}</div>);
}
function FormNum({ label, k, v, on }) {
  return (<div className="form-row"><FieldLabel label={label} k={k} /><div className="form-ctl"><input className="inp mono" type="number" value={v} style={{ width: 110 }} onChange={(e) => on(+e.target.value)} /></div></div>);
}
function FormSel({ label, k, v, on, opts, last }) {
  return (<div className="form-row" style={last ? { borderBottom: 'none' } : null}><FieldLabel label={label} k={k} /><div className="form-ctl">
    <select className="inp" value={v} onChange={(e) => on(e.target.value)}>{opts.map(([val, lbl]) => <option key={val} value={val}>{lbl}</option>)}</select></div></div>);
}
function FormTog({ label, k, v, on, hint, last }) {
  return (<div className="form-row" style={last ? { borderBottom: 'none' } : null}><FieldLabel label={label} k={k} hint={hint} /><div className="form-ctl"><Toggle on={v} onChange={on} /></div></div>);
}

// ---------------- SUBSCRIPTIONS ----------------
function SubscriptionsScreen({ S }) {
  const [merge, setMerge] = React.useState('append');
  return (
    <div>
      <PageHead title="订阅管理" desc="远程配置订阅 · 定时更新与合并策略">
        <TBtn icon="plus" label="添加订阅" onClick={() => S.toast('打开「添加订阅」对话框')} />
        <TBtn icon="refresh" accent label="全部更新" onClick={() => S.toast('正在更新 3 个订阅…')} />
      </PageHead>
      <Card title="合并策略" style={{ marginBottom: 'var(--gap)' }}>
        <div className="form-row" style={{ borderBottom: 'none', padding: '4px 0' }}>
          <FieldLabel label="多订阅合并方式" k="merge-strategy" />
          <div className="form-ctl">
            <Seg value={merge} onChange={setMerge} options={[
              { v: 'override', label: '覆盖' }, { v: 'append', label: '追加' }, { v: 'group', label: '代理组合并' },
            ]} />
          </div>
        </div>
      </Card>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--gap)' }}>
        {SUBSCRIPTIONS.map((s) => {
          const pct = s.total ? s.used / s.total : 0;
          return (
            <div className="card" key={s.id} style={{ padding: 14 }}>
              <div className="row-flex" style={{ gap: 10, marginBottom: 10 }}>
                <span className="pg-ico"><Icon name="cloud" size={16} /></span>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div className="row-flex" style={{ gap: 8 }}>
                    <span style={{ fontWeight: 700, fontSize: 14 }}>{s.name}</span>
                    <span className="pg-kind">{s.nodes} 节点</span>
                    {s.auto && <span className="iface-tag" style={{ color: 'var(--accent)', background: 'color-mix(in oklch, var(--accent) 16%, transparent)' }}>自动更新</span>}
                  </div>
                  <div className="mono dim" style={{ fontSize: 10.5, marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.url}</div>
                </div>
                <Toggle on={s.auto} onChange={() => {}} size="sm" />
                <button className="icon-btn" onClick={() => S.toast('已更新「' + s.name + '」')}><Icon name="refresh" size={14} /></button>
              </div>
              <div className="row-flex" style={{ gap: 18, fontSize: 11.5 }}>
                {s.total != null ? (
                  <div style={{ flex: 1 }}>
                    <div className="row-flex" style={{ marginBottom: 4 }}>
                      <span style={{ color: 'var(--text-dim)' }}>流量 {s.used} / {s.total} GB</span>
                      <span style={{ flex: 1 }} />
                      <span className="mono" style={{ color: 'var(--text-faint)' }}>{Math.round(pct * 100)}%</span>
                    </div>
                    <div style={{ height: 5, borderRadius: 3, background: 'var(--input)', overflow: 'hidden' }}>
                      <div style={{ width: pct * 100 + '%', height: '100%', background: pct > 0.85 ? 'var(--bad)' : 'var(--accent)', borderRadius: 3 }} />
                    </div>
                  </div>
                ) : <div style={{ flex: 1, color: 'var(--text-faint)' }}>本地静态配置 · 无流量限制</div>}
                <div style={{ textAlign: 'right' }}>
                  <div style={{ color: 'var(--text-faint)', fontSize: 10 }}>到期</div>
                  <div className="mono">{s.expire || '—'}</div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <div style={{ color: 'var(--text-faint)', fontSize: 10 }}>更新于</div>
                  <div className="mono">{s.updated}</div>
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ---------------- MENU BAR PANEL ----------------
function MenuPanel({ S, onClose }) {
  const m = S.traffic;
  const dl = m.down[m.down.length - 1], ul = m.up[m.up.length - 1];
  const sel = S.sel['g_select'];
  return (
    <div className="mb-panel" onClick={(e) => e.stopPropagation()}>
      <div className="mb-panel-head">
        <span className="sb-logo" style={{ width: 26, height: 26 }}><Icon name="bolt" size={15} /></span>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 700, fontSize: 13 }}>ClashPow</div>
          <div className="row-flex" style={{ gap: 5, fontSize: 10.5, color: 'var(--text-dim)' }}>
            <Dot color={S.running ? 'var(--good)' : 'var(--warn)'} pulse={S.running} />
            {S.running ? '运行中' : '已暂停'} · {STATS.uptime}
          </div>
        </div>
        <Toggle on={S.running} onChange={S.togglePause} size="sm" />
      </div>

      <div className="mb-section">
        <div className="row-flex" style={{ justifyContent: 'space-between' }}>
          <div className="row-flex" style={{ gap: 7 }}><Dot color="var(--accent)" /><span style={{ fontSize: 11, color: 'var(--text-dim)' }}>下载</span>
            <span className="mono" style={{ fontWeight: 700, color: 'var(--accent)' }}>{fmtRate(dl)}</span></div>
          <div className="row-flex" style={{ gap: 7 }}><Dot color="#5b8cff" /><span style={{ fontSize: 11, color: 'var(--text-dim)' }}>上传</span>
            <span className="mono" style={{ fontWeight: 700 }}>{fmtRate(ul)}</span></div>
        </div>
        <div style={{ marginTop: 8 }}><Sparkline values={m.down.slice(-50)} color={S.accent} w={292} h={34} /></div>
      </div>

      <div className="mb-section">
        <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--text-faint)', marginBottom: 7, letterSpacing: '.4px' }}>节点选择</div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
          {['g_auto', 'hk01', 'jp01', 'DIRECT'].map((id) => {
            const p = resolveProxy(id); const on = sel === id;
            return (
              <button key={id} className="mb-big-btn" style={on ? { borderColor: 'var(--accent)', background: 'var(--row-sel)' } : null}
                onClick={() => S.selectNode('g_select', id)}>
                {p.region && <RegionChip region={p.region} />}
                <span>{p.name}</span><span style={{ flex: 1 }} />
                {!p.isGroup && id !== 'DIRECT' && <LatencyBadge ms={S.lat[id]} />}
                {on && <Icon name="check" size={15} style={{ color: 'var(--accent)' }} />}
              </button>
            );
          })}
        </div>
      </div>

      <div className="mb-section" style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
        <div className="mb-mini-row"><span style={{ flex: 1 }}>系统代理</span><Toggle on={S.sysProxy} onChange={(v) => S.setSysProxy(v)} size="sm" /></div>
        <div className="mb-mini-row"><span style={{ flex: 1 }}>TUN 模式</span><Toggle on={S.tun} onChange={(v) => S.setTun(v)} size="sm" /></div>
        <div className="mb-mini-row" style={{ color: 'var(--text-dim)', fontSize: 11 }}>
          <span style={{ flex: 1 }}>代理地址</span>
          <button className="copy-btn" onClick={() => copyText(`127.0.0.1:${S.ports.mixed}`, S.toast)}>
            <Icon name="link" size={12} />127.0.0.1:{S.ports.mixed}</button>
        </div>
      </div>

      <div className="mb-section" style={{ display: 'flex', gap: 8 }}>
        <button className="mb-big-btn" onClick={S.togglePause}>
          <Icon name={S.running ? 'pause' : 'playfill'} size={15} />{S.running ? '暂停' : '恢复'}</button>
        <button className="mb-big-btn" onClick={() => { S.repairNet(); }}>
          <Icon name="wrench" size={15} />一键修复</button>
      </div>
    </div>
  );
}

Object.assign(window, { ConfigScreen, SubscriptionsScreen, MenuPanel });
