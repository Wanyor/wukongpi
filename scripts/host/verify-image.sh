#!/usr/bin/env bash
#
# 判断 out/ 里最新的镜像是否包含当前 HEAD 的全部提交。
#
# 依据是镜像文件名里的 -g<提交号>（由 mk-sd-image.sh 写入），所以
# 不解包、不需要 Docker、也不依赖 mtime —— git rebase 会重写所有文件
# 的 mtime，用「谁比谁新」判断镜像是否最新是不可靠的。
#
#   ./scripts/host/verify-image.sh              # 检查 out/ 里最新的镜像
#   ./scripts/host/verify-image.sh out/xxx.img  # 检查指定镜像
#
# 退出码：0 = 已包含 HEAD（或只差文档/宿主机脚本，不必重构建）
#         1 = 缺的提交会改变镜像内容，需要 make image
#         2 = 无法判定（镜像早于溯源功能 / 脏构建 / 历史分叉）
#
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$HOST_DIR/../.." && pwd)"
cd "$SRC_ROOT"

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 会影响镜像内容的路径。其余（README、LICENSE、scripts/host/…）改了
# 不需要重构建 —— 区分这两类正是这个脚本存在的意义。
AFFECTS=(board configs docker scripts/inner)

IMG="${1:-}"
if [ -z "$IMG" ]; then
    # 优先 .xz：那才是实际拿去烧录的产物，也是最后写出的
    IMG="$(ls -t out/*.img.xz 2>/dev/null | head -1 || true)"
    [ -n "$IMG" ] || IMG="$(ls -t out/*.img 2>/dev/null | head -1 || true)"
    [ -n "$IMG" ] || die "out/ 里没有镜像（先跑 make image）"
fi
[ -f "$IMG" ] || die "找不到文件: $IMG"

NAME="$(basename "$IMG")"

echo
echo "  镜像     : $NAME"
echo "  大小/时间: $(du -h "$IMG" | cut -f1)   $(ls -l "$IMG" | awk '{print $6, $7, $8}')"
echo

# ---- 从文件名解析提交号 ----
BASE="${NAME%.img.xz}"
BASE="${BASE%.img}"
DIRTY=""
case "$BASE" in
    *-dirty) DIRTY=1; BASE="${BASE%-dirty}" ;;
esac
SHORT=""
case "$BASE" in
    *-g*) SHORT="${BASE##*-g}" ;;
esac
# 不是纯十六进制就不是提交号（防止把别的后缀误当提交号）
case "$SHORT" in
    *[!0-9a-f]*) SHORT="" ;;
esac

if [ -z "$SHORT" ]; then
    cat >&2 <<'EOF'
[!] 这个镜像的文件名里没有提交号。

    它构建于「构建溯源」功能之前，无法判定里面是哪一版代码。
    重新跑一次 make image 就会带上 -g<提交号>。
EOF
    exit 2
fi

FULL="$(git rev-parse --verify --quiet "${SHORT}^{commit}" || true)"
[ -n "$FULL" ] || die "提交 ${SHORT} 不在本地仓库里（可能被 gc 回收，或这个镜像来自别的机器）"

HEAD_SHA="$(git rev-parse HEAD)"
echo "  镜像提交 : $(git log -1 --format='%h %s' "$FULL")"
echo "  当前 HEAD: $(git log -1 --format='%h %s' "$HEAD_SHA")"

if [ -n "$DIRTY" ]; then
    cat >&2 <<'EOF'

[!] 这个镜像是在工作区不干净时构建的（文件名带 -dirty）。

    脏工作区不对应任何提交，「包含哪些修改」没法用提交号回答。
    把改动提交（或 stash）后重新构建，才能得到可溯源的镜像。
EOF
    exit 2
fi

if [ "$FULL" = "$HEAD_SHA" ]; then
    echo
    echo "✓ 镜像就是当前 HEAD，包含全部修改。"
    exit 0
fi

if git merge-base --is-ancestor "$HEAD_SHA" "$FULL" 2>/dev/null; then
    echo
    echo "! 镜像比 HEAD 还新（HEAD 不是镜像提交的后代），本地代码可能被回退过。"
    echo "  建议重新构建以免混淆。"
    exit 2
fi

if ! git merge-base --is-ancestor "$FULL" "$HEAD_SHA" 2>/dev/null; then
    echo
    echo "! 镜像提交与 HEAD 分叉（不是祖先关系），无法用提交号判断。建议重新构建。"
    exit 2
fi

echo
echo "镜像落后于 HEAD，缺少的提交："
git log --oneline "$FULL..$HEAD_SHA" | sed 's/^/    /'
echo

AFFECT="$(git log --format='    %h %s' "$FULL..$HEAD_SHA" -- "${AFFECTS[@]}" || true)"
if [ -n "$AFFECT" ]; then
    echo "其中会改变镜像内容的（${AFFECTS[*]} 之下）："
    printf '%s\n' "$AFFECT"
    echo
    echo "-> 需要重新构建：make image"
    exit 1
fi

echo "缺的这些只改了文档 / 宿主机脚本（不在 ${AFFECTS[*]} 之下），"
echo "镜像内容不受影响，不必重构建。"
exit 0
