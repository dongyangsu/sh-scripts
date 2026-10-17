#!/usr/bin/env bash
# 单窗口一体版：启动多盘并行清零，并在同一个终端里原地刷新每块盘的进度
# （不需要另开终端、不用 tmux、不刷屏）
#
# 用法:
#   ./多盘清零单窗看板.sh sdb sdc sdd [sde ...]
#   ./多盘清零单窗看板.sh --bs 32M sdb sdc
#   ./多盘清零单窗看板.sh --interval 2 sdb sdc
#
# 说明:
#   - 每个盘一个 dd，日志写入 $DD_LOG_DIR/dd_<盘>.log（默认 /tmp）
#   - Ctrl+C 只退出看板，后台 dd 继续跑；如需停止用「多盘并行零填写入.sh --stop 盘...」
#   - 与「多盘并行零填写入.sh + 多盘进度看板.sh」的区别：这是二合一，前台一条命令搞定

set -u

BS=24M
INTERVAL=1
LOGDIR=${DD_LOG_DIR:-/tmp}
DISKS=()

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bs)       BS="${2:?缺少块大小}"; shift 2 ;;
        --interval) INTERVAL="${2:?缺少刷新间隔}"; shift 2 ;;
        --log-dir)  LOGDIR="${2:?缺少日志目录}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        -*)         echo "未知参数: $1" >&2; usage; exit 1 ;;
        *)          DISKS+=("$1"); shift ;;
    esac
done
[ ${#DISKS[@]} -gt 0 ] || { usage; exit 1; }

mkdir -p "$LOGDIR"
STARTED=()

for d in "${DISKS[@]}"; do
    dev="/dev/$d"
    if [ ! -b "$dev" ]; then echo "跳过 $d：$dev 不存在或不是块设备" >&2; continue; fi
    if pgrep -f "dd if=/dev/zero of=$dev " >/dev/null 2>&1; then echo "跳过 $d：已有 dd 在跑" >&2; continue; fi
    sudo dd if=/dev/zero of="$dev" bs="$BS" status=progress > "$LOGDIR/dd_$d.log" 2>&1 &
    STARTED+=("$d")
done

if [ ${#STARTED[@]} -eq 0 ]; then echo "没有可启动的盘" >&2; exit 1; fi

N=${#STARTED[@]}
for _ in "${STARTED[@]}"; do echo; done
trap 'printf "\033[%dB" "$N"; echo "（看板已退出，后台 dd 仍在运行）"; exit 0' INT TERM

while :; do
    printf '\033[%dA' "$N"
    for d in "${STARTED[@]}"; do
        f="$LOGDIR/dd_$d.log"
        last=""
        [ -f "$f" ] && last=$(tr '\r' '\n' < "$f" | tail -1)
        [ -z "$last" ] && last="(等待数据)"
        printf '\r\033[2K%s %s\n' "$d" "$last"
    done
    sleep "$INTERVAL"
done
