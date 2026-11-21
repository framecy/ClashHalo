#!/usr/bin/env bash
# 独立审查：隐私（全历史）+ 功能回归。
#
# 为什么存在（2026-11-21）：本仓库经历过一次 git filter-repo 全历史脱敏
# （个人姓名/邮箱/真实网段/设备标识 → 匿名与示意值）。此后需要一个**不信任
# 任何前序结论**、在任意机器、任意 clone 上都能重跑的验证脚本——它从当前
# 仓库重新推导全部事实，而不是引用某次审查的输出。
#
# 用法：
#   bash Scripts/audit.sh               # 隐私五段 + 36 套全量回归
#   bash Scripts/audit.sh --no-tests    # 只做隐私部分（秒级）
#   bash Scripts/audit.sh --build       # 追加 Debug 编译验证
#
# 退出码：0 = 全绿；1 = 有命中/失败。一段红不中止其余（与 run-tests.sh 同纪律）。
#
# 维护约定：
# - 发现新的敏感值形态时，追加进 PRIVACY / SECRET 两个模式串；
# - 模式必须用可移植 ERE（BSD grep 兼容：禁用 \b、(?:)、(?!) 前瞻）；
# - 断言不得依赖开发机实时状态（网卡、网段、已装应用）；
# - 故意**不**扫 vmess:///ss:// 等分享链接 scheme：内置 Zashboard 的 vendored
#   源码里有大量协议模板串（hysteria2://…），按 scheme 扫历史全是假阳性；
#   真实节点凭据的防线由 pre-commit 的暂存区扫描 + 本脚本的凭据形态扫描承担。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_TESTS=1; RUN_BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-tests) RUN_TESTS=0; shift ;;
    --build)    RUN_BUILD=1; shift ;;
    *) echo "未知参数：$1（支持 --no-tests / --build）"; exit 2 ;;
  esac
done

pass=0; fail=0
declare -a RESULTS=()
ok()  { pass=$((pass+1)); RESULTS+=("PASS  $1"); printf "  ✓ %s\n" "$1"; }
bad() { fail=$((fail+1)); RESULTS+=("FAIL  $1"); printf "  ✗ %s\n" "$1"; }

# ──────────────────────────────────────────────────────────────────────
# Part 1：隐私审查
# ──────────────────────────────────────────────────────────────────────
echo "══ Part 1：隐私审查 ══"

# 1.1 提交身份：作者 / 提交者 / 附注标签 tagger 必须全部匿名。
#   隐私决策（2026-11-21）：个人姓名与邮箱全部重写为 GitHub noreply；
#   GitHub 网页端合并提交的 committer 保留官方 noreply；
#   Claude 协作署名（Co-Authored-By，noreply@anthropic.com）保留在消息里，
#   不算个人隐私，不出现在本断言的元数据口径中。
#   `^ <>$`：轻量标签没有 tagger，for-each-ref 的两个字段都为空——结构性
#   空串，不是身份泄漏。sed 归一化：`%(taggeremail)` 自带尖括号，与格式串
#   的尖括号叠成 `<<…>>`，去一层后与 log 行同形。
ALLOWED='^framecy <30614656\+framecy@users\.noreply\.github\.com>$|^GitHub <noreply@github\.com>$|^ <>$|^$'
leak="$( { git log --all --format='%an <%ae>%n%cn <%ce>';
           git for-each-ref --format='%(taggername) <%(taggeremail)>' refs/tags; } \
         | sed 's/<</</;s/>>/>/' | sort -u | grep -Ev "$ALLOWED" )"
if [ -n "$leak" ]; then
  bad "提交身份出现 allowlist 之外的姓名/邮箱：$(echo "$leak" | head -3 | tr '\n' ' ')"
else
  ok "提交身份全量匿名（作者/提交者/附注标签 tagger）"
fi

