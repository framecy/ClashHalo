// app.jsx — shell, state, navigation, menu bar, tweaks

window.accentHex = (v) => v;

const NAV = [
  { group: '概览', items: [
    { id: 'dashboard', label: '仪表盘', icon: 'gauge' },
  ] },
  { group: '代理', items: [
    { id: 'proxies', label: '代理', icon: 'rocket' },
    { id: 'connections', label: '连接', icon: 'link' },
    { id: 'sdwan', label: 'SD‑WAN', icon: 'share' },
  ] },
  { group: '网络', items: [
    { id: 'dns', label: 'DNS 缓存', icon: 'dns' },
    { id: 'logs', label: '日志', icon: 'logs' },
  ] },
  { group: '配置', items: [
    { id: 'subscriptions', label: '订阅', icon: 'cloud' },
    { id: 'config', label: '配置编辑', icon: 'sliders' },
    { id: 'settings', label: '设置', icon: 'gear' },
  ] },
];
const TITLES = { dashboard: '仪表盘', proxies: '代理', connections: '连接监控', sdwan: 'SD‑WAN 共存', dns: 'DNS 缓存', logs: '日志', subscriptions: '订阅管理', config: '配置编辑', settings: '设置' };

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "dark": true,
  "accent": "#19c37d",
  "density": "compact",
  "nav": "sidebar"
}/*EDITMODE-END*/;

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [route, setRoute] = React.useState('dashboard');
  const [running, setRunning] = React.useState(true);
  const [mode, setMode] = React.useState('rule');
  const [sel, setSel] = React.useState(() => Object.fromEntries(GROUPS.map((g) => [g.id, g.now])));
  const [lat, setLat] = React.useState(() => {
    const o = { DIRECT: 1, REJECT: 0 }; NODES.forEach((n) => (o[n.id] = n.latency)); return o;
  });
  const [testing, setTesting] = React.useState(new Set());
  const [connections] = React.useState(() => makeConnections(48));
  const [routeAssign, setRouteAssign] = React.useState(() => Object.fromEntries(ROUTE_TARGETS.map((r) => [r.id, r.iface])));
  const [menuOpen, setMenuOpen] = React.useState(false);
  const [toast, setToast] = React.useState(null);
  const [clock, setClock] = React.useState(nowClock());
  const [sysProxy, setSysProxy] = React.useState(true);
  const [tun, setTun] = React.useState(true);
  const [ports, setPorts] = React.useState({ mixed: 7890, socks: 7891, http: 7890, redir: 7892, tproxy: 7893, api: 9090, secret: 'cp_9f3a7b2e1d8c4f60' });

  const traffic = useTrafficModel(running);

  React.useEffect(() => { const i = setInterval(() => setClock(nowClock()), 10000); return () => clearInterval(i); }, []);

  const showToast = React.useCallback((msg) => {
    setToast({ msg, id: Date.now() });
  }, []);
  React.useEffect(() => { if (!toast) return; const x = setTimeout(() => setToast(null), 2600); return () => clearTimeout(x); }, [toast]);

  const testNodes = (ids) => {
    setTesting((s) => { const n = new Set(s); ids.forEach((i) => n.add(i)); return n; });
    ids.forEach((id, k) => setTimeout(() => {
      setLat((l) => ({ ...l, [id]: Math.max(18, Math.round((NODE_BY_ID[id]?.latency || 80) * (0.7 + Math.random() * 0.7))) }));
      setTesting((s) => { const n = new Set(s); n.delete(id); return n; });
    }, 250 + k * 90 + Math.random() * 400));
  };
  const selectNode = (gid, id) => { setSel((s) => ({ ...s, [gid]: id })); };
  const togglePause = () => { setRunning((r) => { showToast(r ? '代理已暂停 · 流量直连' : '代理已恢复'); return !r; }); };
  const repairNet = () => { showToast('正在重置路由表与 DNS… 网络已修复 (0.8s)'); };

  const S = {
    route, setRoute, running, togglePause, mode, setMode, sel, selectNode,
    lat, testing, testNodes, connections, routeAssign, setRouteAssign,
    traffic, accent: t.accent, toast: showToast, repairNet,
    sysProxy, setSysProxy, tun, setTun, ports, setPorts,
  };

  const Screen = {
    dashboard: DashboardScreen, proxies: ProxiesScreen, connections: ConnectionsScreen,
    sdwan: SdwanScreen, dns: DnsScreen, logs: LogsScreen,
    subscriptions: SubscriptionsScreen, config: ConfigScreen, settings: SettingsScreen,
  }[route];

  const dl = traffic.down[traffic.down.length - 1];
  const curNode = resolveProxy(sel['g_select']);

  return (
    <div id="desk" data-theme={t.dark ? 'dark' : 'light'} data-density={t.density}
      style={{ '--accent': t.accent }} onClick={() => setMenuOpen(false)}>
      {/* macOS menu bar */}
      <div id="menubar">
        <span className="mb-app">ClashPow</span>
        <span className="mb-item">文件</span>
        <span className="mb-item">编辑</span>
        <span className="mb-item">视图</span>
        <span className="mb-item">帮助</span>
        <div className="mb-right">
          <span className={'mb-status' + (menuOpen ? ' open' : '')}
            onClick={(e) => { e.stopPropagation(); setMenuOpen((o) => !o); }}>
            <Icon name="bolt" size={13} style={{ color: running ? t.accent : 'rgba(255,255,255,0.6)' }} />
            <span className="mono" style={{ fontSize: 11 }}>{fmtRate(dl)}</span>
          </span>
          <Icon name="wifi" size={15} />
          <Icon name="battery" size={17} />
          <span style={{ fontVariantNumeric: 'tabular-nums' }}>{clock}</span>
        </div>
        {menuOpen && <MenuPanel S={S} onClose={() => setMenuOpen(false)} />}
      </div>

      <div id="stage">
        <div className="win">
          {/* sidebar */}
          <div className={'sidebar' + (t.nav === 'rail' ? ' rail' : '')}>
            <div className="sb-brand">
              <span className="sb-logo"><Icon name="bolt" size={15} /></span>
              {t.nav !== 'rail' && <div>
                <div className="sb-name">ClashPow</div>
                <div className="sb-ver">mihomo v1.18 · arm64</div>
              </div>}
            </div>

            {t.nav !== 'rail' && (
              <div className="sb-status">
                <div className="sb-status-row">
                  <Dot color={running ? 'var(--good)' : 'var(--warn)'} pulse={running} />
                  <span style={{ color: 'var(--text-dim)' }}>{running ? '代理运行中' : '已暂停'}</span>
                  <span style={{ flex: 1 }} />
                  <span className="region-chip" style={{ borderColor: 'var(--border-strong)', color: 'var(--text-dim)' }}>{({ rule: '规则', global: '全局', direct: '直连' })[mode]}</span>
                </div>
                <div className="big">{curNode.name}</div>
                <div className="sb-status-row" style={{ marginTop: 5, color: 'var(--text-faint)' }}>
                  <Icon name="dot" size={9} style={{ color: 'var(--accent)' }} />
                  <span className="mono" style={{ fontSize: 11 }}>{fmtRate(dl)}</span>
                  <span style={{ flex: 1 }} />
                  <span className="mono" style={{ fontSize: 10 }}>{connections.length} 连接</span>
                </div>
              </div>
            )}

            <div className="sb-scroll scrollbox">
              {NAV.map((sec) => (
                <div key={sec.group}>
                  <div className="sb-group-label">{sec.group}</div>
                  {sec.items.map((it) => (
                    <div key={it.id} className={'sb-item' + (route === it.id ? ' on' : '')}
                      onClick={() => setRoute(it.id)} title={it.label}>
                      <Icon name={it.icon} size={16} />
                      <span className="sb-label">{it.label}</span>
                      {it.id === 'connections' && <span className="sb-badge">{connections.length}</span>}
                    </div>
                  ))}
                </div>
              ))}
            </div>
          </div>

          {/* main */}
          <div className="main">
            <div className="titlebar">
              <span className="tb-title">{TITLES[route]}</span>
              <span style={{ flex: 1 }} />
              <button className="icon-btn" title={running ? '暂停' : '恢复'} onClick={togglePause}
                style={!running ? { color: 'var(--warn)' } : null}>
                <Icon name={running ? 'pause' : 'playfill'} size={15} />
              </button>
              <button className="icon-btn" title="一键修复网络" onClick={repairNet}><Icon name="wrench" size={15} /></button>
              <button className="icon-btn" title="设置"><Icon name="gear" size={15} /></button>
            </div>
            <div className="content scrollbox">
              <Screen S={S} />
            </div>
          </div>
        </div>
      </div>

      {toast && <div key={toast.id} className="cp-toast">{toast.msg}</div>}

      <TweaksPanel>
        <TweakSection label="外观" />
        <TweakToggle label="深色模式" value={t.dark} onChange={(v) => setTweak('dark', v)} />
        <TweakColor label="强调色" value={t.accent}
          options={['#19c37d', '#0a84ff', '#bf5af2', '#ff9f0a']}
          onChange={(v) => setTweak('accent', v)} />
        <TweakRadio label="信息密度" value={t.density} options={['compact', 'regular', 'comfy']}
          onChange={(v) => setTweak('density', v)} />
        <TweakSection label="导航布局" />
        <TweakRadio label="侧栏样式" value={t.nav} options={['sidebar', 'rail']}
          onChange={(v) => setTweak('nav', v)} />
      </TweaksPanel>
    </div>
  );
}

function nowClock() {
  const d = new Date();
  const wd = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][d.getDay()];
  return `${wd} ${d.toTimeString().slice(0, 5)}`;
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
