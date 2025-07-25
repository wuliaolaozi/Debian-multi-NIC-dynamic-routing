#!/usr/bin/env bash
# lat-interactive.sh v4.2  (2025-07-25)
set -euo pipefail

################ 可调 ################
PING_CNT=6  TIMEOUT=1
PRIO_BASE=100 HI_METRIC=200
MODE=icmp    TCP_PORT=80
BATCH_FILE="" AUTO=0
#####################################

#──── 依赖检测（多发行版） ────#
pm() { for p in apt-get dnf yum apk pacman;do command -v $p &>/dev/null&&{ echo $p;return;};done; }
install() { case $PKGM in
  apt-get) sudo apt-get -qq update && sudo apt-get -y install "$1";;
  dnf)     sudo dnf -q -y install "$1";;
  yum)     sudo yum -q -y install "$1";;
  apk)     sudo apk add --no-progress "$1";;
  pacman)  sudo pacman -Sy --noconfirm "$1";; esac; }
need() { command -v "$1" &>/dev/null && return; echo "[INFO] 安装 $2 ..."; install "$2"; }

PKGM=$(pm) || { echo "Unsupported OS"; exit 1; }
need bc bc
need_nc() { case $PKGM in
  apt-get|apk)  need nc netcat-openbsd;;
  dnf|yum)      need nc nmap-ncat;;
  pacman)       need nc openbsd-netcat;; esac; }

#──── systemd timer 子命令 ────#
if [[ ${1-} == --install-timer ]];then
  [[ $# -lt 3 ]]&&{ echo "用法: --install-timer <分钟> <targets.txt> [额外参数]";exit 1;}
  MIN=$2;shift 2
  sudo tee /etc/systemd/system/lat-refresh.service<<S
[Unit]
Description=Latency refresh
After=network-online.target
[Service]
Type=oneshot
ExecStart=$(realpath "$0") --batch $*
S
  sudo tee /etc/systemd/system/lat-refresh.timer<<T
[Timer]
OnBootSec=2min
OnUnitActiveSec=${MIN}min
RandomizedDelaySec=30s
Persistent=true
[Install]
WantedBy=timers.target
T
  sudo systemctl daemon-reload
  sudo systemctl enable --now lat-refresh.timer
  echo "[OK] timer 已安装"
  exit 0
elif [[ ${1-} == --remove-timer ]];then
  sudo systemctl disable --now lat-refresh.timer 2>/dev/null||true
  sudo rm -f /etc/systemd/system/lat-refresh.{service,timer}
  sudo systemctl daemon-reload
  echo "[OK] timer 已卸载";exit 0;fi

#──── 参数解析 ────#
while [[ $# -gt 0 ]];do case $1 in
  -m|--mode) MODE=$2;shift 2;;
  -p|--port) TCP_PORT=$2;shift 2;;
  --batch) BATCH_FILE=$2;shift 2;;
  --auto) AUTO=1;shift;;
  -h|--help) echo "用法: $0 [-m icmp|tcp] [-p port] [--batch file]";exit 0;;
  *) echo "未知参数 $1";exit 1;; esac;done
[[ $MODE == tcp ]] && need_nc

