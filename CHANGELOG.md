# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/),版本遵循语义化版本。

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
