#!/usr/bin/env bash
# 历史应急脚本：把历史上入库过、曾在 291a239 被移出的回归测试套件重新物化到工作区。
#
# 注：`Tests/` 已重新纳入版本管理，新克隆的仓库可直接运行 `bash Scripts/run-tests.sh`，
# 本脚本仅在检出旧分支或历史提交时作为应急恢复工具保留。
#
#   bash Scripts/restore-tests.sh          物化缺失的套件（已存在的不动）
#   bash Scripts/restore-tests.sh --check  只报告状态，不写文件
#
# 注意：移出之后新增的套件从未入库（TUNLoopSentinel、KernelMemoryGuard、
# TUNDNSAddress、ApplyDrift、ConfigWriteAudit、ConnOrigin、ProviderProtocols …），
# 本脚本对它们无能为力，只能明确列出——那些套件目前只存在于写它们的那台机器上。
# 具体是哪几套由脚本按实际状态报告，不要在这里写死数量。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# 找到所有删除过 Tests/ 内容的提交（不止最近一次）：不同套件可能在不同时间
# 被移出，只取最近一次的父快照会漏掉更早删除的套件。逐个尝试各删除提交的
# 父快照，取第一个仍含该文件的版本（git log 默认新→旧，即最近版本优先）。
# 不写死 sha：仓库再整理一次，写死的 sha 就悄悄失效了。
DELETE_COMMITS="$(git log --all --diff-filter=D --format=%H -- 'Tests/*')"
if [ -z "$DELETE_COMMITS" ]; then
  echo "仓库历史里找不到 Tests/ 的删除记录，无需恢复。"
  exit 0
fi
NEWEST_DELETE="$(printf '%s\n' "$DELETE_COMMITS" | head -1)"

echo "Tests/ 于 $(git log -1 --format='%h %ad %s' --date=short "$NEWEST_DELETE") 移出仓库（最近一次）"
echo "逐个尝试各删除提交的父快照物化："
echo ""

restored=0
present=0

# 历史里存在过的全部 Tests 路径（跨多次提交去重）。
paths="$(git log --all --pretty=format: --name-only --diff-filter=AD -- 'Tests/*' \
         | sed '/^\s*$/d' | sort -u)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ -f "$f" ]; then
    present=$((present+1))
    printf "  已存在   %s\n" "$f"
    continue
  fi
  SRC_REV=""
  while IFS= read -r dc; do
    [ -n "$dc" ] || continue
    if git cat-file -e "$dc^:$f" 2>/dev/null; then SRC_REV="$dc^"; break; fi
  done <<< "$DELETE_COMMITS"
  if [ -n "$SRC_REV" ]; then
    if [ "$CHECK_ONLY" = 1 ]; then
      printf "  可恢复   %s\n" "$f"
    else
      mkdir -p "$(dirname "$f")"
      git show "$SRC_REV:$f" > "$f"
      printf "  已恢复   %s\n" "$f"
    fi
    restored=$((restored+1))
  else
    # 所有删除提交的父快照里都没有该路径：从未入库，历史里取不到。
    printf "  取不到   %s（所有删除提交的父快照里都没有该文件，无法恢复）\n" "$f"
  fi
done <<< "$paths"

echo ""
# 反向核对：磁盘上有、但历史里从来没有过的套件，才是真正无备份的那一批。
# 只看历史清单永远发现不了它们——它们从没进过清单。
declare -a LOCAL_ONLY=()
for f in Tests/*/main.swift; do
  [ -f "$f" ] || continue
  if ! printf '%s\n' "$paths" | grep -qx "$f"; then
    LOCAL_ONLY+=("$f")
  fi
done

if [ "${#LOCAL_ONLY[@]}" -gt 0 ]; then
  echo "以下套件只存在于这台机器：从未入库，也不在历史里，任何脚本都恢复不出来："
  for o in "${LOCAL_ONLY[@]}"; do echo "    $o"; done
  echo "要么自行备份，要么把 Tests/ 重新纳入仓库："
  echo "    删掉 .gitignore 里的 Tests/ 规则，然后 git add Tests/"
  echo ""
fi

if [ "$CHECK_ONLY" = 1 ] && [ "$restored" -gt 0 ]; then
  echo "$restored 套可恢复（未写入，去掉 --check 执行）。"
fi
echo "工作区套件数：$((present + restored)) 已就位 / $(printf '%s\n' "$paths" | sed '/^\s*$/d' | wc -l | tr -d ' ') 已知（历史内）"
echo "跑回归：bash Scripts/run-tests.sh"
