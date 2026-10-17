#!/usr/bin/env bash
# 顺序清零：一块盘写完后才开始下一块，降低多盘并发带来的链路/供电压力
# 适合「并行时容易掉盘」的机器
#
# 用法:
#   ./多盘顺序零填写入.sh sdb sdc sdd [sde ...]
#   ./多盘顺序零填写入.sh --bs 32M sdb sdc
#   ./多盘顺序零填写入.sh --force sdb sdc      # 跳过挂载检查
#
# 说明:
#   - 前台逐个盘执行 dd，可直接看到每块盘的进度
#   - 每块盘开始前会检查：是否为块设备、是否被挂载
#   - 最后打印汇总（成功/失败/耗时）

set -u

BS=24M
FORCE=0
LOGDIR=${DD_LOG_DIR:-/tmp}
DISKS=()

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bs)      BS="${2:?缺少块大小}"; shift 2 ;;
        --force)   FORCE=1; shift ;;
        --log-dir) LOGDIR="${2:?缺少日志目录}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "未知参数: $1" >&2; usage; exit 1 ;;
        *)         DISKS+=("$1"); shift ;;
    esac
done
[ ${#DISKS[@]} -gt 0 ] || { usage; exit 1; }
mkdir -p "$LOGDIR"

OK=(); FAIL=(); SKIP=()

for d in "${DISKS[@]}"; do
    dev="/dev/$d"
    echo "==================== $d ===================="
    if [ ! -b "$dev" ]; then
        echo "跳过：$dev 不存在或不是块设备"; SKIP+=("$d"); continue
    fi
    mp=$(findmnt -n -o TARGET --source "$dev" 2>/dev/null | head -1)
    if [ -n "$mp" ] && [ "$FORCE" -eq 0 ]; then
        echo "跳过：$dev 正在挂载于 $mp（确认无误可加 --force）"; SKIP+=("$d"); continue
    fi
    size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
    echo "容量: $(( size / 1024 / 1024 / 1024 )) GB，块大小 $BS，开始写入..."
    t0=$(date +%s)
    if sudo dd if=/dev/zero of="$dev" bs="$BS" status=progress 2>&1 | tee "$LOGDIR/dd_$d.log"; then
        t1=$(date +%s); echo "✅ $d 完成，用时 $((t1 - t0)) 秒"; OK+=("$d")
    else
        t1=$(date +%s); echo "❌ $d 失败（用时 $((t1 - t0)) 秒），见 $LOGDIR/dd_$d.log" >&2; FAIL+=("$d")
    fi
done

echo
echo "=========== 汇总 ==========="
echo "成功: ${OK[*]:-无}"
echo "失败: ${FAIL[*]:-无}"
echo "跳过: ${SKIP[*]:-无}"
[ ${#FAIL[@]} -eq 0 ]
