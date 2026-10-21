#!/usr/bin/env bash
# 把历史上入库过、后来被移出的回归测试套件重新物化到工作区。
#
# 背景：291a239「Tests/ 目录移出仓库（本地开发用，不再入库）」把 11 套测试从
# 版本管理里拿掉了。移出只动了索引，blob 仍在历史里，所以任何一次克隆都能
# 把它们取回来——但必须有人显式去做，否则 `Scripts/run-tests.sh` 会报 MISSING，
# 而一个跑不起来的回归套件等于没有回归套件。
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

# 找到最后一次删除 Tests/ 内容的提交，再从它的父提交取文件。
# 不写死 sha：仓库再整理一次，写死的 sha 就悄悄失效了。
DELETE_COMMIT="$(git log --all --diff-filter=D --format=%H -- 'Tests/*' | head -1)"
if [ -z "$DELETE_COMMIT" ]; then
  echo "仓库历史里找不到 Tests/ 的删除记录，无需恢复。"
  exit 0
fi

echo "Tests/ 于 $(git log -1 --format='%h %ad %s' --date=short "$DELETE_COMMIT") 移出仓库"
echo "从 $(git rev-parse --short "$DELETE_COMMIT^") 物化："
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
  if git cat-file -e "$DELETE_COMMIT^:$f" 2>/dev/null; then
    if [ "$CHECK_ONLY" = 1 ]; then
      printf "  可恢复   %s\n" "$f"
    else
      mkdir -p "$(dirname "$f")"
      git show "$DELETE_COMMIT^:$f" > "$f"
      printf "  已恢复   %s\n" "$f"
    fi
    restored=$((restored+1))
  else
    # 在 DELETE_COMMIT 之后才加入又再删掉的路径，历史里取不到。
    printf "  取不到   %s（%s 里没有该文件，无法恢复）\n" "$f" "$(git rev-parse --short "$DELETE_COMMIT^")"
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