# 1.2 全历史敏感值：blob 内容 + 提交消息一起扫（git log -p 覆盖两者）。
#   口径对照 2026-11-21 的替换表：真实家庭网段组合、tailnet 对端、真实设备
#   MAC 尾缀、公网 IPv6 前缀、个人使用痕迹、疑似密钥样值、用户名路径。
#   [^0-9] 而不是前瞻：既命中三段裸缩写形式的目的地，又不误伤新值
#   （10.10.0.x、192.168.30.x、192.168.31.x）。
#   防自匹配：审查器自身提交入库后，它的源码会出现在全历史 diff 里——被
#   审查的字面量绝不能在文件字节中连续出现，否则每次审查命中它自己。所有
#   明文 token 一律用相邻字符串片段在运行时拼合（'a''b' == "ab"）。
PRIVACY='chace''justso''|clashpow\.dev|/Users/''chace''|(^|[^A-Za-z])''Ch''ace''([^A-Za-z]|$)|(^|[^A-Za-z])''ncase''9''([^A-Za-z]|$)|10\.1\.1([^0-9]|$)|100\.121\.91|192\.168\.3([^0-9]|$)|10\.99\.99|10\.20\.20\.0/24|172\.16\.10\.|172\.30\.0\.0/16|68:1b:''e9''|84:45:''e6''|2409:8a''3c''|''Blue''Stacks''|54c51d''410'
hist_hits="$(git log -p --all --no-color | grep -E "$PRIVACY" | head -5)"
if [ -n "$hist_hits" ]; then
  bad "全历史（blob+提交消息）仍有敏感值残留："
  echo "$hist_hits" | cut -c1-160 | sed 's/^/      /'
else
  ok "全历史（blob+提交消息，$(git rev-list --count --all) 提交）敏感值零残留"
fi

# 1.3 密钥形态宽扫（历史）：只认凭据形态，不认协议 scheme（见文件头维护约定）。
#   sk- 前缀必须锚在词边界上：内置面板的 Tailwind 产物里 mask- 开头的类名
#   内嵌 sk- 子串（前一个字符是字母），裸 sk- 会整片误报；词边界锚定后，
#   只有独立的 sk-<40+ 字符> 形态才算密钥。
SECRET='ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|ghs_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|tskey-(auth|api)-[A-Za-z0-9]{12,}'
secret_hits="$(git log -p --all --no-color | grep -E "$SECRET" | head -5)"
if [ -n "$secret_hits" ]; then
  bad "历史中存在凭据形态字符串："
  echo "$secret_hits" | cut -c1-160 | sed 's/^/      /'
else
  ok "历史凭据形态扫描零命中（PAT/OAuth/AWS/OpenAI/Tailscale key）"
fi

# 1.4 工作区 tracked 文件快扫（补 git log 覆盖不到的未提交状态）。
work_hits="$(git grep -I -E "$PRIVACY" -- . | head -5)"
if [ -n "$work_hits" ]; then
  bad "工作区 tracked 文件仍有敏感值："
  echo "$work_hits" | cut -c1-160 | sed 's/^/      /'
else
  ok "工作区 tracked 文件敏感值零残留"
fi

# 1.5 对象库健康：断链 / 悬空引用检查（防半途重写留下可恢复残片）。
fsck_out="$(git fsck --no-dangling --connectivity-only 2>&1)"
if [ -n "$fsck_out" ]; then
  bad "git fsck 报告问题：$(echo "$fsck_out" | head -2 | tr '\n' ' ')"
else
  ok "git fsck 对象库健康"
fi

# ──────────────────────────────────────────────────────────────────────
# Part 2：功能回归（独立于隐私段，红一段不中止另一段）
# ──────────────────────────────────────────────────────────────────────
if [ "$RUN_TESTS" = 1 ]; then
  echo ""
  echo "══ Part 2：全量回归套件 ══"
  if bash Scripts/run-tests.sh; then
    ok "回归套件全绿"
  else
    bad "回归套件存在失败/缺失（见上方输出）"
  fi
fi

if [ "$RUN_BUILD" = 1 ]; then
  echo ""
  echo "══ Part 3：Debug 编译 ══"
  if xcodebuild -project ClashHalo.xcodeproj -scheme ClashHalo \
      -configuration Debug build 2>&1 | grep -q "BUILD SUCCEEDED"; then
    ok "Debug 构建成功"
  else
    bad "Debug 构建失败"
  fi
fi

echo ""
echo "══════════════════════════════════════════════"
printf "审查汇总：PASS %d   FAIL %d\n" "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  echo "全部通过。"
  exit 0
fi
echo "存在未通过项。"
exit 1
