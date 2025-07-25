#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────
# Latency-aware multi-NIC routing helper
# v4 2025-07-25  (interactive + batch + systemd-timer)
# --------------------------------------------------------------------
set -euo pipefail

# ============================= 参数 ============================== #
PING_CNT=6
TIMEOUT=1
PRIO_BASE=100
HI_METRIC=200
MODE=icmp          # icmp | tcp
TCP_PORT=80
BATCH_FILE=""
# ================================================================= #

# ---------- 依赖检查 ----------
need() { command -v "$1" &>/dev/null && return;
  echo "[INFO] Installing $1 ..."; sudo apt-get -qq update && sudo apt-get -y install "$1"; }
need bc

# ---------- TIMER 子命令 ----------
if [[ ${1-} == --install-timer ]]; then
  [[ $# -lt 3 ]] && { echo "用法: --install-timer <分钟> <targets.txt> [额外参数]"; exit 1; }
  MIN=$2; shift 2
  TIMER_ARGS="$*"
  sudo tee /etc/systemd/system/lat-refresh.service >/dev/null <<SERVICE
[Unit]
Description=Latency-aware routing refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(realpath "$0") --batch $TIMER_ARGS
SERVICE

  sudo tee /etc/systemd/system/lat-refresh.timer >/dev/null <<TIMER
[Unit]
Description=Latency refresh every ${MIN}min
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
  echo "[OK] systemd timer installed (每 ${MIN} 分钟刷新)"
  exit 0
elif [[ ${1-} == --remove-timer ]]; then
  sudo systemctl disable --now lat-refresh.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/lat-refresh.{service,timer}
  sudo systemctl daemon-reload
  echo "[OK] timer 已移除"
  exit 0
fi

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case $1 in
    -m|--mode)  MODE=$2; shift 2;;
    -p|--port)  TCP_PORT=$2; shift 2;;
    --batch)    BATCH_FILE=$2; shift 2;;
    -h|--help)  echo "用法: $0 [-m icmp|tcp] [-p port] [--batch file]"; exit 0;;
    *) echo "未知参数 $1"; exit 1;;
  esac
done
[[ $MODE == tcp ]] && need nc