#──── 公共函数 ────#
detect(){ ip -4 -o addr show up scope global|while read -r _ i _ a _;do
  sip=${a%/*};gw=$(ip r|awk -v d="$i" '$1=="default"&&$0~d{print $3;exit}');[[ -z $gw ]]&&gw="N/A";echo "$i,$sip,$gw";done;}
icmp_rtt(){ ping -I "$1" -c $PING_CNT -W $TIMEOUT -q "$2" 2>/dev/null|awk -F/ '/^rtt/{print $5}';}
tcp_rtt(){ (/usr/bin/time -f "%E" nc -G$TIMEOUT -w$TIMEOUT -s "$1" "$2" $TCP_PORT < /dev/null)2>&1|awk -F: '/[0-9]/{split($0,t,":");print (t[1]*60+t[2])*1000}';}
get_rtt(){ [[ $MODE == icmp ]]&&icmp_rtt "$@"||tcp_rtt "$@";}

build_tbl(){ for idx in "${!IFACES[@]}";do
  ifc=${IFACES[idx]} tbl=tbl_$ifc gw=${GWS[idx]} tid=$((200+idx))
  grep -q "[[:space:]]$tbl$" /etc/iproute2/rt_tables||echo "$tid $tbl"|sudo tee -a /etc/iproute2/rt_tables >/dev/null
  subnet=$(ip -4 route show dev "$ifc" proto kernel scope link|awk 'NR==1{print $1}')
  sudo ip route flush table $tbl 2>/dev/null||true
  sudo ip route add $subnet dev $ifc scope link table $tbl
  [[ $gw != N/A ]]&&{ sudo ip route add default via $gw dev $ifc table $tbl
                      sudo ip route replace default via $gw dev $ifc metric $HI_METRIC;};done;}

write_rule(){ sudo ip rule del to "$1"/32 2>/dev/null||true
              sudo ip rule add to "$1"/32 lookup tbl_$2 priority "$3";}

#──── 批量模式 ────#
if [[ -n $BATCH_FILE ]];then
  mapfile -t TARGETS < "$BATCH_FILE"
  IFS=',' read -ra arr <<<"$(detect|paste -sd ',' -)"
  declare -a IFACES SRCIPS GWS;for((i=0;i<${#arr[@]};i+=3));do
    IFACES+=("${arr[i]}") SRCIPS+=("${arr[i+1]}") GWS+=("${arr[i+2]}");done
  build_tbl
  idx=0;for DST in "${TARGETS[@]}";do
    best_if="" best=999999
    for id in "${!IFACES[@]}";do
      r=$(get_rtt "${SRCIPS[id]}" "$DST"||true);[[ -z $r ]]&&r="∞"
      [[ $r != "∞" ]]&&awk -v a=$r -v b=$best 'BEGIN{exit(a<b)?0:1}'&&{ best_if=${IFACES[id]} best=$r;};done
    [[ $best_if ]]&&write_rule "$DST" "$best_if" $((PRIO_BASE+idx*10));idx=$((idx+1));done;exit 0;fi

#──── 交互模式 ────#
IFS=',' read -ra flat <<<"$(detect|paste -sd ',' -)"
declare -a IFACES SRCIPS GWS;for((i=0;i<${#flat[@]};i+=3));do
  IFACES+=("${flat[i]}") SRCIPS+=("${flat[i+1]}") GWS+=("${flat[i+2]}");done
show(){ printf "  %-3s %-8s %-15s %-15s\n" "#" IFACE SRC_IP GATEWAY
        for i in "${!IFACES[@]}";do printf "  %-3d %-8s %-15s %-15s\n" "$i" "${IFACES[i]}" "${SRCIPS[i]}" "${GWS[i]}";done;}
if [[ $AUTO -eq 0 ]];then echo -e "\n[INFO] 检测到出口:";show
  read -rp $'\n<Enter>确认 / n 调整: ' ans
  if [[ $ans =~ [Nn] ]];then while :;do echo;show;echo "(a)添加 (d)删除 (e)编辑 (q)继续)"
    read -rp "选: " op;case $op in
      a|A) read -rp "IFACE: " i;read -rp "SRC: " s;read -rp "GW: " g
           IFACES+=("$i") SRCIPS+=("$s") GWS+=("$g");;
      d|D) read -rp "编号: " n;unset "IFACES[n]" "SRCIPS[n]" "GWS[n]"
           IFACES=("${IFACES[@]}") SRCIPS=("${SRCIPS[@]}") GWS=("${GWS[@]}");;
      e|E) read -rp "编号: " n;[[ -z ${IFACES[n]-} ]]&&continue
           read -rp "新IF: " x;[[ $x ]]&&IFACES[n]=$x
           read -rp "新SRC: " y;[[ $y ]]&&SRCIPS[n]=$y
           read -rp "新GW : " z;[[ $z ]]&&GWS[n]=$z;;
      q|Q) break;; esac;done;fi;fi

build_tbl;echo "[INFO] 表已就绪，模式: $MODE (TCP $TCP_PORT)"

prio=0;while :;do echo
  read -rp "目标IP(空退出,m切换,port N改端口): " DST
  case $DST in '') exit 0;;
    m) MODE=$([[ $MODE == icmp ]]&&echo tcp||echo icmp);[[ $MODE == tcp ]]&&need_nc;echo ">> MODE=$MODE";continue;;
    port*) TCP_PORT=${DST#port };echo ">> TCP_PORT=$TCP_PORT";continue;;esac
  best_if="" best=999999;declare -A RTT
  for id in "${!IFACES[@]}";do r=$(get_rtt "${SRCIPS[id]}" "$DST"||true);[[ -z $r ]]&&r="∞";RTT[${IFACES[id]}]=$r
    [[ $r != "∞" ]]&&awk -v a=$r -v b=$best 'BEGIN{exit(a<b)?0:1}'&&{ best_if=${IFACES[id]} best=$r;};done
  echo -e "\n[RTT] $MODE (ms)";for if in "${IFACES[@]}";do printf "  %-8s %s\n" "$if" "${RTT[$if]}";done
  [[ $best_if ]]||{ echo "[WARN] 全失败";continue;}
  read -rp "最优 $best_if ($best ms) 写入策略？(y/n) " y;[[ $y =~ [Yy] ]]||continue
  write_rule "$DST" "$best_if" $((PRIO_BASE+prio*10));echo "[OK] priority $((PRIO_BASE+prio*10)) → $best_if";prio=$((prio+1));done
