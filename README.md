# ClashPow

> macOS 14+ Apple Silicon 原生代理 GUI 客户端，完整封装 mihomo (Clash.Meta) 内核。

## 系统要求

- macOS 14.0+
- Apple Silicon (M1/M2/M3/M4)

## 开发

```bash
# 初始化
bash setup.sh

# 构建引擎
cd Engine && go build -o /tmp/clashpow-engine ./cmd/clashpow/

# 构建 GUI
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug build

# 安装引擎守护进程
bash Scripts/install.sh --dev
```
