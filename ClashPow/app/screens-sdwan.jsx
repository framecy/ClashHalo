// screens-sdwan.jsx — SD-WAN topology + drag-to-assign routing

const IFACE_COLOR = {
  physical: 'oklch(0.62 0.15 250)',
  clashpow: 'var(--accent)',
  tailscale: 'oklch(0.68 0.12 185)',
  zerotier: 'oklch(0.72 0.15 60)',
  oray: 'oklch(0.66 0.18 300)',
};
const IFACE_ICON = { physical: 'wifi', clashpow: 'shield', tailscale: 'share', zerotier: 'globe', oray: 'link' };

function SdwanScreen({ S }) {
  const [drag, setDrag] = React.useState(null);
  const [over, setOver] = React.useState(null);
  const assign = S.routeAssign;

  const drop = (ifaceId) => {
    setOver(null);
    if (!drag) return;
    const r = ROUTE_TARGETS.find((x) => x.id === drag);
    setDrag(null);
    if (!r || r.locked) return;
    if (assign[drag] === ifaceId) return;
    S.setRouteAssign({ ...assign, [drag]: ifaceId });
    S.toast(`已将「${r.label}」路由迁移至 ${INTERFACES.find((i) => i.id === ifaceId).name}`);
  };

  return (
    <div>
      <PageHead title="SD‑WAN 共存" desc="用户态 UTUN · 不占 VPN 插槽 · 不抢默认路由">
        <TBtn icon="check" accent label="无路由冲突" onClick={() => {}} />
        <TBtn icon="wrench" label="重新探测拓扑" onClick={() => S.toast('已重新扫描 SCDynamicStore 接口与路由表')} />
      </PageHead>

      <div className="card" style={{ marginBottom: 'var(--gap)', padding: '12px 14px', display: 'flex', gap: 12, alignItems: 'center' }}>
        <span className="iface-ico" style={{ '--ifc': 'var(--accent)', width: 32, height: 32 }}><Icon name="shield" size={17} /></span>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 700, fontSize: 13 }}>自动隔离已启用</div>
          <div style={{ fontSize: 11.5, color: 'var(--text-dim)' }}>
            监听到 3 个 SD‑WAN 虚拟接口。ClashPow 仅注入代理所需精确网段，
            <b style={{ color: 'var(--accent)' }}> 未添加默认路由</b>，Tailscale / ZeroTier / 蒲公英 路由保持完整。
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div className="mono" style={{ fontSize: 18, fontWeight: 700, color: 'var(--accent)' }}>0</div>
          <div style={{ fontSize: 10, color: 'var(--text-faint)' }}>路由冲突</div>
        </div>
      </div>

      <div style={{ fontSize: 11, color: 'var(--text-faint)', marginBottom: 8, display: 'flex', alignItems: 'center', gap: 6 }}>
        <Icon name="grip" size={13} /> 拖拽下方路由条目到其它接口可重新分流（锁定项为系统保护路由，不可移动）
      </div>

      <div className="topo">
        {INTERFACES.map((ifc) => {
          const routes = ROUTE_TARGETS.filter((r) => assign[r.id] === ifc.id);
          const color = IFACE_COLOR[ifc.kind];
          return (
            <div key={ifc.id} style={{ '--ifc': color }}>
              <div className="iface-card" style={{ '--ifc': color, borderRadius: '10px 10px 0 0', borderBottom: 'none' }}>
                <span className="iface-ico" style={{ '--ifc': color }}><Icon name={IFACE_ICON[ifc.kind]} size={19} /></span>
                <div style={{ flex: 1 }}>
                  <div className="row-flex" style={{ gap: 8 }}>
                    <span className="iface-name">{ifc.name}</span>
                    <span className="iface-tag" style={{ color, background: 'color-mix(in oklch, ' + color + ' 16%, transparent)' }}>{ifc.label}</span>
                    {ifc.isDefault && <span className="iface-tag" style={{ color: 'var(--text-dim)', background: 'var(--elev)' }}>默认网关</span>}
                  </div>
                  <div className="iface-addr">{ifc.addr}{ifc.gw ? ' · gw ' + ifc.gw : ''}{ifc.vendor ? ' · ' + ifc.vendor : ''}</div>
                </div>
                <div className="row-flex" style={{ gap: 6 }}>
                  <Dot color={ifc.status === 'up' ? 'var(--good)' : 'var(--text-faint)'} pulse={ifc.status === 'up'} />
                  <span style={{ fontSize: 11, color: 'var(--text-dim)' }}>{ifc.status === 'up' ? '在线' : '空闲'}</span>
                </div>
              </div>
              <div
                className={'route-zone' + (over === ifc.id ? ' drag-over' : '')}
                style={{ borderRadius: '0 0 10px 10px' }}
                onDragOver={(e) => { e.preventDefault(); setOver(ifc.id); }}
                onDragLeave={(e) => { if (e.currentTarget === e.target) setOver(null); }}
                onDrop={() => drop(ifc.id)}>
                {routes.length === 0 && <div style={{ fontSize: 11, color: 'var(--text-faint)', padding: '8px 4px' }}>拖拽路由到此接口…</div>}
                {routes.map((r) => (
                  <div key={r.id}
                    className={'route-pill' + (r.locked ? ' locked' : '') + (drag === r.id ? ' dragging' : '')}
                    draggable={!r.locked}
                    onDragStart={() => setDrag(r.id)}
                    onDragEnd={() => { setDrag(null); setOver(null); }}>
                    <Icon name={r.locked ? 'lock' : 'grip'} size={14} style={{ color: 'var(--text-faint)' }} />
                    <span style={{ fontSize: 12, fontWeight: 600 }}>{r.label}</span>
                    <span style={{ flex: 1 }} />
                    <span className="route-cidr">{r.cidr}</span>
                  </div>
                ))}
              </div>
            </div>
          );
        })}
      </div>

      <Card title="进程级分流 (SO_USER_COOKIE + PF)" style={{ marginTop: 'var(--gap)' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          {[
            ['Docker Desktop', '走 ClashPow 代理', 'clashpow'],
            ['Tailscale SSH 会话', '走 Tailscale 直达', 'tailscale'],
            ['内网管理后台', '走蒲公英组网', 'oray'],
          ].map(([app, rule, kind], i, a) => (
            <div className="form-row" key={app} style={i === a.length - 1 ? { borderBottom: 'none' } : null}>
              <span className="iface-ico" style={{ '--ifc': IFACE_COLOR[kind], width: 24, height: 24, borderRadius: 7 }}><Icon name={IFACE_ICON[kind]} size={13} /></span>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 12.5, fontWeight: 600 }}>{app}</div>
                <div style={{ fontSize: 11, color: 'var(--text-faint)' }}>{rule}</div>
              </div>
              <Toggle on={true} onChange={() => {}} size="sm" />
            </div>
          ))}
        </div>
      </Card>
    </div>
  );
}

window.SdwanScreen = SdwanScreen;
