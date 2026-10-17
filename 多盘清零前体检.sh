#!/usr/bin/env bash
# 清零前体检（只读）：确认盘符、容量、型号、序列号、挂载状态、SMART 关键项
# 不做任何写操作，用来避免「选错盘」和「选到坏盘」
#
# 用法:
#   ./多盘清零前体检.sh sdb sdc sdd [sde ...]
#   ./多盘清零前体检.sh --smart sdb sdc      # 额外读 SMART（需要 root/sudo）
#
# 输出:
#   盘符 | 是否块设备 | 容量 | 型号 | 序列号 | 挂载点 | 扇区大小 | SMART 05/197/198/199

set -u

WITH_SMART=0
DISKS=()

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --smart)   WITH_SMART=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "未知参数: $1" >&2; usage; exit 1 ;;
        *)         DISKS+=("$1"); shift ;;
    esac
done
[ ${#DISKS[@]} -gt 0 ] || { usage; exit 1; }

BAD=0

for d in "${DISKS[@]}"; do
    dev="/dev/$d"
    echo "==================== $d ===================="
    if [ ! -b "$dev" ]; then
        echo "❌ $dev 不存在或不是块设备"; BAD=1; continue
    fi
    size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
    gb=$(( size / 1000 / 1000 / 1000 ))
    info=$(lsblk -dno MODEL,SERIAL "$dev" 2>/dev/null)
    mp=$(findmnt -n -o TARGET --source "$dev" 2>/dev/null | head -1)
    sectors=$(blockdev --getss "$dev" 2>/dev/null || echo '?')
    echo "容量: ${gb} GB   扇区: ${sectors} B"
    echo "型号/序列号: ${info:-未知}"
    echo "挂载: ${mp:-未挂载 ✅}"
    if [ -n "$mp" ]; then BAD=1; fi

    if [ "$WITH_SMART" -eq 1 ]; then
        if command -v smartctl >/dev/null 2>&1; then
            out=$(sudo smartctl -A "$dev" 2>/dev/null || true)
            if [ -n "$out" ]; then
                printf '%s\n' "$out" | grep -Ei 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count' || echo "SMART: 未取到关键属性（可能是 SAS 盘，见 G-list）"
            else
                echo "SMART: 读取失败（可能需要 -d sat 或该盘不支持）"
            fi
        else
            echo "SMART: 未安装 smartctl"
        fi
    fi
done

echo
if [ "$BAD" -ne 0 ]; then
    echo "⚠️ 有盘不存在或处于挂载状态，请先处理再清零"
    exit 1
fi
echo "✅ 体检通过：所有指定盘都存在且未挂载"
