// data.jsx — mock data for ClashPow prototype
// All numbers are illustrative.

const REGIONS = {
  HK: { name: '香港', hue: 5 },
  JP: { name: '日本', hue: 0 },
  US: { name: '美国', hue: 250 },
  SG: { name: '新加坡', hue: 150 },
  TW: { name: '台湾', hue: 30 },
  KR: { name: '韩国', hue: 290 },
  DE: { name: '德国', hue: 60 },
  UK: { name: '英国', hue: 220 },
};

// Outbound proxy nodes
const NODES = [
  { id: 'hk01', name: '香港 IEPL 专线 01', region: 'HK', type: 'Trojan', latency: 38, load: 0.42 },
  { id: 'hk02', name: '香港 IEPL 专线 02', region: 'HK', type: 'Trojan', latency: 41, load: 0.55 },
  { id: 'hk03', name: '香港 BGP 中转 03', region: 'HK', type: 'Hysteria2', latency: 52, load: 0.31 },
  { id: 'jp01', name: '日本 东京 IPLC 01', region: 'JP', type: 'VLESS', latency: 64, load: 0.28 },
  { id: 'jp02', name: '日本 大阪 中转 02', region: 'JP', type: 'VMess', latency: 71, load: 0.61 },
  { id: 'sg01', name: '新加坡 IPLC 01', region: 'SG', type: 'Hysteria2', latency: 88, load: 0.19 },
  { id: 'sg02', name: '新加坡 中转 02', region: 'SG', type: 'Shadowsocks', latency: 96, load: 0.44 },
  { id: 'us01', name: '美国 洛杉矶 GIA 01', region: 'US', type: 'VLESS', latency: 142, load: 0.36 },
  { id: 'us02', name: '美国 圣何塞 9929 02', region: 'US', type: 'TUIC', latency: 168, load: 0.22 },
  { id: 'tw01', name: '台湾 Hinet 家宽 01', region: 'TW', type: 'Trojan', latency: 58, load: 0.48 },
  { id: 'kr01', name: '韩国 首尔 CN2 01', region: 'KR', type: 'VMess', latency: 74, load: 0.33 },
  { id: 'de01', name: '德国 法兰克福 01', region: 'DE', type: 'WireGuard', latency: 210, load: 0.12 },
  { id: 'uk01', name: '英国 伦敦 01', region: 'UK', type: 'VLESS', latency: 224, load: 0.15 },
];

const NODE_BY_ID = Object.fromEntries(NODES.map((n) => [n.id, n]));

// Proxy groups
const GROUPS = [
  {
    id: 'g_select', name: '节点选择', kind: 'SELECT', now: 'g_auto',
    members: ['g_auto', 'g_fallback', 'hk01', 'jp01', 'sg01', 'us01', 'DIRECT'],
    icon: 'rocket',
  },
  {
    id: 'g_auto', name: '自动选择', kind: 'URL-TEST', now: 'hk01',
    members: ['hk01', 'hk02', 'hk03', 'jp01', 'jp02', 'sg01', 'tw01', 'kr01'],
    icon: 'recycle', interval: 300,
  },
  {
    id: 'g_fallback', name: '故障转移', kind: 'FALLBACK', now: 'hk01',
    members: ['hk01', 'jp01', 'sg01', 'us01'],
    icon: 'shield',
  },
  {
    id: 'g_lb', name: '负载均衡', kind: 'LOAD-BALANCE', now: '—',
    members: ['hk01', 'hk02', 'hk03', 'jp01', 'sg01'],
    icon: 'balance', strategy: 'round-robin',
  },
  {
    id: 'g_media', name: '国外媒体', kind: 'SELECT', now: 'sg01',
    members: ['g_auto', 'sg01', 'us01', 'jp01', 'hk01'],
    icon: 'play',
  },
  {
    id: 'g_ai', name: 'AI 服务', kind: 'SELECT', now: 'us01',
    members: ['us01', 'us02', 'jp01', 'sg01'],
    icon: 'spark',
  },
  {
    id: 'g_ms', name: '微软服务', kind: 'SELECT', now: 'DIRECT',
    members: ['DIRECT', 'g_select', 'hk01'],
    icon: 'window',
  },
  {
    id: 'g_apple', name: '苹果服务', kind: 'SELECT', now: 'DIRECT',
    members: ['DIRECT', 'g_select', 'hk01'],
    icon: 'apple',
  },
  {
    id: 'g_direct', name: '全球直连', kind: 'SELECT', now: 'DIRECT',
    members: ['DIRECT', 'g_select'],
    icon: 'compass',
  },
];

const SPECIAL = {
  DIRECT: { id: 'DIRECT', name: '直连', type: 'Direct', region: null, latency: 1, load: 0 },
  REJECT: { id: 'REJECT', name: '拒绝', type: 'Reject', region: null, latency: 0, load: 0 },
};

function resolveProxy(id) {
  if (SPECIAL[id]) return SPECIAL[id];
  if (NODE_BY_ID[id]) return NODE_BY_ID[id];
  const g = GROUPS.find((x) => x.id === id);
  if (g) return { id: g.id, name: g.name, type: 'Group', isGroup: true, now: g.now };
  return { id, name: id, type: '?', latency: null };
}

