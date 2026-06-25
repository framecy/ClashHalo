#!/usr/bin/env bash
# ClashPow 自动化集成测试套件 (E2E Integration Tests)
# 用于自动化测试 App 逻辑：内核生命周期、系统代理状态、TUN 和网络恢复
# 运行前请确保 ClashPow 正在运行，且具有管理员权限

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}[INFO] $1${NC}"; }
log_pass() { echo -e "${GREEN}[PASS] $1${NC}"; }
log_fail() { echo -e "${RED}[FAIL] $1${NC}"; exit 1; }

# 获取当前活动的主网络接口 (Wi-Fi 或 Ethernet)
ACTIVE_IFACE=$(route get default | grep interface | awk '{print $2}')
if [ -z "$ACTIVE_IFACE" ]; then
    ACTIVE_IFACE="en0" # 默认 fallback
fi
NETWORK_SERVICE=$(networksetup -listallhardwareports | grep -B 1 "$ACTIVE_IFACE" | head -n 1 | sed 's/Hardware Port: //')

check_system_proxy() {
    # 检查 macOS 系统代理状态
    local state=$(scutil --proxy | grep HTTPEnable | awk '{print $3}')
    if [ "$state" == "1" ]; then echo "ON"; else echo "OFF"; fi
}

check_mihomo_process() {
    if pgrep -x "mihomo" > /dev/null; then echo "ALIVE"; else echo "DEAD"; fi
}

echo "========================================="
echo "  ClashPow 自动化集成测试开始"
echo "  检测到主网络接口: $ACTIVE_IFACE ($NETWORK_SERVICE)"
echo "========================================="

# 确保 App 正在运行
if ! pgrep -x "ClashHalo" > /dev/null; then
    log_info "正在启动 ClashPow..."
    open -a "ClashHalo" || open build/Release/ClashHalo.app
    sleep 3
fi

# ---------------------------------------------------------
# 测试 1：特权守护进程的 Dead Man's Switch 测试 (崩溃兜底清场机制)
# ---------------------------------------------------------
log_info "▶ 执行测试 1: 守护进程崩溃兜底机制 (Dead Man's Switch)"
INITIAL_PID=$(pgrep -x "mihomo" | head -n 1)

if [ -z "$INITIAL_PID" ]; then
    log_info "内核未运行，请在 App 中开启内核并启用系统代理，然后重新运行此脚本。"
    exit 1
fi

log_info "当前内核 PID: $INITIAL_PID"
log_info "强杀 ClashHalo App 模拟异常退出 (killall -9)..."
killall -9 ClashHalo || true
sleep 4 # 等待 XPC Helper 检测到连接断开并执行 handleClientExit

DEAD_PID=$(pgrep -x "mihomo" | head -n 1)
if [ -z "$DEAD_PID" ]; then
    log_pass "UI 崩溃后，守护进程 (Helper) 已成功自动杀死遗留的内核进程！"
else
    log_fail "UI 崩溃后，内核进程仍残留！PID: $DEAD_PID"
fi

PROXY_STATE_CRASH=$(check_system_proxy)
if [ "$PROXY_STATE_CRASH" == "OFF" ]; then
    log_pass "UI 崩溃后，守护进程 (Helper) 已成功自动清理系统代理！"
else
    log_fail "UI 崩溃后，系统代理未被清理，将导致断网黑洞！"
fi

log_info "重新启动 ClashHalo App..."
open -a "ClashHalo"
sleep 5

# ---------------------------------------------------------
# 测试 2：内核意外崩溃时的代理断网防护 (测试刚修复的 reconnect 逻辑)
# ---------------------------------------------------------
log_info "▶ 执行测试 2: 内核崩溃代理防死锁测试"
if [ "$(check_system_proxy)" == "OFF" ]; then
    log_info "系统代理未开启，请先在 UI 中开启系统代理！"
    exit 1
fi

log_info "模拟内核崩溃 (killall -9 mihomo)..."
sudo killall -9 mihomo
sleep 4 # 等待 App 的 reconnect() 轮询发现内核断开 (间隔 3 秒)

PROXY_STATE=$(check_system_proxy)
if [ "$PROXY_STATE" == "OFF" ]; then
    log_pass "检测到内核崩溃，已成功自动关闭系统代理防断网！"
else
    log_fail "内核崩溃后，系统代理仍然处于 ON 状态，存在断网死锁漏洞！"
fi

# 等待用户通过 UI 或后台拉起恢复内核
log_info "等待内核恢复运行以进行后续测试..."
while [ "$(check_mihomo_process)" == "DEAD" ]; do
    sleep 2
done
sleep 4 # 给 App 自动恢复代理的时间

PROXY_STATE_AFTER=$(check_system_proxy)
if [ "$PROXY_STATE_AFTER" == "ON" ]; then
    log_pass "内核恢复后，系统代理成功自动恢复！"
else
    log_fail "内核恢复后，系统代理未能自动恢复！"
fi

# ---------------------------------------------------------
# 测试 3：网络瞬断模拟 (测试 handleNetworkChange 代理保护逻辑)
# ---------------------------------------------------------
log_info "▶ 执行测试 3: 网络瞬断模拟"
if [ -z "$NETWORK_SERVICE" ]; then
    log_info "未找到对应的硬件端口，跳过网络测试"
else
    log_info "关闭网络接口 $NETWORK_SERVICE (模拟断网)..."
    sudo networksetup -setnetworkserviceenabled "$NETWORK_SERVICE" off
    sleep 3

    PROXY_STATE_OFFLINE=$(check_system_proxy)
    if [ "$PROXY_STATE_OFFLINE" == "OFF" ]; then
        log_pass "断网时自动关闭了系统代理！"
    else
        log_fail "断网时未能自动关闭系统代理！"
        # 错误恢复
        sudo networksetup -setnetworkserviceenabled "$NETWORK_SERVICE" on
    fi

    log_info "恢复网络接口 $NETWORK_SERVICE (模拟恢复)..."
    sudo networksetup -setnetworkserviceenabled "$NETWORK_SERVICE" on
    sleep 5 # 网络重连需要时间

    PROXY_STATE_ONLINE=$(check_system_proxy)
    if [ "$PROXY_STATE_ONLINE" == "ON" ]; then
        log_pass "网络恢复后自动重启了系统代理！"
    else
        log_fail "网络恢复后系统代理未能自动开启！"
    fi
fi

echo "========================================="
echo -e "${GREEN}  所有自动化集成测试均已通过！完美！${NC}"
echo "========================================="
