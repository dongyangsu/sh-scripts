#!/usr/bin/env bash
# 指定用户免密设置：为「别人」配置/撤销 sudo 永久免密（需 root 或已有 sudo 权限执行）
#
# 用法:
#   ./指定用户免密设置.sh <用户名>              # 为该用户设置永久免密
#   ./指定用户免密设置.sh <用户名> --remove     # 撤销该用户的永久免密
#   ./指定用户免密设置.sh <用户名> --check      # 检查该用户是否已免密
#
# 说明:
#   - 写入 /etc/sudoers.d/010-<用户名>-nopasswd，不与其它文件冲突
#   - 写入前用 visudo -cf 校验，校验失败不落盘
#   - 与「永久免密设置.sh」的区别：那个只作用于当前用户，这个可以指定任意用户

set -eu

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -ge 1 ] || { usage; exit 1; }

TARGET="$1"
ACTION="${2:-add}"

if ! id "$TARGET" >/dev/null 2>&1; then
    echo "用户不存在: $TARGET" >&2
    exit 1
fi

F="/etc/sudoers.d/010-${TARGET}-nopasswd"

do_add() {
    local t
    t=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD: ***' "$TARGET" > "$t"
    if ! sudo visudo -cf "$t" >/dev/null; then
        echo "语法校验失败，未写入" >&2; rm -f "$t"; exit 1
    fi
    sudo install -o root -g root -m 0440 "$t" "$F"
    rm -f "$t"
    sudo visudo -c >/dev/null
    echo "✅ 已为 $TARGET 设置永久免密: $F"
}

do_remove() {
    if [ -f "$F" ]; then
        sudo rm -f "$F"
        sudo visudo -c >/dev/null
        echo "✅ 已撤销 $TARGET 的永久免密: $F"
    else
        echo "未找到 $F（该用户未配置永久免密）"
    fi
}

do_check() {
    if [ -f "$F" ]; then
        echo "已配置: $F"
        cat "$F"
    else
        echo "未配置永久免密"
    fi
}

case "$ACTION" in
    --remove|-r) do_remove ;;
    --check|-c)  do_check ;;
    add|--add|-a) do_add ;;
    *) echo "未知参数: $ACTION" >&2; usage; exit 1 ;;
esac