// Live connections
const PROCS = ['com.apple.WebKit', 'Telegram', 'Google Chrome', 'curl', 'Code Helper', 'Spotify', 'Docker', 'figma_agent', 'mihomo', 'Mail'];
const HOSTS = [
  ['raw.githubusercontent.com', '185.199.108.133', 443, '节点选择', 'hk01', 'DOMAIN-SUFFIX'],
  ['api.openai.com', '162.159.140.245', 443, 'AI 服务', 'us01', 'RULE-SET,ai'],
  ['i.ytimg.com', '142.250.72.118', 443, '国外媒体', 'sg01', 'GEOSITE,youtube'],
  ['dn.figma.com', '13.226.210.88', 443, '节点选择', 'jp01', 'DOMAIN-KEYWORD'],
  ['t.me', '149.154.167.99', 443, '节点选择', 'hk01', 'DOMAIN-SUFFIX'],
  ['mtalk.google.com', '142.250.157.188', 5228, '国外媒体', 'sg01', 'GEOSITE,google'],
  ['steamcdn-a.akamaihd.net', '23.62.131.50', 443, '全球直连', 'DIRECT', 'GEOIP,CN'],
  ['registry-1.docker.io', '34.226.69.105', 443, '节点选择', 'us01', 'RULE-SET,proxy'],
  ['gateway.icloud.com', '17.248.180.65', 443, '苹果服务', 'DIRECT', 'GEOSITE,apple-cn'],
  ['analytics.tiktok.com', '161.117.95.10', 443, '广告拦截', 'REJECT', 'RULE-SET,reject'],
  ['cdn.jsdelivr.net', '151.101.1.229', 443, '节点选择', 'hk01', 'DOMAIN-SUFFIX'],
  ['push.apple.com', '17.57.146.84', 5223, '苹果服务', 'DIRECT', 'GEOSITE,apple'],
  ['speed.cloudflare.com', '104.16.123.96', 443, '自动选择', 'jp01', 'DOMAIN'],
  ['music.163.com', '59.111.181.38', 443, '全球直连', 'DIRECT', 'GEOSITE,netease'],
  ['discord.gg', '162.159.137.232', 443, '国外媒体', 'us01', 'DOMAIN-SUFFIX'],
];

function makeConnections(n) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const h = HOSTS[i % HOSTS.length];
    out.push({
      id: 'c' + i,
      host: h[0], ip: h[1], port: h[2], chain: h[3], node: h[4], rule: h[5],
      proc: PROCS[(i * 3) % PROCS.length],
      net: i % 4 === 0 ? 'UDP' : 'TCP',
      up: Math.round(2000 + Math.random() * 900000),
      down: Math.round(8000 + Math.random() * 4500000),
      ulSpeed: Math.round(Math.random() * 240000),
      dlSpeed: Math.round(Math.random() * 1800000),
      start: Date.now() - Math.round(Math.random() * 600000),
    });
  }
  return out;
}

// DNS / Fake-IP cache
const DNS_CACHE = [
  { host: 'api.openai.com', fakeip: '198.18.0.41', real: '162.159.140.245', type: 'A', src: 'DoH', ttl: 287, hits: 142 },
  { host: 'raw.githubusercontent.com', fakeip: '198.18.0.12', real: '185.199.108.133', type: 'A', src: 'DoH', ttl: 92, hits: 88 },
  { host: 't.me', fakeip: '198.18.0.7', real: '149.154.167.99', type: 'A', src: 'DoT', ttl: 41, hits: 311 },
  { host: 'i.ytimg.com', fakeip: '198.18.0.55', real: '142.250.72.118', type: 'AAAA', src: 'DoH', ttl: 188, hits: 522 },
  { host: 'gateway.icloud.com', fakeip: '—', real: '17.248.180.65', type: 'A', src: 'UDP', ttl: 3600, hits: 12, direct: true },
  { host: 'music.163.com', fakeip: '—', real: '59.111.181.38', type: 'A', src: 'UDP', ttl: 600, hits: 47, direct: true },
  { host: 'dn.figma.com', fakeip: '198.18.0.83', real: '13.226.210.88', type: 'A', src: 'DoQ', ttl: 240, hits: 19 },
  { host: 'speed.cloudflare.com', fakeip: '198.18.0.91', real: '104.16.123.96', type: 'A', src: 'DoH', ttl: 300, hits: 6 },
  { host: 'registry-1.docker.io', fakeip: '198.18.0.102', real: '34.226.69.105', type: 'A', src: 'DoH', ttl: 120, hits: 28 },
  { host: 'discord.gg', fakeip: '198.18.0.66', real: '162.159.137.232', type: 'A', src: 'DoH', ttl: 156, hits: 73 },
];

