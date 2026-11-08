#!/usr/bin/env bash
# L1 层：route-exclude-address 的多源合并与归属记录（对着真实内核跑）。
#
# 为什么需要它：`directexclude-tests` 只钉住了纯函数，而这条链路上真正的风险在
# 三处真实调用（applyTUNState / reconcileCoexistenceIfChanged / SDWAN 一键修复）
# 和一份**跨进程持久化**的归属记录。记录一旦和运行配置不一致，后果是静默撤回或
# 永久固化——两者都不报错，只在某天"路由莫名其妙不对"时被发现。
#
# 用法：
#   bash Scripts/tun-exclusion-test.sh            # 只跑纯逻辑断言，不动系统
#   bash Scripts/tun-exclusion-test.sh --apply    # 追加：真实 PATCH 一轮 + 收敛记录
#   bash Scripts/tun-exclusion-test.sh --apply --probe 180.101.0.0/16
#
# --apply 会改 `tun.route-exclude-address` 并在结束时还原（失败也还原）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$HOME/Library/Application Support/ClashHalo/config.yaml"
APPLY=0; PROBE="180.101.0.0/16"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --probe) PROBE="$2"; shift 2 ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac
done

[[ -f "$CFG" ]] || { echo "找不到运行配置：$CFG"; exit 1; }
# 配置里 external-controller 是带引号的（'127.0.0.1:9090'）。用 -F 切会把端口切掉，
# 用 sub 去掉键名再剥引号。
CTRL=$(awk '/^external-controller:/{sub(/^external-controller:[[:space:]]*/,""); print; exit}' "$CFG" | /usr/bin/tr -d "'\"")
SECRET=$(awk '/^secret:/{sub(/^secret:[[:space:]]*/,""); print; exit}' "$CFG" | /usr/bin/tr -d "'\"")
API="http://$CTRL"
api() { /usr/bin/curl -s -m 8 -H "Authorization: Bearer $SECRET" "$API$1"; }
httpcode() { /usr/bin/curl -s -m 10 -o /tmp/tex.out -w '%{http_code}' -X "$1" -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d @"$2" "$API$3"; }

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1"; }

# ── 纯逻辑：编译生产源码，不重写规则 ───────────────────────────────
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

// 与 Tests/DirectExclusionPlanner 同一套生产源码，但这里只用隔离的 field，
// 不碰真实记录；真实记录的收敛由脚本用 defaults 完成。
var failures = 0
func expect(_ c: Bool, _ what: String) {
    if c { print("OK \(what)") } else { failures += 1; print("FAIL \(what)") }
}
let field = "l1test.route-exclude-address"
CoexistenceProvenance.commitProvenance(field: field, injected: [])

let user = ["10.0.0.0/8", "223.5.5.5/32"]
var r = RouteExclusionMerge.merge(
    sources: RouteExclusionSources(peer: ["100.64.0.0/10"], direct: ["1.2.3.0/24"]),
    existing: user, field: field)
expect(r.merged == ["1.2.3.0/24", "10.0.0.0/8", "100.64.0.0/10", "223.5.5.5/32"], "并集保留用户条目")
expect(r.injected == ["1.2.3.0/24", "100.64.0.0/10"], "injected 只含新增")
CoexistenceProvenance.commitProvenance(field: field, injected: r.record)

// 第二轮：对端消失，直连仍在。记录必须是"至今认领"，不能退化成本轮新增。
r = RouteExclusionMerge.merge(
    sources: RouteExclusionSources(peer: [], direct: ["1.2.3.0/24"]),
    existing: r.merged, field: field)
expect(r.record == ["1.2.3.0/24"], "第二轮记录不丢上一轮的认领（nextRecord）")
expect(r.merged.contains("10.0.0.0/8"), "用户手写条目不被撤回")
expect(!r.merged.contains("100.64.0.0/10"), "不再需要的对端条目被撤回")
CoexistenceProvenance.commitProvenance(field: field, injected: r.record)

// 撤回
let kept = RouteExclusionMerge.withdraw(existing: r.merged, field: field)
expect(!kept.contains("1.2.3.0/24"), "TUN 关闭时撤回自己的条目")
expect(kept.contains("223.5.5.5/32"), "用户条目存活")

// 幂等：同一份输入连续两次合并结果一致
let a = RouteExclusionMerge.merge(sources: RouteExclusionSources(peer: ["100.64.0.0/10"]),
                                  existing: user, field: field).merged
let b = RouteExclusionMerge.merge(sources: RouteExclusionSources(peer: ["100.64.0.0/10"]),
                                  existing: user, field: field).merged
expect(a == b, "合并幂等")

UserDefaults.standard.removeObject(forKey: "coexistence.injected." + field)
exit(failures == 0 ? 0 : 1)
SWIFT

