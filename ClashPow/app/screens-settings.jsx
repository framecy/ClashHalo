// screens-settings.jsx — System proxy + TUN switches & related config, mihomo ports + copy

function SetRow({ label, k, hint, children, last }) {
  return (
    <div className="form-row" style={last ? { borderBottom: 'none' } : null}>
      <div className="form-label" style={{ width: 220 }}>
        <div className="fl-name">{label}</div>
        {k && <div className="fl-key">{k}</div>}
        {hint && <div style={{ fontSize: 10.5, color: 'var(--text-faint)', marginTop: 2, maxWidth: 210 }}>{hint}</div>}
      </div>
      <div className="form-ctl">{children}</div>
    </div>
  );
}

function CopyBtn({ value, S, label }) {
  return (
    <button className="copy-btn" onClick={() => copyText(value, S.toast)} title={'复制 ' + value}>
      <Icon name="link" size={13} />{label || '复制'}
    </button>
  );
}

function SettingsScreen({ S }) {
  const p = S.ports;
  const setP = (k, v) => S.setPorts({ ...p, [k]: v });

  // system-proxy related (local)
  const [guard, setGuard] = React.useState(true);
  const [autostart, setAutostart] = React.useState(true);
  const [silent, setSilent] = React.useState(false);
  const [pacMode, setPacMode] = React.useState('global');
  const [bypass, setBypass] = React.useState('localhost, 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, *.local, *.crashlytics.com');

  // tun related (local, except main toggle from S)
  const [stack, setStack] = React.useState('gvisor');
  const [device, setDevice] = React.useState('utun4');
  const [autoRoute, setAutoRoute] = React.useState(false);
  const [autoDetect, setAutoDetect] = React.useState(true);
  const [dnsHijack, setDnsHijack] = React.useState(true);
  const [strict, setStrict] = React.useState(false);
  const [mtu, setMtu] = React.useState(9000);

  const httpAddr = `127.0.0.1:${p.mixed}`;
  const socksAddr = `127.0.0.1:${p.socks}`;
  const apiAddr = `127.0.0.1:${p.api}`;
  const envCmd = `export https_proxy=http://${httpAddr} http_proxy=http://${httpAddr} all_proxy=socks5://${socksAddr}`;

  return (
    <div>
      <PageHead title="设置" desc="系统代理 · TUN 模式 · mihomo 端口">
        <TBtn icon="link" label="复制代理命令" accent onClick={() => copyText(envCmd, S.toast)} />
      </PageHead>

      {/* quick switches */}
      <div className="grid-half" style={{ marginBottom: 'var(--gap)' }}>
        <div className="card switch-hero" style={{ borderColor: S.sysProxy ? 'color-mix(in oklch, var(--accent) 45%, var(--border))' : 'var(--border)' }}>
          <div className="row-flex" style={{ gap: 11 }}>
            <span className="hero-ico" style={S.sysProxy ? { background: 'var(--accent)', color: 'var(--accent-ink)' } : null}><Icon name="globe" size={20} /></span>
            <div style={{ flex: 1 }}>
              <div style={{ fontWeight: 700, fontSize: 14 }}>系统代理</div>
              <div style={{ fontSize: 11.5, color: 'var(--text-dim)' }}>{S.sysProxy ? `已接管 · HTTP/SOCKS ${httpAddr}` : '未启用 · 应用需手动配置代理'}</div>
            </div>
            <Toggle on={S.sysProxy} onChange={(v) => { S.setSysProxy(v); S.toast(v ? '已设置系统代理' : '已清除系统代理'); }} />
          </div>
        </div>
        <div className="card switch-hero" style={{ borderColor: S.tun ? 'color-mix(in oklch, var(--accent) 45%, var(--border))' : 'var(--border)' }}>
          <div className="row-flex" style={{ gap: 11 }}>
            <span className="hero-ico" style={S.tun ? { background: 'var(--accent)', color: 'var(--accent-ink)' } : null}><Icon name="shield" size={20} /></span>
            <div style={{ flex: 1 }}>
              <div style={{ fontWeight: 700, fontSize: 14 }}>TUN 模式</div>
              <div style={{ fontSize: 11.5, color: 'var(--text-dim)' }}>{S.tun ? `用户态 ${device} · 全流量接管` : '未启用 · 仅显式代理生效'}</div>
            </div>
            <Toggle on={S.tun} onChange={(v) => { S.setTun(v); S.toast(v ? 'TUN 已启用 · 未注入默认路由' : 'TUN 已关闭'); }} />
          </div>
        </div>
      </div>

      <div className="grid-half" style={{ marginBottom: 'var(--gap)' }}>
        <Card title="系统代理 · 相关配置">
          <SetRow label="代理守护" k="proxy-guard" hint="意外退出或被篡改时自动恢复系统代理设置"><Toggle on={guard} onChange={setGuard} /></SetRow>
          <SetRow label="开机自启动" k="launch-at-login"><Toggle on={autostart} onChange={setAutostart} /></SetRow>
          <SetRow label="静默启动" k="silent-start" hint="启动时不显示主窗口，仅驻留菜单栏"><Toggle on={silent} onChange={setSilent} /></SetRow>
          <SetRow label="代理模式" k="pac / global">
            <Seg value={pacMode} onChange={setPacMode} options={[{ v: 'global', label: '全局' }, { v: 'pac', label: 'PAC' }]} />
          </SetRow>
          <SetRow label="绕过列表" k="bypass" last>
            <textarea className="inp mono" style={{ width: '100%', height: 58, resize: 'vertical', lineHeight: 1.5 }}
              value={bypass} onChange={(e) => setBypass(e.target.value)} />
          </SetRow>
        </Card>

        <Card title="TUN · 相关配置">
          <SetRow label="协议栈" k="tun.stack" hint="gVisor 用户态栈，无需内核扩展">
            <select className="inp" value={stack} onChange={(e) => setStack(e.target.value)} disabled={!S.tun}>
              <option value="gvisor">gVisor</option><option value="system">System</option><option value="mixed">Mixed</option>
            </select>
          </SetRow>
          <SetRow label="设备名" k="tun.device"><input className="inp mono" style={{ width: 130 }} value={device} onChange={(e) => setDevice(e.target.value)} disabled={!S.tun} /></SetRow>
          <SetRow label="自动路由" k="tun.auto-route" hint="关闭以避免抢占 SD‑WAN 默认路由（推荐关闭）"><Toggle on={autoRoute} onChange={setAutoRoute} /></SetRow>
          <SetRow label="自动选择接口" k="tun.auto-detect-interface"><Toggle on={autoDetect} onChange={setAutoDetect} /></SetRow>
          <SetRow label="DNS 劫持" k="tun.dns-hijack" hint="拦截 any:53，强制走内置解析器"><Toggle on={dnsHijack} onChange={setDnsHijack} /></SetRow>
          <SetRow label="严格路由" k="tun.strict-route"><Toggle on={strict} onChange={setStrict} /></SetRow>
          <SetRow label="MTU" k="tun.mtu" last><input className="inp mono" type="number" style={{ width: 110 }} value={mtu} onChange={(e) => setMtu(+e.target.value)} disabled={!S.tun} /></SetRow>
        </Card>
      </div>

      {/* mihomo ports + copy */}
      <Card title="mihomo 端口" right={<CopyBtn value={envCmd} S={S} label="复制环境变量" />}>
        <div style={{ overflow: 'hidden', borderRadius: 8, border: '0.5px solid var(--border)' }}>
          <table className="tbl port-tbl">
            <thead><tr><th>入站</th><th>键</th><th>端口</th><th>地址</th><th></th></tr></thead>
            <tbody>
              <PortRow S={S} label="混合端口 (HTTP+SOCKS)" k="mixed-port" v={p.mixed} on={(x) => setP('mixed', x)} addr={httpAddr} />
              <PortRow S={S} label="SOCKS5 端口" k="socks-port" v={p.socks} on={(x) => setP('socks', x)} addr={socksAddr} />
              <PortRow S={S} label="HTTP 端口" k="port" v={p.http} on={(x) => setP('http', x)} addr={`127.0.0.1:${p.http}`} />
              <PortRow S={S} label="Redir 透明代理" k="redir-port" v={p.redir} on={(x) => setP('redir', x)} addr={`127.0.0.1:${p.redir}`} />
              <PortRow S={S} label="TProxy 透明代理" k="tproxy-port" v={p.tproxy} on={(x) => setP('tproxy', x)} addr={`127.0.0.1:${p.tproxy}`} />
            </tbody>
          </table>
        </div>
        <div style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 2 }}>
          <SetRow label="外部控制器 (REST API)" k="external-controller">
            <span className="row-flex" style={{ gap: 8 }}>
              <input className="inp mono" style={{ width: 150 }} value={apiAddr} readOnly />
              <CopyBtn value={`http://${apiAddr}`} S={S} />
            </span>
          </SetRow>
          <SetRow label="API 密钥" k="secret" last>
            <span className="row-flex" style={{ gap: 8 }}>
              <input className="inp mono" style={{ width: 220 }} value={p.secret} readOnly />
              <CopyBtn value={p.secret} S={S} />
            </span>
          </SetRow>
        </div>
      </Card>
    </div>
  );
}

function PortRow({ S, label, k, v, on, addr }) {
  return (
    <tr>
      <td style={{ fontWeight: 600 }}>{label}</td>
      <td className="mono dim" style={{ fontSize: 10.5 }}>{k}</td>
      <td><input className="inp mono" type="number" style={{ width: 86 }} value={v} onChange={(e) => on(+e.target.value)} /></td>
      <td className="mono" style={{ color: 'var(--accent)' }}>{addr}</td>
      <td className="num"><CopyBtn value={addr} S={S} /></td>
    </tr>
  );
}

window.SettingsScreen = SettingsScreen;
