# ClashPow

> macOS 14+ (Apple Silicon) 原生 SwiftUI 代理客户端，封装 mihomo (Clash.Meta) 内核。

自研引擎内嵌 mihomo，由 `launchd` 守护、崩溃自愈、配置错误自动回滚；GUI 通过引擎托管的 mihomo
external-controller (REST + WebSocket) 驱动全部界面，纯实时数据，无 mock。

## 系统要求

- macOS 14.0+（Apple Silicon M 系列）

## 功能

- **概览仪表盘** — 总下载/上传/连接数/访问目标，Metal GPU 流量趋势图，核心/应用内存，流量分布
  (直连/代理/拦截)，策略组排行，流量时间轴，高频规则 / 热门域名 / 热门节点，客户端源 IP / 热门进程 / 目标分类
- **策略组** — 按类型图标 (URLTest/Fallback/LoadBalance/Selector)，当前出口与延迟，点选切换，单组/全部测速
- **连接监控** — 实时连接表 (目标/进程/规则/链路/上下行速率)，搜索过滤
- **规则** — 启用/禁用、编辑、上移/下移、删除、复制，添加新规则（热重载）
- **多配置管理** — 本地配置卡片，导入远程订阅 / 添加本地配置，一键切换 (持久化 + 热重载)，YAML 编辑
- **DNS** — enable/ipv6/enhanced-mode/fake-ip/上游/过滤 可编辑，解析测试，Fake-IP 映射
- **日志** — 实时流，级别过滤、搜索、暂停、导出
- **网络** — 入站端口、IPv6/MPTCP/TCP 并发、访问控制 (allow-lan/绑定/允许-拒绝 IP/认证/免认证)、系统代理开关
- **通用** — 路由与连接 (日志级别/统一延迟/进程匹配/Keep-Alive)，GEO 数据库 (DAT 模式/加载器/自动更新)，
  GEO 下载源，**内核管理** (版本/正式版-Alpha 通道/检查更新/下载/重启)
- **TUN / 嗅探** — 协议栈/自动路由/DNS 劫持/路由排除；嗅探开关
- **SD-WAN 地图** — 网卡拓扑识别 (物理/代理 TUN/Tailscale/ZeroTier/蒲公英)，UTUN 路由表，路由冲突检测
- **总开关** — TUN 模式、系统代理 (networksetup，单次管理员授权)，菜单栏状态

## 架构

```
┌──────────────────────┐  UDS 类型化 RPC (控制)   ┌──────────────────────────┐
│  ClashPow GUI         │◄───────────────────────►│  ClashPow Engine (Go)     │
│  SwiftUI 5 + Metal    │  REST + WebSocket (数据) │  内嵌 mihomo + 扩展        │
│  AppModel/MihomoClient│◄───────────────────────►│  launchd 守护 · 配置回滚   │
└──────────────────────┘  mmap 共享统计 (10ms)    └──────────────────────────┘
```

- **引擎**：内嵌 mihomo (Go 库)，托管配置 (覆盖+回滚)，UDS JSON-RPC 控制面，mihomo REST 控制器
  (127.0.0.1:9092)，10ms 自适应统计写入 mmap 共享文件。
- **GUI**：首次启动自动安装引擎 + LaunchAgent；自动发现控制器；Metal MTKView 从 mmap 渲染 120fps 流量图
  (后台节流)；全部配置经 `patch_config` 深合并写入并热重载 (校验失败回滚)。

## 开发

```bash
# 一键打包自包含 .app + DMG (引擎 + geodata 打进 bundle)
bash make.sh

# 仅构建 GUI (Debug)
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug -destination 'platform=macOS,arch=arm64' build

# 运行（必须用 open，勿直接跑二进制）
APP=$(find ~/Library/Developer/Xcode/DerivedData/ClashPow-*/Build/Products/Debug -name "ClashPow.app" -type d | head -1); open "$APP"
```

详见 [CHANGELOG.md](CHANGELOG.md) 与 [CLAUDE.md](CLAUDE.md)。

## 已知边界

- 转发层极致性能 (≤1.8ms / 9Gbps / readv-writev) 取决于 mihomo 数据面本身，不修改内核前提下不再优化。
- 跨进程 IOSurface 经 Go 进程不可行，统计采用 POSIX mmap 共享文件 (等价零拷贝)，渲染为真实 Metal GPU。
- 内核 Alpha 切换：已实现版本检查与外部内核下载；以下载内核替换内嵌内核的“监管进程”模式为后续启用。
- 公开分发需 Developer ID 签名 + 公证 + Sparkle（`make.sh` 末尾列出命令）；当前为 ad-hoc 签名。

## 许可

MIT