echo "── 纯逻辑（编译生产源码）──"
if /usr/bin/swiftc -O -o "$TMP/l1"   "$ROOT/Sources/XPC/HelperProtocol.swift"   "$ROOT/Sources/Model/RuleNode.swift"   "$ROOT/Sources/Model/CoexistenceProvenance.swift"   "$ROOT/Sources/Model/RouteExclusions.swift"   "$TMP/main.swift" 2> "$TMP/cc.log"; then
  if "$TMP/l1" > "$TMP/out.txt" 2>&1; then
    while IFS= read -r line; do ok "${line#OK }"; done < <(/usr/bin/grep '^OK ' "$TMP/out.txt")
    fail=$((fail + $(/usr/bin/grep -c '^FAIL ' "$TMP/out.txt" || true)))
    /usr/bin/grep '^FAIL ' "$TMP/out.txt" | sed 's/^FAIL /  ✗ /' || true
  else
    bad "纯逻辑断言失败"
    /usr/bin/grep '^FAIL ' "$TMP/out.txt" | sed 's/^FAIL /     /' || true
  fi
else
  bad "编译失败（生产源码无法单独编译，先修这个）"
  head -5 "$TMP/cc.log"
fi

# ── 记录与运行配置一致性 ───────────────────────────────────────────
echo
echo "── 归属记录 vs 运行配置 ──"
LIVE=$(api /configs | /usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["tun"].get("route-exclude-address",[])))' 2>/dev/null)
if [[ -z "$LIVE" ]]; then bad "拿不到运行配置里的 route-exclude-address"; else
  REC=$(/usr/bin/defaults read com.clashhalo.app coexistence.injected.route-exclude-address 2>/dev/null \
        | /usr/bin/tr -d '(),"' | /usr/bin/tr -s ' \n' '\n' | /usr/bin/grep -v '^$' || true)
  STALE=""
  for e in $REC; do
    /usr/bin/grep -qxF "$e" <<< "$LIVE" || STALE="$STALE $e"
  done
  if [[ -z "${STALE// /}" ]]; then
    ok "记录中的条目都在运行配置里"
  else
    bad "记录里有 $(echo $STALE | wc -w | tr -d ' ') 条已不在运行配置：$STALE"
    if [[ $APPLY -eq 1 ]]; then
      KEEP=""
      for e in $REC; do /usr/bin/grep -qxF "$e" <<< "$LIVE" && KEEP="$KEEP $e"; done
      KEEP=$(echo $KEEP | /usr/bin/tr ' ' '\n')
      if [[ -z "$KEEP" ]]; then /usr/bin/defaults delete com.clashhalo.app coexistence.injected.route-exclude-address 2>/dev/null || true
      else /usr/bin/defaults write com.clashhalo.app coexistence.injected.route-exclude-address -array $KEEP; fi
      ok "已收敛：记录 := 记录 ∩ 运行配置"
    fi
  fi
fi

# ── 真实 PATCH 一轮 ────────────────────────────────────────────────
if [[ $APPLY -eq 1 ]]; then
  echo
  echo "── 真实 PATCH（探针 $PROBE）──"
  TUN_JSON=$(api /configs | /usr/bin/python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["tun"]))')
  echo "$TUN_JSON" > "$TMP/tun-before.json"
  # 完整重述 tun 块（PATCH 对嵌套对象是整块替换）；去掉内核派生字段与会导致 400 的字段
  /usr/bin/python3 - "$TMP/tun-before.json" "$PROBE" > "$TMP/tun-add.json" <<'PY'
import json,sys
t=json.load(open(sys.argv[1]))
for k in ("file-descriptor","inet4-address","processors-per-channel"): t.pop(k,None)
t["route-exclude-address"]=sorted(set(t.get("route-exclude-address",[]))|{sys.argv[2]})
print(json.dumps({"tun":t}))
PY
  /usr/bin/python3 - "$TMP/tun-before.json" > "$TMP/tun-restore.json" <<'PY'
import json,sys
t=json.load(open(sys.argv[1]))
for k in ("file-descriptor","inet4-address","processors-per-channel"): t.pop(k,None)
print(json.dumps({"tun":t}))
PY
  PROBE_IP=$(echo "$PROBE" | /usr/bin/cut -d/ -f1 | /usr/bin/awk -F. '{print $1"."$2"."$3".73"}')
  code=$(httpcode PATCH "$TMP/tun-add.json" /configs)
  [[ "$code" == "204" ]] && ok "PATCH 接受（204）" || bad "PATCH 被拒：$code $(head -c 120 /tmp/tex.out)"
  sleep 1
  iface=$(/sbin/route -n get "$PROBE_IP" 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')
  [[ "$iface" == "en0" ]] && ok "$PROBE_IP 已绕出隧道（en0）" || bad "$PROBE_IP 仍走 $iface"
  code=$(httpcode PATCH "$TMP/tun-restore.json" /configs)
  [[ "$code" == "204" ]] && ok "还原 PATCH 接受（204）" || bad "还原被拒：$code"
  sleep 1
  iface=$(/sbin/route -n get "$PROBE_IP" 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')
  [[ "$iface" == "utun100" ]] && ok "还原后回到隧道" || bad "还原后仍是 $iface（需要人工关开一次 TUN）"
  AFTER=$(api /configs | /usr/bin/python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin)["tun"].get("route-exclude-address",[]))))')
  BEFORE=$(/usr/bin/python3 -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1]))["route-exclude-address"])))' "$TMP/tun-before.json")
  [[ "$AFTER" == "$BEFORE" ]] && ok "排除表逐条还原" || bad "排除表与操作前不一致"
fi

echo
echo "通过 $pass，失败 $fail"
[[ $fail -eq 0 ]] || exit 1
