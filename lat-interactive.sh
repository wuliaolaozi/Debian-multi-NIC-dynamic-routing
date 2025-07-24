#!/usr/bin/env bash
# 保存路径：/usr/local/sbin/lat-interactive.sh
# 赋权：sudo chmod +x /usr/local/sbin/lat-interactive.sh
set -euo pipefail

#============================= 依赖自检 =======================================#
need_dep() {
  command -v "$1" &>/dev/null && return
  read -rp "缺少 $1，自动安装？(y/n) " yn
  [[ $yn =~ [Yy] ]] || { echo "请先 apt install $1"; exit 1; }
  sudo apt-get -qq update && sudo apt-get -y install "$1"
}
need_dep bc    # 用于比较浮点 RTT

#============================= 可调参数 =======================================#
PING_CNT=6             # 每出口 ping 次数
TIMEOUT=1              # 单次超时秒
PRIO_BASE=100          # ip rule 起始 priority
HI_METRIC=200          # 写到主表的高 metric 缺省路由（不影响现有默认出口）

#========================= 自动探测出口接口 ===================================#
detect_exits() {
  ip -4 -o addr show up scope global | while read -r _ ifc _ addr _; do
    src=${addr%/*}
    gw=$(ip route | awk -v d="$ifc" '$1=="default" && $0~d{print $3;exit}')
    [[ -z $gw ]] && gw="N/A"
    echo "$ifc,$src,$gw"
  done
}

IFS=',' read -ra flat <<<"$(detect_exits | paste -sd ',' -)"
declare -a IFACES SRCIPS GWS
for ((i=0;i<${#flat[@]};i+=3)); do
  IFACES+=("${flat[i]}") SRCIPS+=("${flat[i+1]}") GWS+=("${flat[i+2]}")
done

#========================= 辅助：显示出口列表 =================================#
show_list() {
  printf "  %-3s %-8s %-15s %-15s\n" "#" "IFACE" "SRC_IP" "GATEWAY"
  for i in "${!IFACES[@]}"; do
    printf "  %-3d %-8s %-15s %-15s\n" "$i" "${IFACES[i]}" "${SRCIPS[i]}" "${GWS[i]}"
  done
}

#========================= 用户确认 / 调整出口列表 ============================#
echo -e "\n[INFO] 检测到的出口："; show_list
read -rp $'\n回车确认 / n 调整: ' ans
if [[ $ans =~ [Nn] ]]; then
  while :; do
    echo ; show_list ; echo "(a)添加 (d)删除 (e)编辑 (q)继续)"
    read -rp "选择: " op
    case $op in
      a|A)
        read -rp "    IFACE : " ifc
        read -rp "    SRC IP: " sip
        read -rp "    GATEWAY: " gw
        IFACES+=("$ifc"); SRCIPS+=("$sip"); GWS+=("$gw")
        ;;
      d|D)
        read -rp "    序号: " n
        unset "IFACES[n]" "SRCIPS[n]" "GWS[n]"
        IFACES=("${IFACES[@]}") SRCIPS=("${SRCIPS[@]}") GWS=("${GWS[@]}")
        ;;
      e|E)
        read -rp "    序号: " n
        [[ -z ${IFACES[n]-} ]] && { echo "无效序号"; continue; }
        read -rp "    新 IFACE (回车跳过): " x
        read -rp "    新 SRC IP (回车跳过): " y
        read -rp "    新 GATEWAY(回车跳过): " z
        [[ $x ]] && IFACES[n]=$x
        [[ $y ]] && SRCIPS[n]=$y
        [[ $z ]] && GWS[n]=$z
        ;;
      q|Q) break ;;
      *)   echo "无效输入" ;;
    esac
  done
fi

(( ${#IFACES[@]} == 0 )) && { echo "[ERROR] 没有配置出口，脚本结束"; exit 1; }

#======================= 为每个出口创建路由表 & 主表缺省 =======================#
for i in "${!IFACES[@]}"; do
  ifc=${IFACES[i]}  tbl="tbl_$ifc"  gw=${GWS[i]}  tid=$((200+i))
  grep -q "[[:space:]]$tbl$" /etc/iproute2/rt_tables || \
      echo "$tid $tbl" | sudo tee -a /etc/iproute2/rt_tables >/dev/null

  subnet=$(ip -4 route show dev "$ifc" proto kernel scope link | awk 'NR==1{print $1}')
  sudo ip route flush table "$tbl" 2>/dev/null || true
  sudo ip route add "$subnet" dev "$ifc" scope link table "$tbl"
  if [[ $gw != "N/A" ]]; then
    sudo ip route add default via "$gw" dev "$ifc" table "$tbl"
    # 高 metric 缺省路由，供 ping -I 使用
    sudo ip route replace default via "$gw" dev "$ifc" metric $HI_METRIC
  fi
done
echo "[INFO] 路由表准备完毕，开始 ICMP 延迟测试…"

#============================== 主循环 ========================================#
prio=0
while :; do
  echo
  read -rp "目标 IP (空退出): " DST
  [[ -z $DST ]] && exit 0

  best_if="" best_rtt=999999; declare -A RTT
  for ifc in "${IFACES[@]}"; do
    out=$(ping -I "$ifc" -c $PING_CNT -W $TIMEOUT -q "$DST" 2>/dev/null || true)
    r=$(awk -F'/' '/^rtt/{print $5}' <<<"$out")
    [[ -z $r ]] && r="∞"
    RTT[$ifc]=$r
    if [[ $r != "∞" ]] && awk -v a=$r -v b=$best_rtt 'BEGIN{exit (a<b)?0:1}'; then
      best_if=$ifc; best_rtt=$r
    fi
  done

  echo -e "\n[结果] RTT 平均值 (ms):"
  for ifc in "${IFACES[@]}"; do
    printf "  %-8s %s\n" "$ifc" "${RTT[$ifc]}"
  done

  [[ -z $best_if ]] && { echo "[WARN] 所有出口均失败"; continue; }

  echo -e "\n[INFO] 最优出口: $best_if (RTT $best_rtt ms)"
  read -rp "写入策略路由？(y/n) " yn
  [[ $yn =~ [Yy] ]] || continue

  sudo ip rule del to "$DST"/32 2>/dev/null || true
  sudo ip rule add to "$DST"/32 lookup "tbl_$best_if" priority $((PRIO_BASE + prio*10))
  echo "[INFO] 已写入 ip rule priority $((PRIO_BASE + prio*10)) → tbl_$best_if"
  prio=$((prio + 1))
done
EOF
