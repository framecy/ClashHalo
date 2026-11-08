#!/usr/bin/env bash
# 直连链路测量基线（P0）。
#
# 为什么需要它：会话 613e714a 里「TUN 每连接 +7.7ms」这个结论，是用 4ms RTT 的
# AliDNS 量出来的，随后被当成「TUN 的固定成本」推广。它不是固定的——代理拨号
# 那 1 个 RTT 随目标距离线性增长，国内站点 20~30ms 的 RTT 意味着 25~35ms 的真实
# 成本。没有可复现的对照，这类结论会一直靠记忆和巧合维持。
#
# 做法：拿同一家服务、同城、RTT 几乎相同的两个 IP 做对照——一个在
# tun.route-exclude-address 里（走物理网卡），一个不在（走 utun）。两者唯一的
# 差别就是「是否经代理拨号」，差值即 TUN 成本。
#
#   bash Scripts/perf-ab.sh            # 对照 + 逐阶段打点
#   bash Scripts/perf-ab.sh --full     # 追加 每连接 CPU 与 代理链路对照
#
# 只读：不写 config.yaml、不 PATCH 内核、不改系统代理。
set -uo pipefail

HOME=${HOME:-/Users/$(id -un)}
CFG="$HOME/Library/Application Support/ClashHalo/config.yaml"
SAMPLES=${SAMPLES:-7}
FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

[[ -f "$CFG" ]] || { echo "找不到运行配置：$CFG"; exit 1; }

# 对照用同一家服务的两个地址：AliDNS 的主/备，RTT 相同、证书相同。
# 必须是「真的走了物理网卡」的那个：排除表里的 /32 还混着 ping 目标与游戏服务器，
# 它们大多不提供 443，拿来当对照只会得到 nan。
excluded() { awk '/^[[:space:]]*-[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/32/{gsub(/[^0-9.\/]/,"");print}' "$CFG" | sed 's#/32##'; }
route_if() { /sbin/route -n get "$1" 2>/dev/null | awk '/interface:/{print $2}'; }
NATIVE_IP=""
for cand in "${NATIVE_IP:-223.5.5.5}" 223.5.5.5 $(excluded); do
  if [[ "$(route_if "$cand")" != "utun100" && -n "$(route_if "$cand")" ]]; then NATIVE_IP="$cand"; break; fi
done
NATIVE_IP=${NATIVE_IP:-223.5.5.5}
TUN_IP="223.6.6.6"
[[ "$NATIVE_IP" == "$TUN_IP" ]] && TUN_IP="223.5.5.5"

# 一条连接的分阶段耗时（毫秒）。用 curl 的 --trace-time，不依赖 tcpdump（需要 root）。
phase() { # $1=url -> "firstFlight tls"
  local out ff tls
  out=$(/usr/bin/curl -s -o /dev/null --max-time 8 -v --trace-time "$1" 2>&1)
  ff=$(printf '%s\n' "$out" | awk '
    /Client hello/ {split($1,a,":"); ch=a[1]*3600+a[2]*60+a[3]}
    /Server hello/ {split($1,a,":"); sh=a[1]*3600+a[2]*60+a[3]; printf "%.1f", (sh-ch)*1000; exit}')
  tls=$(printf '%s\n' "$out" | awk '
    /Connected to/ {split($1,a,":"); c=a[1]*3600+a[2]*60+a[3]}
    /SSL connection using/ {split($1,a,":"); s=a[1]*3600+a[2]*60+a[3]; printf "%.1f", (s-c)*1000; exit}')
  printf '%s %s\n' "${ff:-nan}" "${tls:-nan}"
}

median() { sort -n | awk '{v[NR]=$1} END{ if(NR==0){print "nan"; exit} print v[int((NR+1)/2)] }'; }

measure() { # $1=label $2=url
  local ff=() tls=()
  for ((i=0;i<SAMPLES;i++)); do
    read -r a b <<< "$(phase "$2")"
    ff+=("$a"); tls+=("$b")
  done
  printf '%-30s %8s %8s\n' "$1" "$(printf '%s\n' "${ff[@]}" | median)" "$(printf '%s\n' "${tls[@]}" | median)"
}

echo "配置: $CFG"
echo "对照: native=$NATIVE_IP ($(route_if "$NATIVE_IP"))  tun=$TUN_IP ($(route_if "$TUN_IP"))"
echo
printf '%-30s %8s %8s\n' "目标" "首飞ms" "TLSms"
printf '%-30s %8s %8s\n' "------------------------------" "--------" "--------"
measure "native $NATIVE_IP" "https://$NATIVE_IP"
measure "tun    $TUN_IP" "https://$TUN_IP"
measure "direct-rule www.baidu.com" "https://www.baidu.com"
measure "direct-rule www.aliyun.com" "https://www.aliyun.com"

echo
echo "首飞 = ClientHello→ServerHello（1 个 RTT + 代理拨号）。两者之差即 TUN 的每连接成本。"

if [[ $FULL -eq 1 ]]; then
  echo
  echo "── 每连接 CPU（各 200 次新建连接，取 mihomo 累计 CPU 差）──"
  PID=$(pgrep -f "ClashHalo/bin/mihomo" | head -1)
  if [[ -n "${PID:-}" ]]; then
    cpu() { /bin/ps -o time= -p "$PID" | awk -F'[:.]' '{print ($1*60+$2)*1000+$3}'; }
    run_batch() { local url=$1 n=$2 t0 t1; t0=$(cpu)
      for ((i=0;i<n;i++)); do /usr/bin/curl -s -o /dev/null --max-time 5 "$url"; done
      t1=$(cpu); echo $((t1-t0)); }
    a=$(run_batch "https://$NATIVE_IP" 200)
    b=$(run_batch "https://$TUN_IP" 200)
    echo "native: ${a}ms/200  tun: ${b}ms/200  差 $(( (b-a)/200 ))ms/连接"
  else
    echo "内核未运行，跳过"
  fi
  echo
  echo "── 代理链路对照 ──"
  measure "proxy  www.google.com" "https://www.google.com"
fi
