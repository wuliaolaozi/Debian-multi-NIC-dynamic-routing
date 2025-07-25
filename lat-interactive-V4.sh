#!/usr/bin/env bash
# lat-interactive.sh v4.2 2025-07-25
set -euo pipefail

################################################################################
#                      可调参数（默认即可满足大多数需求）
################################################################################
PING_CNT=6           # 每接口 ICMP/TCP 测试次数
TIMEOUT=1            # 单次超时秒数
PRIO_BASE=100        # ip rule 起始优先级
HI_METRIC=200        # 写到主表的高 metric 缺省路由
MODE=icmp            # icmp | tcp   （可用 -m 切换）
TCP_PORT=80          # TCP 测试端口，可 -p 指定
BATCH_FILE=""        # --batch <file> 时读取目标列表
AUTO=0               # --auto 跳过出口确认
################################################################################

###############################################################################
#                依赖检查：跨多发行版自动安装 bc / netcat
###############################################################################
detect_pkg_mgr() {
  for pm in apt-get dnf yum apk pacman; do command -v $pm &>/dev/null && { echo $pm; return; }; done
  echo ""
}

install_pkg() {  # $1=包名
  local pm=$PKG_MGR
  case $pm in
    apt-get) sudo apt-get -qq update && sudo apt-get -y install "$1" ;;
    dnf)     sudo dnf -q -y install "$1" ;;
    yum)     sudo yum -q -y install "$1" ;;
    apk)     sudo apk add --no-progress "$1" ;;
    pacman)  sudo pacman -Sy --noconfirm "$1" ;;
    *)       echo "[ERROR] 未识别的包管理器，无法自动安装 $1"; exit 1 ;;
  esac
}

need() { command -v "$1" &>/dev/null && return
  echo "[INFO] 缺少 $1，尝试安装..."
  install_pkg "$2"
}

PKG_MGR=$(detect_pkg_mgr)
[[ -z $PKG_MGR ]] && { echo "[ERROR] 未检测到受支持的包管理器"; exit 1; }

need bc bc
if [[ $MODE == tcp ]]; then
  case $PKG_MGR in
    apt-get|apk)  need nc netcat-openbsd ;;
    dnf|yum)      need nc nmap-ncat ;;
    pacman)       need nc openbsd-netcat ;;
  esac
fi

###############################################################################
#                systemd timer 安装 / 卸载 子命令
###############################################################################
if [[ ${1-} == --install-timer ]]; then
  [[ $# -lt 3 ]] && { echo "用法: --install-timer <分钟> <targets.txt> [额外参数]"; exit 1; }
  MIN=$2; shift 2
  sudo tee /etc/systemd/system/lat-refresh.service >/dev/null <<SERVICE
[Unit]
Description=Latency-aware routing refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(realpath "$0") --batch $*
SERVICE
  sudo tee /etc/systemd/system/lat-refresh.timer >/dev/null <<TIMER
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
  echo "[OK] systemd timer 已安装 (每 ${MIN} 分钟执行一次)"
  exit 0
elif [[ ${1-} == --remove-timer ]]; then
  sudo systemctl disable --now lat-refresh.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/lat-refresh.{service,timer}
  sudo systemctl daemon-reload
  echo "[OK] timer 已卸载"
  exit 0
fi

###############################################################################
#                参数解析
###############################################################################
while [[ $# -gt 0 ]]; do
  case $1 in
    -m|--mode)   MODE=$2; shift 2;;
    -p|--port)   TCP_PORT=$2; shift 2;;
    --batch)     BATCH_FILE=$2; shift 2;;
    --auto)      AUTO=1; shift;;
    -h|--help)   echo "用法: $0 [-m icmp|tcp] [-p port] [--batch file] [--auto]"; exit 0;;
    *)           echo "未知参数 $1"; exit 1;;
  esac
done
[[ $MODE != icmp && $MODE != tcp ]] && { echo "MODE 仅支持 icmp 或 tcp"; exit 1; }

