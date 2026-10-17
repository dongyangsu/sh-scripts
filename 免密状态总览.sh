#!/usr/bin/env bash
# 免密状态总览（只读）：一句话看清当前 sudo 到底是「永久免密 / 临时免密 / 需要密码」
#
# 用法:
#   ./免密状态总览.sh
#
# 检查项:
#   1. 当前用户与终端
#   2. sudo -n 是否可直接执行（即时判断）
#   3. /etc/sudoers.d 下与免密相关的文件
#   4. sudoers 中是否含 NOPASSWD 规则
#   5. 当前终端的 sudo 时间戳是否仍在有效期
#   6. timestamp_timeout 配置
#
# 说明: 全部为只读检查，不修改任何配置

set -u

U=$(id -un)
TTY=$(tty 2>/dev/null || echo '非交互/未知')

echo "用户: $U"
echo "终端: $TTY"
echo

echo "--- 1) 即时判断 ---"
if sudo -n true 2>/dev/null; then
    echo "✅ 当前 sudo -n 可直接执行（不需要密码）"
    INSTANT=ok
else
    echo "❌ sudo -n 需要密码"
    INSTANT=no
fi
echo

echo "--- 2) sudoers.d 中的免密文件 ---"
FOUND=0
for f in /etc/sudoers.d/*; do
    [ -e "$f" ] || continue
    if sudo grep -qi 'NOPASSWD' "$f" 2>/dev/null; then
        echo "  $f"
        sudo grep -i 'NOPASSWD' "$f" 2>/dev/null | sed 's/^/    /'
        FOUND=1
    fi
done
[ "$FOUND" -eq 0 ] && echo "  （无）"
echo

echo "--- 3) /etc/sudoers 主文件中的免密规则 ---"
if sudo grep -qi 'NOPASSWD' /etc/sudoers 2>/dev/null; then
    sudo grep -i 'NOPASSWD' /etc/sudoers | sed 's/^/  /'
else
    echo "  （无）"
fi
echo

echo "--- 4) timestamp_timeout ---"
TT=$(sudo grep -rhi 'timestamp_timeout' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | head -3)
if [ -n "$TT" ]; then
    echo "$TT" | sed 's/^/  /'
else
    echo "  未显式配置 → 默认 15 分钟"
fi
echo

echo "--- 5) 结论 ---"
if [ "$INSTANT" = ok ]; then
    if [ "$FOUND" -eq 1 ]; then
        echo "  ✅ 已配置永久免密（sudoers.d 有 NOPASSWD 规则）"
    else
        echo "  ✅ 当前处于临时免密有效期（时间戳未过期），或 sudoers 主文件有规则"
    fi
else
    echo "  ⚠️ 当前需要密码：可用「永久免密设置.sh」或「临时免密设置.sh」"
fi