# ---------- 公共函数 ----------
detect() { ip -4 -o addr show up scope global \
  | while read -r _ i _ a _; do src=${a%/*}; gw=$(ip r|awk -v d="$i" '$1=="default"&&$0~d{print $3;exit}'); [[ -z $gw ]]&&gw="N/A"; echo "$i,$src,$gw"; done; }

icmp_rtt() { ping -I "$1" -c $PING_CNT -W $TIMEOUT -q "$2" 2>/dev/null | awk -F'/' '/^rtt/{print $5}'; }
tcp_rtt()  { ( /usr/bin/time -f "%E" nc -G$TIMEOUT -w$TIMEOUT -s "$1" "$2" $TCP_PORT < /dev/null ) 2>&1 \
             | awk -F: '/[0-9]/{split($0,t,":");print (t[1]*60+t[2])*1000}'; }
get_rtt()   { [[ $MODE == icmp ]] && icmp_rtt "$@" || tcp_rtt "$@"; }

build_tables() {
  for idx in "${!IFACES[@]}"; do
    ifc=${IFACES[idx]} tbl="tbl_$ifc" gw=${GWS[idx]} tid=$((200+idx))
    grep -q "[[:space:]]$tbl$" /etc/systemd/system/../../../../../etc/iproute2/rt_tables || \
        echo "$tid $tbl" | sudo tee -a /etc/iproute2/rt_tables >/dev/null
    subnet=$(ip -4 route show dev "$ifc" proto kernel scope link | awk 'NR==1{print $1}')
    sudo ip route flush table "$tbl" 2>/dev/null || true
    sudo ip route add "$subnet" dev "$ifc" scope link table "$tbl"
    if [[ $gw != N/A ]]; then
      sudo ip route add default via "$gw" dev "$ifc" table "$tbl"
      sudo ip route replace default via "$gw" dev "$ifc" metric $HI_METRIC
    fi
  done
}

write_rule() {
  sudo ip rule del to "$1"/32 2>/dev/null || true
  sudo ip rule add to "$1"/32 lookup "tbl_$2" priority "$3"
}

# ===================== 批量模式 ===================== #
if [[ -n $BATCH_FILE ]]; then
  mapfile -t TARGETS < "$BATCH_FILE"
  IFS=',' read -ra arr <<<"$(detect | paste -sd ',' -)"
  declare -a IFACES SRCIPS GWS
  for ((i=0;i<${#arr[@]};i+=3)); do
    IFACES+=("${arr[i]}") SRCIPS+=("${arr[i+1]}") GWS+=("${arr[i+2]}")
  done
  build_tables
  prio=0
  for DST in "${TARGETS[@]}"; do
    best_if=""; best=999999
    for idx in "${!IFACES[@]}"; do
      r=$(get_rtt "${SRCIPS[idx]}" "$DST" || true); [[ -z $r ]] && r="∞"
      if [[ $r != ∞ ]] && awk -v a=$r -v b=$best 'BEGIN{exit(a<b)?0:1}'; then
        best_if=${IFACES[idx]} best=$r
      fi
    done
    [[ $best_if ]] && write_rule "$DST" "$best_if" $((PRIO_BASE+prio*10))
    prio=$((prio+1))
  done
  exit 0
fi

# ===================== 交互模式 ===================== #
IFS=',' read -ra flat <<<"$(detect | paste -sd ',' -)"
declare -a IFACES SRCIPS GWS
for ((i=0;i<${#flat[@]};i+=3)); do
  IFACES+=("${flat[i]}") SRCIPS+=("${flat[i+1]}") GWS+=("${flat[i+2]}")
done
print_hdr(){ printf "  %-3s %-8s %-15s %-15s\n" "#" IFACE SRC_IP GATEWAY; }
print_lst(){ for i in "${!IFACES[@]}"; do printf "  %-3d %-8s %-15s %-15s\n" "$i" "${IFACES[i]}" "${SRCIPS[i]}" "${GWS[i]}"; done; }

echo -e "\n[INFO] 检测到出口:"; print_hdr; print_lst
read -rp $'\n<Enter>确认 / n 调整: ' ans
if [[ $ans =~ [Nn] ]]; then
  while :; do
    echo; print_hdr; print_lst; echo "(a)添加 (d)删除 (e)编辑 (q)继续)"
    read -rp "选: " op
    case $op in
      a|A) read -rp "IF: " ifc; read -rp "SRC: " sip; read -rp "GW: " gw
           IFACES+=("$ifc") SRCIPS+=("$sip") GWS+=("$gw");;
      d|D) read -rp "编号: " n; unset "IFACES[n]" "SRCIPS[n]" "GWS[n]"
           IFACES=("${IFACES[@]}") SRCIPS=("${SRCIPS[@]}") GWS=("${GWS[@]}");;
      e|E) read -rp "编号: " n; [[ -z ${IFACES[n]-} ]] && continue
           read -rp "新IF(留空跳过): " x; [[ $x ]] && IFACES[n]=$x
           read -rp "新SRC: " y; [[ $y ]] && SRCIPS[n]=$y
           read -rp "新GW : " z; [[ $z ]] && GWS[n]=$z;;
      q|Q) break;;
    esac
  done
fi
build_tables
echo "[INFO] 表已创建; 当前模式: $MODE (端口 $TCP_PORT)"

prio=0
while :; do
  echo
  read -rp "目标IP(空退出, m=切换, port N=改端口): " DST
  case $DST in
    '') exit 0;;
    m) MODE=$([[ $MODE == icmp ]] && echo tcp || echo icmp)
       [[ $MODE == tcp ]] && need nc
       echo ">> 模式改为 $MODE"; continue;;
    port*) TCP_PORT=${DST#port }; echo ">> 端口改为 $TCP_PORT"; continue;;
  esac

  best_if=""
  best=999999
  declare -A RTT
  for idx in "${!IFACES[@]}"; do
    r=$(get_rtt "${SRCIPS[idx]}" "$DST" || true); [[ -z $r ]] && r="∞"
    RTT[${IFACES[idx]}]=$r
    if [[ $r != ∞ ]] && awk -v a=$r -v b=$best 'BEGIN{exit(a<b)?0:1}'; then
      best_if=${IFACES[idx]} best=$r
    fi
  done

  echo -e "\n[结果] $MODE RTT(ms)"
  for ifc in "${IFACES[@]}"; do printf "  %-8s %s\n" "$ifc" "${RTT[$ifc]}"; done

  [[ -z $best_if ]] && { echo "[WARN] 全部失败"; continue; }
  echo -e "\n最优出口: $best_if ($best ms)"
  read -rp "写入策略？(y/n) " yn; [[ $yn =~ [Yy] ]] || continue
  write_rule "$DST" "$best_if" $((PRIO_BASE+prio*10))
  echo "[OK] priority $((PRIO_BASE+prio*10)) → $best_if"
  prio=$((prio+1))
done
