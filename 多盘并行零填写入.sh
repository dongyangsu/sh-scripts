#!/usr/bin/env bash
# 多盘并行零填写入（dd if=/dev/zero），盘符由外部参数传入，数量不限
#
# 用法:
#   ./多盘并行零填写入.sh sdb sdc sdd [sde ...]
#   ./多盘并行零填写入.sh --bs 32M sdb sdc
#   ./多盘并行零填写入.sh --stop sdb sdc        # 停止指定盘上的 dd
#   ./多盘并行零填写入.sh --status sdb sdc      # 查看指定盘的当前进度
#
# 说明:
#   - 每个盘单独起一个 dd，输出写入 $DD_LOG_DIR/dd_<盘>.log（默认 /tmp）
#   - 配合「多盘进度看板.sh」可原地刷新查看进度
#   - 需要 sudo；已配置免密时不会提示密码

set -u

BS=24M
LOGDIR=${DD_LOG_DIR:-/tmp}
ACTION=start
DISKS=()

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bs)      BS="${2:?缺少块大小}"; shift 2 ;;
        --log-dir) LOGDIR="${2:?缺少日志目录}"; shift 2 ;;
        --stop)    ACTION=stop; shift ;;
        --status)  ACTION=status; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "未知参数: $1" >&2; usage; exit 1 ;;
        *)         DISKS+=("$1"); shift ;;
    esac
done

if [ ${#DISKS[@]} -eq 0 ]; then
    usage
    exit 1
fi

mkdir -p "$LOGDIR"

start_one() {
    local d="$1" dev="/dev/$1"
    if [ ! -b "$dev" ]; then
        echo "跳过 $d：$dev 不存在或不是块设备"
        return
    fi
    if pgrep -f "dd if=/dev/zero of=$dev " >/dev/null 2>&1; then
        echo "跳过 $d：该盘已有 dd 在运行"
        return
    fi
    sudo dd if=/dev/zero of="$dev" bs="$BS" status=progress > "$LOGDIR/dd_$d.log" 2>&1 &
    echo "已启动 $d (pid $!)  日志: $LOGDIR/dd_$d.log"
}

stop_one() {
    local d="$1" pids pids2
    pids=$(pgrep -f "dd if=/dev/zero of=/dev/$d " || true)
    if [ -z "$pids" ]; then
        echo "$d 没有在跑"
        return
    fi
    kill -TERM $pids 2>/dev/null || true
    sleep 2
    pids2=$(pgrep -f "dd if=/dev/zero of=/dev/$d " || true)
    [ -n "$pids2" ] && kill -9 $pids2 2>/dev/null || true
    echo "已停止 $d"
}

status_one() {
    local d="$1" f="$LOGDIR/dd_$d.log" last
    if [ ! -f "$f" ]; then
        echo "$d  (无日志)"
        return
    fi
    last=$(tr '\r' '\n' < "$f" | tail -1)
    [ -z "$last" ] && last="(等待数据)"
    printf '%s %s\n' "$d" "$last"
}

case "$ACTION" in
    start)
        for d in "${DISKS[@]}"; do start_one "$d"; done
        ;;
    stop)
        for d in "${DISKS[@]}"; do stop_one "$d"; done
        ;;
    status)
        for d in "${DISKS[@]}"; do status_one "$d"; done
        ;;
esac
