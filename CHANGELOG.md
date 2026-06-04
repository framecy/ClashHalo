# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/),版本遵循语义化版本。

## [0.4.1] - 2026-06-04

继 v0.4.0 的稳定性大修后,完成 Helper 交互、内核管理、功能可用性与界面的一轮打磨。

### Added
- **默认内置官方 mihomo 内核**,开箱即用;内核管理可一键切回内置内核并显示版本。
- 侧栏头部展示 App 版本号。

### Changed
- 概览页顶部三个快捷开关(系统代理/TUN/核心)移除,**统一由侧栏底部控制**,消除重复。
- Helper 安装/卸载增加 loading 态、防重复点击与失败原因提示;关于页版本号动态化、描述更新。
- 规则页改为只读展示内核真实规则,编辑引导至配置 YAML。

### Fixed
- **规则页此前不可用**:从 `/configs` 读规则恒为空、PATCH rules 被内核忽略;改为读 `/rules` 端点(实测 156 条可读)。
- 移除 DNS 页硬编码假统计(平均解析/Fake-IP 池/缓存,无数据源)。
- Helper 日志写入修复(原 fallback 覆盖整文件导致"进程在跑却无日志")。

### Removed
- 死代码清理:`ConfigEditor/Pages.swift`(2144 行)、`EngineStatusRPC`、`RuleEditSheet`、`HeadSwitch`。

### Internal
- 连接监控接入单连接断开;XPC 层(EngineControl/XPCManager)不再引用 `AppModel.shared`,改注入日志通道(降耦合);源码编译 0 警告。

## [0.4.0] - 2026-06-04

原生架构稳定性与安全大修:从严格自测出发,修复内核交互、TUN、Helper 权限三大类严重缺陷,并经 clean 端到端自愈验证。

### Added
- 内核启动前自动发现控制面地址/secret(解析 config.yaml 的 external-controller/secret)。
- 内核缺失时回退到已下载内核(kernel.json / kernels/),并给出可见错误。
- Helper 连通性主动探测(XPC getVersion 握手),取代"plist 存在即可用"的误判。
- 日志订阅级别可配置(默认 WARN),UI 可切换 DEBUG/INFO/WARN/ERROR(服务端过滤)。
- DMG 打包加入 `/Applications` 软链与 `使用说明.txt`(含 Gatekeeper 绕过指引)。

### Fixed
- **内核交互**:连接参数硬编码导致永久重连;内核二进制路径分裂导致静默不启动。
- **TUN**:切换"提示成功实际失败"——升级 root 时旧用户态内核杀不掉、永不以 root 重启;提示不反映真实生效状态。
- **Helper**:`unload -w` 持久禁用服务导致安装后永不启动(launchctl disabled override);改用 `enable` + `bootout`。
- **geox-url 死锁**:失效的 geodata 源使内核 fatal,而修正逻辑依赖 REST → 死锁;改为启动前规范化。
- **打包**:0 字节 geodata 进入产物;增量构建残留;plist 多套不一致。

### Security
- 控制面强制绑回环 `127.0.0.1`,弱 secret 替换为强随机值。
- Helper XPC 增加客户端代码签名校验(`identifier "com.clashpow.app"`)+ 内核路径白名单,封堵任意二进制以 root 执行的本地提权。
- 修正 `SMPrivilegedExecutables` 标识符不一致。

### Changed
- 源码编译警告清零(Swift 6 严格并发就绪)。
- 移除失效的 LaunchDaemon plist,收敛为安装时单一真相源。

## [0.3.1] - 2026-06-02
UI 与稳定性改进。详见 [GitHub Release](https://github.com/framecy/ClashPow/releases/tag/v0.3.1)。

## [0.3.0] - 2026-05-31
原生架构首个版本(移除自研 Go 引擎)。详见 [GitHub Release](https://github.com/framecy/ClashPow/releases/tag/v0.3.0)。