###############################################################################
#                公共函数
###############################################################################
detect_ifaces() {
  ip -4 -o addr show up scope global |
    while read -r _ ifc _ addr _; do
      sip=${addr%/*}
      gw=$(ip route | awk -v d="$ifc" '$1=="default" && $0~d{print $3;exit}')
      [[ -z $gw ]] && gw="N/A"
      echo "$ifc,$sip,$gw"
    done
}

icmp_rtt() { ping -I "$1" -c $PING_CNT -W $TIMEOUT -q "$2" 2>/dev/null | awk -F'/' '/^rtt/{print $5}' ; }
tcp_rtt()  { ( /usr/bin/time -f "%E" nc -G$TIMEOUT -w$TIMEOUT -s "$1" "$2" $TCP_PORT < /dev/null ) 2>&1 \
              | awk -F: '/[0-9]/{split($0,t,":");print (t[1]*60+t[2])*1000}' ; }
get_rtt()  { [[ $MODE == icmp ]] && icmp_rtt "$@" || tcp_rtt "$@" ; }

build_tables() {
  for idx in "${!IFACES[@]}"; do
    ifc=${IFACES[idx]} tbl="tbl_$ifc" gw=${GWS[idx]} tid=$((200+idx))
    grep -q "[[:space:]]$tbl$" /etc/iproute2/rt_tables || echo "$tid $tbl" | sudo tee -a /etc/iproute2/rt_tables >/dev/null
    subnet=$(ip -4 route show dev "$ifc" proto kernel scope link | awk 'NR==1{print $1}')
    sudo ip route flush table "$tbl" 2>/dev/null || true
    sudo ip route add "$subnet" dev "$ifc" scope link table "$tbl"
    if [[ $gw != "N/A" ]]; then
      sudo ip route add default via "$gw" dev "$ifc" table "$tbl"
      sudo ip route replace default via "$gw" dev "$ifc" metric $HI_METRIC
    fi
  done
}

write_rule() { sudo ip rule del to "$1"/32 2>/dev/null || true
               sudo ip rule add to "$1"/32 lookup "tbl_$2" priority "$3"; }

###############################################################################
#                批量模式
###############################################################################
if [[ -n $BATCH_FILE ]]; then
  mapfile -t TARGETS < "$BATCH_FILE"
  IFS=',' read -ra arr <<<"$(detect_ifaces | paste -sd ',' -)"
  declare -a IFACES SRCIPS GWS
  for ((i=0;i<${#arr[@]};i+=3)); do
    IFACES+=("${arr[i]}") SRCIPS+=("${arr[i+1]}") GWS+=("${arr[i+2]}")
  done
  build_tables
  idx=0
  for DST in "${TARGETS[@]}"; do
    best_if="" best=999999
    for id in "${!IFACES[@]}"; do
      r=$(get_rtt "${SRCIPS[id]}" "$DST" || true); [[ -z $r ]] && r="∞"
      if [[ $r != "∞" ]] && awk -v a=$r -v b=$best 'BEGIN{exit(a<b)?0:1}'; then
        best_if=${IFACES[id]} best=$r
      fi
    done
    [[ $best_if ]] && write_rule "$DST" "$best_if" $((PRIO_BASE+idx*10))
    idx=$((idx+1))
  done
  exit 0
fi

###############################################################################
#                交互模式
###############################################################################
IFS=',' read -ra flat <<<"$(detect_ifaces | paste -sd ',' -)"
declare -a IFACES SRCIPS GWS
for ((i=0;i<${#flat[@]};i+=3)); do
  IFACES+=("${flat[i]}") SRCIPS+=("${flat[i+1]}") GWS+=("${flat[i+2]}")
done

show_list() {
  printf "  %-3s %-8s %-15s %-15s\n" "#" IFACE SRC_IP GATEWAY
  for i in "${!IFACES[@]}"; do
    printf "  %-3d %-8s %-15s %-15s\n" "$i" "${IFACES[i]}" "${SRCIPS[i]}" "${GWS[i]}"
  done
}

if [[ $AUTO -eq 0 ]]; then
  echo -e "\n[INFO] 检测到出口:"; show_list
  read -rp $'\n<Enter>确认 / n 调整: ' ans
  if [[ $ans =~ [Nn] ]]; then
    while :; do
      echo; show_list; echo "(a)添加 (d)删除 (e)编辑 (q)继续)"
      read -rp "选: " op
      case $op in
        a|A) read -rp "IFACE : " ifc; read -rp "SRC IP: " sip; read -rp "GATEWAY: " gw
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
fi

build_tables
echo "[INFO] 表已就绪。当前模式: $MODE (TCP端口 $TCP_PORT)"

prio=0
while :; do
  echo
  read -rp "目标IP(空退出, m=切换, port N=改端口): " DST
  case $DST in
    '') exit 0;;
    m)  MODE=$([[ $MODE == icmp ]] && echo tcp || echo icmp)
        [[ $MODE == tcp ]] && need nc $(case $PKG_MGR in apt-get|apk) echo netcat-openbsd;; dnf|yum) echo nmap-ncat;; pacman) echo openbsd-netcat;; esac)
        echo ">> 模式切换为 $MODE"; continue;;
    port*) TCP_PORT=${DST#port }; echo ">> TCP端口=$TCP_PORT"; continue;;
  esac

  best_if="" best=999999; declare -A RTT
  for id in "${!IFACES[@]}"; do
    r=$(get_rtt "${SRCIPS[id]}" "$DST" || true); [[ -z $r ]] && r="∞"
    RTT[${IFACES[id]}]=$r
    if [[ $r != "∞" ]] && awk -v a=$r -v b=$best 'BEGIN{exit(a<b)?0:1}'; then
      best_if=${IFACES[id]} best=$r
    fi
  done

  echo -e "\n[RTT] $MODE (ms)"
  for ifc in "${IFACES[@]}"; do printf "  %-8s %s\n" "$ifc" "${RTT[$ifc]}"; done
  [[ -z $best_if ]] && { echo "[WARN] 全部失败"; continue; }

  echo -e "\n最优出口: $best_if ($best ms)"
  read -rp "写入策略？(y/n) " yn; [[ $yn =~ [Yy] ]] || continue
  write_rule "$DST" "$best_if" $((PRIO_BASE+prio*10))
  echo "[OK] 已写入 priority $((PRIO_BASE+prio*10)) → $best_if"
  prio=$((prio+1))
done
