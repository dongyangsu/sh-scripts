#!/usr/bin/env bash
# 永久免密：为当前用户写入 /etc/sudoers.d/010-<用户>-nopasswd，之后 sudo 不再询问密码
#
# 用法:
#   ./永久免密设置.sh            # 设置永久免密
#   ./永久免密设置.sh --remove   # 撤销永久免密（删除该 sudoers 文件）
#   ./永久免密设置.sh --check    # 检查当前是否已免密
#
# 说明:
#   - 写入前用 visudo -cf 校验，校验失败不会落盘
#   - 会保留 /etc/sudoers.d 下其它文件，不做覆盖
#   - 风险：本机任何人登录该账号即等同 root，请自行评估

set -eu

U=$(id -un)
F="/etc/sudoers.d/010-${U}-nopasswd"

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

do_add() {
    local t
    t=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD: ***' "$U" > "$t"
    if ! sudo visudo -cf "$t" >/dev/null; then
        echo "语法校验失败，未写入" >&2
        rm -f "$t"
        exit 1
    fi
    sudo install -o root -g root -m 0440 "$t" "$F"
    rm -f "$t"
    sudo visudo -c >/dev/null
    if sudo -n true 2>/dev/null; then
        echo "✅ 已设置永久免密: $F"
    else
        echo "⚠️ 已写入 $F，但 sudo -n 仍要求密码，请检查 /etc/sudoers 或 sudo 版本" >&2
        exit 1
    fi
}

do_remove() {
    if [ -f "$F" ]; then
        sudo rm -f "$F"
        sudo visudo -c >/dev/null
        echo "✅ 已撤销永久免密: $F"
    else
        echo "未找到 $F（当前未配置永久免密）"
    fi
}

do_check() {
    if [ -f "$F" ] && sudo -n true 2>/dev/null; then
        echo "当前已免密: $F"
        cat "$F"
    else
        echo "当前未免密（或需要密码）"
    fi
}

case "${1:-}" in
    ""|--add|-a)  do_add ;;
    --remove|-r)  do_remove ;;
    --check|-c)   do_check ;;
    -h|--help)    usage ;;
    *)            echo "未知参数: $1" >&2; usage; exit 1 ;;
esac
