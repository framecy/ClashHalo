# ClashPow

> macOS 14+ (Apple Silicon) 原生 SwiftUI 代理客户端，使用 mihomo (Clash.Meta) 官方内核。

## 架构

本项目已完全抛弃自研 Go 引擎，直接使用官方 `mihomo` 内核：
1. **GUI**：SwiftUI 5 + Metal 渲染，通过 REST + WebSocket 与内核通信。
2. **Privileged Helper**：负责系统代理设置及以 root 权限启动内核（用于 TUN 模式）。

## 开发

1. 放置官方 `mihomo` 二进制文件到 `Contents/MacOS/mihomo`。
2. 运行 `bash make.sh` 打包。