// Network interfaces for SD-WAN view
const INTERFACES = [
  { id: 'en0', kind: 'physical', name: 'Wi‑Fi (en0)', addr: '192.168.1.34', label: '物理网卡', status: 'up', isDefault: true, gw: '192.168.1.1' },
  { id: 'utun4', kind: 'clashpow', name: 'ClashPow TUN (utun4)', addr: '198.18.0.1/15', label: '本应用 UTUN', status: 'up' },
  { id: 'utun3', kind: 'tailscale', name: 'Tailscale (utun3)', addr: '100.84.21.7', label: 'SD‑WAN', status: 'up', vendor: 'Tailscale' },
  { id: 'utun6', kind: 'zerotier', name: 'ZeroTier (utun6)', addr: '10.147.20.45', label: 'SD‑WAN', status: 'up', vendor: 'ZeroTier' },
  { id: 'utun8', kind: 'oray', name: '蒲公英 (utun8)', addr: '172.16.8.12', label: 'SD‑WAN', status: 'idle', vendor: '蒲公英' },
];

// Routing rules for SD-WAN drag assignment
const ROUTE_TARGETS = [
  { id: 'r1', label: '代理流量 (规则匹配)', cidr: '198.18.0.0/15', iface: 'utun4', locked: false },
  { id: 'r2', label: '内网直连', cidr: '192.168.0.0/16', iface: 'en0', locked: true },
  { id: 'r3', label: 'Tailnet 100.64/10', cidr: '100.64.0.0/10', iface: 'utun3', locked: false },
  { id: 'r4', label: 'ZeroTier 10.147.20/24', cidr: '10.147.20.0/24', iface: 'utun6', locked: false },
  { id: 'r5', label: '蒲公英异地组网', cidr: '172.16.0.0/12', iface: 'utun8', locked: false },
  { id: 'r6', label: '默认路由', cidr: '0.0.0.0/0', iface: 'en0', locked: true },
];

const SUBSCRIPTIONS = [
  { id: 's1', name: '主力机场 · Premium', url: 'https://sub.example.com/clash/abc123', nodes: 86, used: 412, total: 1024, expire: '2026-11-02', updated: '14 分钟前', auto: true },
  { id: 's2', name: '备用 · IPLC Lite', url: 'https://lite.example.net/sub/xyz', nodes: 24, used: 38, total: 200, expire: '2026-08-15', updated: '3 小时前', auto: true },
  { id: 's3', name: '自建节点 (静态)', url: 'file:///Users/me/.config/clashpow/self.yaml', nodes: 4, used: null, total: null, expire: null, updated: '6 天前', auto: false },
];

// Config profiles (multi-config / 多配置选择)
const PROFILES = [
  { id: 'p1', name: '主力机场 · Premium', source: 'remote', from: 'https://sub.example.com/clash/abc123', nodes: 86, size: '248 KB', updated: '14 分钟前', interval: 24, cfg: { mode: 'rule' } },
  { id: 'p2', name: '备用 · IPLC Lite', source: 'remote', from: 'https://lite.example.net/sub/xyz', nodes: 24, size: '63 KB', updated: '3 小时前', interval: 12, cfg: { mode: 'rule', dns_mode: 'redir-host' } },
  { id: 'p3', name: '自建节点', source: 'local', from: '~/.config/clashpow/self.yaml', nodes: 4, size: '12 KB', updated: '6 天前', cfg: { 'mixed-port': 1080, 'socks-port': 1081, tun_stack: 'system' } },
  { id: 'p4', name: '全局直连测试', source: 'local', from: '~/.config/clashpow/direct.yaml', nodes: 0, size: '3 KB', updated: '2 周前', cfg: { mode: 'direct', tun_enable: false, dns_enable: false } },
];

const LOG_TEMPLATES = [
  ['info', '[TCP] {h}:443 --> 节点选择(hk01) match DomainSuffix'],
  ['info', '[DNS] resolve {h} via DoH 1.1.1.1 -> 198.18.0.{n} (fake-ip)'],
  ['debug', '[Sniffer] TLS SNI extracted: {h}'],
  ['info', '[UDP] {h}:443 --> 国外媒体(sg01) match GeoSite'],
  ['warning', '[Pool] utun read buffer high-watermark, growing readv batch to 64'],
  ['info', '[Rules] mmap rule-set reloaded: 11,284 rules in 38 ms'],
  ['debug', '[Route] SCDynamicStore change: utun3 up, inject 100.64.0.0/10 -> utun3'],
  ['error', '[Proxy] hk03 handshake timeout (2.0s), failover -> hk01'],
  ['info', '[TCP] {h}:443 --> 全球直连(DIRECT) match GeoIP,CN'],
  ['debug', '[Stat] IOSurface frame committed, write-ptr=0x{x}'],
];

const STATS = {
  uptime: '4 天 02:17:33',
  ruleCount: 11284,
  ruleLoadMs: 38,
  memEngine: 46,
  memGui: 31,
  power: 17,
  fps: 120,
  fwdLatency: 1.6,
  throughput: 9.2,
  totalUp: 4.82e9,
  totalDown: 31.6e9,
};

Object.assign(window, {
  REGIONS, NODES, NODE_BY_ID, GROUPS, SPECIAL, resolveProxy,
  makeConnections, DNS_CACHE, INTERFACES, ROUTE_TARGETS,
  SUBSCRIPTIONS, LOG_TEMPLATES, STATS, PROFILES,
});
