#!/usr/bin/env bash
# v4 2025-07-25 – interactive + batch + systemd timer
set -euo pipefail

################################################################################
#  参数（可自行修改）
################################################################################
PING_CNT=6
TIMEOUT=1
PRIO_BASE=100
HI_METRIC=200
MODE=icmp          # icmp / tcp
TCP_PORT=80
BATCH_FILE=""
################################################################################

################################################################################
#  command-line 解析 ── 支持交互 / 批量 / timer 管理
################################################################################
usage(){ cat <<EOF
用法:
  $0 [通用选项]

通用选项:
  -m, --mode icmp|tcp     探测方式 (默认 icmp)
  -p, --port <num>        TCP 模式端口 (默认 80)
  --batch <file>          批量静默刷新, 读取 file 每行一个 IP
  --install-timer <min> <file> [其他探测参数]
                          安装 systemd timer, 每 <min> 分钟批量刷新 <file>
  --remove-timer          停用并删除 systemd timer
  -h, --help              显示此帮助
EOF
exit 0; }

#--- 先分离 timer 子命令 -------------------------------------------------------
if [[ ${1-} == "--install-timer" ]]; then
  [[ $# -lt 3 ]] && { echo "用法: --install-timer <分钟> <targets.txt> [额外参数]"; exit 1; }
  MIN=$2; shift 2; TIMER_ARGS="$*"
  cat <<SERVICE | sudo tee /etc/systemd/system/lat-refresh.service >/dev/null
[Unit]
Description=Latency-aware routing refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(realpath "$0") --batch $TIMER_ARGS
SERVICE

  cat <<TIMER | sudo tee /etc/systemd/system/lat-refresh.timer >/dev/null
[Unit]
Description=Run latency refresh every $MIN minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${MIN}min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
TIMER
  sudo systemctl daemon-reload
  sudo systemctl enable --now lat-refresh.timer
  echo "[OK] 已安装并启动 lat-refresh.timer (每 $MIN 分钟运行)"
  exit 0
elif [[ ${1-} == "--remove-timer" ]]; then
  sudo systemctl disable --now lat-refresh.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/lat-refresh.{service,timer}
  sudo systemctl daemon-reload
  echo "[OK] timer 已移除"
  exit 0
fi

#--- 常规参数 ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    -m|--mode) MODE=$2; shift 2;;
    -p|--port) TCP_PORT=$2; shift 2;;
    --batch)   BATCH_FILE=$2; shift 2;;
    -h|--help) usage;;
    *) echo "未知参数 $1"; usage;;
  esac
done
[[ $MODE != icmp && $MODE != tcp ]] && { echo "MODE 必须 icmp 或 tcp"; exit 1; }

################################################################################
#  依赖检查
################################################################################
need(){ command -v "$1" &>/dev/null && return;
  echo "缺少 $1，自动安装..." ; sudo apt-get -qq update && sudo apt-get -y install "$1"; }
need bc; [[ $MODE == tcp ]] && need nc

################################################################################
#  公共函数：探测接口、建表、取 RTT
################################################################################
detect(){ ip -4 -o addr show up scope global | while read -r _ ifc _ addr _; do
  src=${addr%/*}; gw=$(ip r|awk -v d="$ifc" '$1=="default"&&$0~d{print $3;exit}')
  [[ -z $gw ]]&&gw="N/A"; echo "$ifc,$src,$gw";done; }

ICMP(){ ping -I "$1" -c $PING_CNT -W $TIMEOUT -q "$2" 2>/dev/null |
        awk -F'/' '/^rtt/{print $5}'; }
TCP(){ ( /usr/bin/time -f "%E" nc -G$TIMEOUT -w$TIMEOUT -s "$1" "$2" $TCP_PORT < /dev/null ) 2>&1 |
       awk -F: '/[0-9]/{split($0,t,":");print (t[1]*60+t[2])*1000}'; }
get_rtt(){ [[ $MODE == icmp ]] && ICMP "$@" || TCP "$@"; }

write_rule(){
  sudo ip rule del to "$1"/32 2>/dev/null || true
  sudo ip rule add to "$1"/32 lookup "tbl_$2" priority "$3"
}

#=========================== 批量模式 =========================================#
if [[ -n $BATCH_FILE ]]; then
  mapfile -t TARGETS < "$BATCH_FILE"
  # detect interfaces
  IFS=',' read -ra arr <<<"$(detect | paste -sd ',' -)"
  declare -a IFACES SRCIPS GWS
  for((i=0;i<${#arr[@]};i+=3));do IFACES+=("${arr[i]}"); SRCIPS+=("${arr[i+1]}"); GWS+=("${arr[i+2]}");done
  # build tables & high-metric defaults
  for idx in "${!IFACES[@]}"; do
    ifc=${IFACES[idx]} tbl="tbl_$ifc" gw=${GWS[idx]} id=$((200+idx))
    grep -q "[[:space:]]$tbl$" /etc/iproute2/rt_tables||echo "$id $tbl"|sudo tee -a /etc/iproute2/rt_tables >/dev/null
    subnet=$(ip -4 route show dev "$ifc" proto kernel scope link|awk 'NR==1{print $1}')
    sudo ip route flush table "$tbl" 2>/dev/null||true
    sudo ip route add "$subnet" dev "$ifc" scope link table "$tbl"
    if [[ $gw != N/A ]];then
      sudo ip route add default via "$gw" dev "$ifc" table "$tbl"
      sudo ip route replace default via "$gw" dev "$ifc" metric $HI_METRIC
    fi
  done

  prio=0
  for DST in "${TARGETS[@]}"; do
    best_if=""; best=999999
    for idx in "${!IFACES[@]}"; do
      ifc=${IFACES[idx]}; sip=${SRCIPS[idx]}
      r=$(get_rtt "$sip" "$DST"||true); [[ -z $r ]]&&r="∞"
      if [[ $r != ∞ ]]&&awk -v a=$r -v b=$best 'BEGIN{exit(a<b)?0:1}'; then
        best_if=$ifc; best=$r; fi
    done
    [[ $best_if ]] && write_rule "$DST" "$best_if" $((PRIO_BASE+prio*10))
    prio=$((prio+1))
  done
  exit 0
fi

################################################################################
#  >>> 交互模式（原功能，略）
################################################################################
# 归档：保持之前交互逻辑，篇幅省略……
# -- 这里你可以保留我们前一版完整的交互代码块 --
################################################################################
