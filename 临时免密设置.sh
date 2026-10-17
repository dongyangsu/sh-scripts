#!/usr/bin/env bash
# 临时免密：刷新当前终端的 sudo 时间戳，短时间内 sudo 不再询问密码
#
# 用法:
#   ./临时免密设置.sh            # 刷新时间戳（会询问一次密码）
#   ./临时免密设置.sh --cancel   # 立即取消当前终端的免密
#   ./临时免密设置.sh --check    # 检查当前终端是否还处于免密有效期
#
# 说明:
#   - 仅对当前终端（tty）有效，默认有效期 15 分钟（由 sudoers 的 timestamp_timeout 决定）
#   - 换终端、重连 SSH、有效期过后都需要重新执行
#   - 与「永久免密设置.sh」不同：不改任何配置文件

set -eu

case "${1:-}" in
    ""|--add|-a)
        sudo -v
        echo "✅ 当前终端已临时免密（默认 15 分钟）"
        sudo -n true 2>/dev/null && echo "验证通过: sudo -n 可直接执行" || echo "⚠️ 验证未通过（可能 sudoers 配置了 timestamp_timeout=0）" >&2
        ;;
    --cancel|-k)
        sudo -k
        echo "✅ 已取消当前终端的 sudo 免密"
        ;;
    --check|-c)
        if sudo -n true 2>/dev/null; then
            echo "当前终端仍在免密有效期内"
        else
            echo "当前终端需要密码"
        fi
        ;;
    -h|--help)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "未知参数: $1" >&2
        exit 1
        ;;
esac
