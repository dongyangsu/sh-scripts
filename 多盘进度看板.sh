#!/usr/bin/env bash
# 多盘 dd 进度看板：N 行原地跳动刷新，不刷屏、不进任何界面
#
# 用法:
#   ./多盘进度看板.sh sdb sdc sdd [sde ...]
#   ./多盘进度看板.sh --interval 2 sdb sdc
#   ./多盘进度看板.sh --log-dir /tmp sdb sdc
#
# 说明:
#   - 读取「多盘并行零填写入.sh」写出的 $LOGDIR/dd_<盘>.log
#   - 每行显示 dd 的原始进度文本，原地覆盖刷新
#   - Ctrl+C 只退出看板，不影响后台的 dd

set -u

INTERVAL=1
LOGDIR=${DD_LOG_DIR:-/tmp}
DISKS=()

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL="${2:?缺少刷新间隔}"; shift 2 ;;
        --log-dir)  LOGDIR="${2:?缺少日志目录}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        -*)         echo "未知参数: $1" >&2; usage; exit 1 ;;
        *)          DISKS+=("$1"); shift ;;
    esac
done

if [ ${#DISKS[@]} -eq 0 ]; then
    usage
    exit 1
fi

N=${#DISKS[@]}

# 先占好 N 行，之后每轮把光标上移 N 行原地重写
for _ in "${DISKS[@]}"; do echo; done

trap 'printf "\033[%dB" "$N"; exit 0' INT TERM

while :; do
    printf '\033[%dA' "$N"
    for d in "${DISKS[@]}"; do
        f="$LOGDIR/dd_$d.log"
        if [ -f "$f" ]; then
            last=$(tr '\r' '\n' < "$f" | tail -1)
        else
            last="(未开始)"
        fi
        [ -z "$last" ] && last="(等待数据)"
        printf '\r\033[2K%s %s\n' "$d" "$last"
    done
    sleep "$INTERVAL"
done
