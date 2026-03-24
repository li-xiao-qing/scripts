#!/bin/bash
################################################################
# RDMA 网络端侧配置采集脚本 (通用版)
#
# 采集项:
#   驱动 & 固件 | Bond 配置 | 内核参数 | 网卡硬件配置
#   MTU | 路由 | PCIe 配置 | QoS 配置 | 拥塞控制 | 高级特性
#
# 使用方法: sudo bash collect_nic_config.sh
################################################################

set -uo pipefail

# ======================== 颜色 & 常量 ========================
CYAN='\033[0;36m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

REPORT_FILE="nic_config_report_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"

# ======================== 工具函数 ========================
log_header() {
    echo -e "\n${BOLD}${BLUE}$(printf '=%.0s' {1..72})${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}$(printf '=%.0s' {1..72})${NC}"
}

log_section() {
    echo -e "\n${CYAN}  --- $1 ---${NC}"
}

# 打印配置项及其实际值
# 用法: print_val "配置项名" "实际值" ["备注"]
print_val() {
    local item="$1" actual="$2" note="${3:-}"
    printf "  %-30s : %-30s" "$item" "$actual"
    [[ -n "$note" ]] && printf "  ${YELLOW}(%s)${NC}" "$note"
    echo ""
}

# ======================== 前置检查 ========================
preflight() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 root 权限运行${NC}"
        echo "  sudo bash $0"
        exit 1
    fi

    if command -v mst &>/dev/null; then
        mst start &>/dev/null 2>&1 || true
    fi

    local warn=()
    for t in mlxconfig mlxfwmanager mlnx_qos mlxreg ibv_devinfo ibdev2netdev ethtool lspci; do
        command -v "$t" &>/dev/null || warn+=("$t")
    done
    if [[ ${#warn[@]} -gt 0 ]]; then
        echo -e "${YELLOW}警告: 以下工具缺失, 部分项将无法采集: ${warn[*]}${NC}"
    fi
}

# ======================== 辅助: 获取所有 mlx5 网卡 ========================
# 输出格式: netdev pci_addr nic_type
get_mlx5_devs() {
    for p in /sys/class/net/*/device/driver; do
        local drv=$(basename "$(readlink -f "$p" 2>/dev/null)" 2>/dev/null)
        [[ "$drv" != "mlx5_core" ]] && continue
        local dev=$(echo "$p" | cut -d'/' -f5)
        [[ "$dev" == bond* ]] && continue
        local pci=$(ethtool -i "$dev" 2>/dev/null | awk '/bus-info/{print $2}')
        [[ -z "$pci" ]] && continue
        local desc=$(lspci -s "$pci" 2>/dev/null)
        local nic_type="unknown"
        echo "$desc" | grep -qi "ConnectX-8" && nic_type="CX8"
        echo "$desc" | grep -qi "ConnectX-7" && nic_type="CX7"
        echo "$desc" | grep -qi "ConnectX-6" && nic_type="CX6"
        echo "$desc" | grep -qi "ConnectX-5" && nic_type="CX5"
        echo "$desc" | grep -qi "BlueField-3" && nic_type="BF3"
        echo "$desc" | grep -qi "BlueField-2" && nic_type="BF2"
        echo "$dev $pci $nic_type"
    done
}

is_bond_slave() {
    local dev="$1"
    for bond in /sys/class/net/bond*/bonding/slaves; do
        grep -qw "$dev" "$bond" 2>/dev/null && return 0
    done
    return 1
}

# 检测网卡物理位置: 机头 (OCP/Mezz 卡) / 机尾 (PCIe add-in 卡)
# 检测方法 (按优先级):
#   1. lspci Subsystem 关键词 (OCP / Mezz / Mezzanine)
#   2. lspci Physical Slot 名称
#   3. Part Number (最可靠: -H 后缀=OCP/Mezz 机头, -N 后缀=PCIe 机尾)
#   4. dmidecode 物理槽位名称与 PCI Bus Address 映射
detect_position() {
    local pci="$1"
    local lspci_vvv=$(lspci -vvv -s "$pci" 2>/dev/null)

    # 方法1: Subsystem 描述
    if echo "$lspci_vvv" | grep -i "Subsystem:" | grep -qiE "OCP|Mezz|Mezzanine"; then
        echo "机头"; return
    fi

    # 方法2: Physical Slot 名称
    local phys_slot=$(echo "$lspci_vvv" | grep -i "Physical Slot:" | awk -F: '{print $2}' | xargs)
    if [[ -n "$phys_slot" ]]; then
        if echo "$phys_slot" | grep -qiE "OCP|Mezz|Mezzanine"; then
            echo "机头"; return
        fi
    fi

    # 方法3: Part Number (最可靠)
    # NVIDIA 命名规则: -H 开头后缀 = OCP/Mezz (如 -HDA, -HEAT), -N 开头后缀 = PCIe (如 -NEA)
    if command -v mlxfwmanager &>/dev/null; then
        local pn=$(mlxfwmanager -d "$pci" --query 2>/dev/null \
            | grep -i "Part Number" | head -1 | sed 's/.*://;s/^[ \t]*//')
        if [[ -n "$pn" ]]; then
            if echo "$pn" | grep -qiE "\-H[A-Z]|\-O[A-Z]|OCP|MEZZ"; then
                echo "机头"; return
            fi
        fi
    fi

    # 方法4: dmidecode 槽位名称 → PCI Bus Address 映射
    if command -v dmidecode &>/dev/null; then
        local short_pci=$(echo "$pci" | sed 's/^0000://')
        local slot_desig=$(dmidecode -t slot 2>/dev/null \
            | awk -v bus="$short_pci" '
                /Designation:/ { desig=$0 }
                /Bus Address:/ && index($0, bus) { print desig; exit }
            ')
        if echo "$slot_desig" | grep -qiE "OCP|Mezz|Mezzanine"; then
            echo "机头"; return
        fi
    fi

    echo "机尾"
}

# ======================== 0. 设备发现 ========================
collect_discovery() {
    log_header "0. 设备发现"

    echo -e "  ${BOLD}RDMA 设备映射:${NC}"
    if command -v ibdev2netdev &>/dev/null; then
        ibdev2netdev 2>/dev/null | sed 's/^/    /'
    else
        echo "    ibdev2netdev 不可用"
    fi

    echo -e "\n  ${BOLD}Bond 接口:${NC}"
    local found_bond=false
    for bond in /sys/class/net/bond*; do
        [[ -d "$bond" ]] || continue
        found_bond=true
        local bname=$(basename "$bond")
        local slaves=$(cat "$bond/bonding/slaves" 2>/dev/null)
        local mode=$(cat "$bond/bonding/mode" 2>/dev/null)
        echo "    $bname  mode=$mode  slaves=[$slaves]"
    done
    $found_bond || echo "    未发现 Bond 接口"

    echo -e "\n  ${BOLD}检测到的 Mellanox/NVIDIA 网卡:${NC}"
    local front_devs=() rear_devs=()
    while read -r dev pci nic_type; do
        local pos=$(detect_position "$pci")
        local role=""
        is_bond_slave "$dev" && role="(bond slave)"
        printf "    %-14s %-15s %-8s %-4s %s\n" "$dev" "$pci" "$nic_type" "$pos" "$role"
        if [[ "$pos" == "机头" ]]; then
            front_devs+=("$dev ($nic_type, $pci)")
        else
            rear_devs+=("$dev ($nic_type, $pci)")
        fi
    done < <(get_mlx5_devs)

    echo -e "\n  ${BOLD}机头网卡 (OCP/Mezz):${NC}"
    if [[ ${#front_devs[@]} -gt 0 ]]; then
        for d in "${front_devs[@]}"; do echo "    $d"; done
    else
        echo "    无 (或无法自动识别, 请结合 Part Number 人工确认)"
    fi

    echo -e "  ${BOLD}机尾网卡 (PCIe add-in):${NC}"
    if [[ ${#rear_devs[@]} -gt 0 ]]; then
        for d in "${rear_devs[@]}"; do echo "    $d"; done
    else
        echo "    无"
    fi
}

# ======================== 1. 驱动 & 固件 ========================
collect_driver_firmware() {
    log_header "1. 驱动 & 固件"

    local drv_ver
    drv_ver=$(ofed_info -s 2>/dev/null | sed 's/.*MLNX_OFED_LINUX-//;s/:.*//' | xargs)
    [[ -z "$drv_ver" ]] && drv_ver=$(modinfo mlx5_core 2>/dev/null | awk '/^version:/{print $2}')
    print_val "驱动版本 (OFED)" "${drv_ver:-N/A}"

    echo ""
    while read -r dev pci nic_type; do
        local fw=$(ethtool -i "$dev" 2>/dev/null | awk '/firmware-version/{print $2}')

        # 检测网卡形态: Mezz Bridge (OCP) / PCIe Add-in
        local form_factor="PCIe"
        local lspci_detail=$(lspci -vvv -s "$pci" 2>/dev/null)
        local subsys=$(echo "$lspci_detail" | grep -i "Subsystem:")
        if echo "$subsys" | grep -qiE "OCP|Mezz|Mezzanine|Bridge"; then
            form_factor="Mezz Bridge"
        fi
        # 辅助判断: 获取 Part Number
        local pn=""
        if command -v mlxfwmanager &>/dev/null; then
            pn=$(mlxfwmanager -d "$pci" --query 2>/dev/null \
                | grep -i "Part Number" | head -1 | sed 's/.*://;s/^[ \t]*//')
            # Mezz/OCP 卡 Part Number 通常含 MCX75xxxx-Hxxx 等模式
            if [[ -n "$pn" ]] && echo "$pn" | grep -qiE "\-H[A-Z]|\-O[A-Z]|OCP|MEZZ"; then
                form_factor="Mezz Bridge"
            fi
        fi

        print_val "固件 $dev" "${fw:-N/A}" "$nic_type $form_factor $pci${pn:+ PN:$pn}"
    done < <(get_mlx5_devs)

    if command -v mlxfwmanager &>/dev/null; then
        echo -e "\n  ${BOLD}mlxfwmanager 详情:${NC}"
        mlxfwmanager --query 2>/dev/null | grep -E "Device Type|FW|PSID|Part Number|Device #" | sed 's/^/    /'
    fi
}

# ======================== 2. Bond 配置 ========================
collect_bond_config() {
    log_header "2. Bond 配置"

    local found=false
    for bond_dir in /sys/class/net/bond*; do
        [[ -d "$bond_dir" ]] || continue
        found=true
        local bname=$(basename "$bond_dir")
        log_section "$bname"

        local mode_str=$(cat "$bond_dir/bonding/mode" 2>/dev/null)
        local mode_num=$(echo "$mode_str" | awk '{print $2}')
        local mode_name=$(echo "$mode_str" | awk '{print $1}')
        print_val "Bond 模式" "mode=$mode_num ($mode_name)"

        local lacp_rate=$(cat "$bond_dir/bonding/lacp_rate" 2>/dev/null | awk '{print $1}')
        print_val "LACP Rate" "${lacp_rate:-N/A}"

        local xmit=$(cat "$bond_dir/bonding/xmit_hash_policy" 2>/dev/null | awk '{print $1}')
        print_val "xmit_hash_policy" "${xmit:-N/A}"

        # ARP 双发检测
        local arp_interval=$(cat "$bond_dir/bonding/arp_interval" 2>/dev/null)
        local arp_targets=$(cat "$bond_dir/bonding/arp_ip_target" 2>/dev/null)
        local arp_validate=$(cat "$bond_dir/bonding/arp_validate" 2>/dev/null | awk '{print $1}')
        local arp_all_targets=$(cat "$bond_dir/bonding/arp_all_targets" 2>/dev/null | awk '{print $1}')
        if [[ -n "$arp_interval" && "$arp_interval" -gt 0 ]] 2>/dev/null; then
            print_val "ARP 双发" "启用" "interval=${arp_interval}ms"
        else
            print_val "ARP 双发" "未启用" "arp_interval=0"
        fi
        print_val "ARP interval" "${arp_interval:-0}"
        [[ -n "$arp_targets" ]] && print_val "ARP targets" "$arp_targets"
        print_val "ARP validate" "${arp_validate:-N/A}"
        print_val "ARP all_targets" "${arp_all_targets:-N/A}"

        # MII 监控
        local miimon=$(cat "$bond_dir/bonding/miimon" 2>/dev/null)
        local updelay=$(cat "$bond_dir/bonding/updelay" 2>/dev/null)
        local downdelay=$(cat "$bond_dir/bonding/downdelay" 2>/dev/null)
        if [[ -n "$miimon" && "$miimon" -gt 0 ]] 2>/dev/null; then
            print_val "MII 监控" "启用" "miimon=${miimon}ms"
        else
            print_val "MII 监控" "未启用" "miimon=0"
        fi
        print_val "MII miimon" "${miimon:-0}"
        print_val "MII updelay" "${updelay:-0}"
        print_val "MII downdelay" "${downdelay:-0}"

        # LAG Port Select Mode (mlxconfig on first slave)
        local slaves=$(cat "$bond_dir/bonding/slaves" 2>/dev/null)
        print_val "Slaves" "${slaves:-无}"
        local first_slave=$(echo "$slaves" | awk '{print $1}')
        if [[ -n "$first_slave" ]] && command -v mlxconfig &>/dev/null; then
            local slave_pci=$(ethtool -i "$first_slave" 2>/dev/null | awk '/bus-info/{print $2}')
            if [[ -n "$slave_pci" ]]; then
                local lag_mode=$(mlxconfig -d "$slave_pci" q 2>/dev/null | grep -i "LAG_PORT_SELECT" | awk '{print $NF}')
                print_val "LAG Port Select Mode" "${lag_mode:-N/A}"
            fi
        fi
    done
    $found || echo "  未发现 Bond 接口"
}

# ======================== 3. 内核参数 ========================
collect_kernel_params() {
    log_header "3. 内核参数"

    local hard_ml=$(grep "Max locked memory" /proc/self/limits 2>/dev/null | awk '{print $5}')
    local soft_ml=$(grep "Max locked memory" /proc/self/limits 2>/dev/null | awk '{print $4}')
    print_val "Hard Memlock" "${hard_ml:-N/A}"
    print_val "Soft Memlock" "${soft_ml:-N/A}"

    echo -e "  ${BOLD}limits.conf memlock 配置:${NC}"
    grep -rv "^#" /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null \
        | grep -i memlock | sed 's/^/    /' || echo "    无显式 memlock 配置"

    echo ""
    local rp_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
    local rp_def=$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null)
    print_val "RP Filter (all)" "${rp_all:-N/A}"
    print_val "RP Filter (default)" "${rp_def:-N/A}"
}

# ======================== 4. 网卡硬件配置 ========================
collect_nic_hw_config() {
    log_header "4. 网卡硬件配置"

    if ! command -v mlxconfig &>/dev/null; then
        echo -e "  ${YELLOW}mlxconfig 不可用${NC}"
        return
    fi

    while read -r dev pci nic_type; do
        log_section "$dev ($pci) [$nic_type]"
        local out=$(mlxconfig -d "$pci" q 2>/dev/null)

        local ats=$(echo "$out" | grep -i "ATS_ENABLED" | awk '{print $NF}')
        print_val "ATS_ENABLED" "${ats:-N/A}"

        local pci_wr=$(echo "$out" | grep -i "PCI_WR_ORDERING" | awk '{print $NF}')
        print_val "PCI_WR_ORDERING" "${pci_wr:-N/A}"
    done < <(get_mlx5_devs)
}

# ======================== 5. MTU ========================
collect_mtu() {
    log_header "5. MTU"

    if command -v ibv_devinfo &>/dev/null; then
        echo -e "  ${BOLD}RDMA 设备 active_mtu:${NC}"
        ibv_devinfo 2>/dev/null | grep -E "hca_id|active_mtu|port:" | sed 's/^/    /'
    fi

    echo -e "\n  ${BOLD}网络接口 MTU:${NC}"
    while read -r dev pci nic_type; do
        local mtu=$(cat "/sys/class/net/$dev/mtu" 2>/dev/null)
        printf "    %-14s MTU=%-8s [%s]\n" "$dev" "${mtu:-N/A}" "$nic_type"
    done < <(get_mlx5_devs)

    for bond in /sys/class/net/bond*; do
        [[ -d "$bond" ]] || continue
        local bname=$(basename "$bond")
        local mtu=$(cat "$bond/mtu" 2>/dev/null)
        printf "    %-14s MTU=%-8s [bond]\n" "$bname" "${mtu:-N/A}"
    done
}

# ======================== 6. 路由 ========================
collect_routes() {
    log_header "6. 路由配置"

    echo -e "  ${BOLD}策略路由 (ip rule):${NC}"
    ip rule show 2>/dev/null | sed 's/^/    /'

    echo -e "\n  ${BOLD}主路由表:${NC}"
    ip route show 2>/dev/null | head -30 | sed 's/^/    /'

    local custom_tables=$(ip rule show 2>/dev/null | grep -oP 'lookup \K\S+' | sort -u)
    for tbl in $custom_tables; do
        [[ "$tbl" == "main" || "$tbl" == "local" || "$tbl" == "default" ]] && continue
        echo -e "\n  ${BOLD}自定义路由表 [$tbl]:${NC}"
        ip route show table "$tbl" 2>/dev/null | sed 's/^/    /'
    done
}

# ======================== 7. PCIe 配置 ========================
collect_pcie_config() {
    log_header "7. PCIe 配置"

    while read -r dev pci nic_type; do
        log_section "$dev ($pci) [$nic_type]"

        local pcie_vvv=$(lspci -vvv -s "$pci" 2>/dev/null)

        # ACS
        local acs_ctl=$(echo "$pcie_vvv" | grep "ACSCtl:")
        if [[ -n "$acs_ctl" ]]; then
            if echo "$acs_ctl" | grep -q "SrcValid+"; then
                print_val "ACS" "on"
            else
                print_val "ACS" "off"
            fi
        else
            print_val "ACS" "N/A" "设备不支持或无法读取"
        fi

        # MaxReadReq
        local mrr=$(echo "$pcie_vvv" | grep -oP 'MaxReadReq \K[0-9]+')
        print_val "MaxReadReq" "${mrr:-N/A} bytes"

        # Link Speed / Width
        local link_speed=$(echo "$pcie_vvv" | grep "LnkSta:" | grep -oP 'Speed \K[^,]+')
        local link_width=$(echo "$pcie_vvv" | grep "LnkSta:" | grep -oP 'Width \K[^,]+')
        [[ -n "$link_speed" ]] && print_val "PCIe Link Speed" "$link_speed"
        [[ -n "$link_width" ]] && print_val "PCIe Link Width" "$link_width"
    done < <(get_mlx5_devs)
}

# ======================== 8. QoS 配置 ========================
collect_qos_config() {
    log_header "8. QoS 配置"

    while read -r dev pci nic_type; do
        log_section "$dev ($pci) [$nic_type]"

        if command -v mlnx_qos &>/dev/null; then
            local qos_out=$(mlnx_qos -i "$dev" 2>/dev/null)

            local trust=$(echo "$qos_out" | grep -i "trust state" | awk '{print $NF}')
            print_val "Trust Mode" "${trust:-N/A}"

            # PFC
            local pfc_enabled=$(echo "$qos_out" | grep -A2 "PFC configuration" | tail -1)
            if [[ -n "$pfc_enabled" ]]; then
                echo -e "  ${BOLD}PFC 配置:${NC}"
                echo "$qos_out" | grep -A3 "PFC configuration" | sed 's/^/    /'
            fi

            # DSCP mapping
            local dscp_map=$(echo "$qos_out" | grep -A1 "dscp2prio")
            if [[ -n "$dscp_map" ]]; then
                echo -e "  ${BOLD}DSCP mapping:${NC}"
                echo "$dscp_map" | sed 's/^/    /'
            fi

            # RoCE 队列 — TC (Traffic Class) 配置
            local tc_lines=$(echo "$qos_out" | grep "^tc:")
            if [[ -n "$tc_lines" ]]; then
                local num_tc=$(echo "$tc_lines" | wc -l | xargs)
                print_val "TC 数量" "$num_tc"
                echo -e "  ${BOLD}TC 配置:${NC}"
                echo "$tc_lines" | sed 's/^/    /'
            fi
        else
            echo -e "  ${YELLOW}mlnx_qos 不可用${NC}"
        fi

        # ToS
        local ib_dev=""
        if command -v ibdev2netdev &>/dev/null; then
            ib_dev=$(ibdev2netdev 2>/dev/null | grep "$dev " | awk '{print $1}')
        fi
        if [[ -n "$ib_dev" ]]; then
            local tos_raw=$(cat "/sys/class/infiniband/$ib_dev/tc/1/traffic_class" 2>/dev/null)
            # traffic_class 可能输出 "Global tclass=162" 或纯数字, 提取数字部分
            local tos=""
            if [[ -n "$tos_raw" ]]; then
                tos=$(echo "$tos_raw" | grep -oP '[0-9]+' | tail -1)
            fi
            [[ -n "$tos" ]] && print_val "ToS (traffic_class)" "$tos" "原始值: $tos_raw"

            # ---- RDMA 传输协议检测 ----
            echo -e "  ${BOLD}RDMA 传输协议:${NC}"

            # link_layer: InfiniBand or Ethernet
            local link_layer=$(cat "/sys/class/infiniband/$ib_dev/ports/1/link_layer" 2>/dev/null)
            print_val "Link Layer" "${link_layer:-N/A}"

            if [[ "$link_layer" == "Ethernet" ]]; then
                # GID 表类型 — 区分 RoCE v1 / v2
                local gid_dir="/sys/class/infiniband/$ib_dev/ports/1/gid_attrs/types"
                local v1_count=0 v2_count=0
                if [[ -d "$gid_dir" ]]; then
                    for gf in "$gid_dir"/*; do
                        [[ -f "$gf" ]] || continue
                        local gt=$(cat "$gf" 2>/dev/null)
                        case "$gt" in
                            *"RoCE v2"*) ((v2_count++)) ;;
                            *"RoCE v1"*|*"IB/RoCE v1"*) ((v1_count++)) ;;
                        esac
                    done
                fi
                print_val "GID 表" "RoCE v1 ×${v1_count}, RoCE v2 ×${v2_count}" "v1 为兼容条目, v2 为实际使用"

                # 判断实际协议: 有 v2 条目则为 RoCE v2 (现代应用默认选 v2 GID)
                if [[ $v2_count -gt 0 ]]; then
                    print_val "RDMA 协议" "RoCE v2 (UDP/IP)" "GID 表含 v2 条目, 应用默认使用 v2"
                elif [[ $v1_count -gt 0 ]]; then
                    print_val "RDMA 协议" "RoCE v1 (Ethertype 0x8915)" "仅有 v1 条目"
                else
                    print_val "RDMA 协议" "RoCE (版本未知)"
                fi
            elif [[ "$link_layer" == "InfiniBand" ]]; then
                print_val "RDMA 协议" "InfiniBand"
            else
                print_val "RDMA 协议" "未知 ($link_layer)"
            fi

            # ---- RoCE 流量路径汇总 ----
            if [[ "$link_layer" == "Ethernet" && -n "$tos" ]]; then
                echo -e "  ${BOLD}RoCE 流量路径 (ToS → DSCP → Priority → TC):${NC}"
                local dscp=$((tos >> 2))
                local ecn=$((tos & 3))
                print_val "ToS" "$tos"
                print_val "DSCP" "$dscp" "ToS($tos) >> 2 = $dscp"
                local ecn_desc=""
                case $ecn in
                    0) ecn_desc="Non-ECT" ;;
                    1) ecn_desc="ECT(1)" ;;
                    2) ecn_desc="ECT(0)" ;;
                    3) ecn_desc="CE" ;;
                esac
                print_val "ECN" "$ecn ($ecn_desc)"

                # 从 mlnx_qos 输出中解析 DSCP→Priority 映射
                if command -v mlnx_qos &>/dev/null; then
                    local qos_full=$(mlnx_qos -i "$dev" 2>/dev/null)

                    # 解析 dscp2prio: 格式 "prio:X dscp:YY,YY,..."
                    local roce_prio=""
                    while IFS= read -r prio_line; do
                        local pnum=$(echo "$prio_line" | grep -oP 'prio:\K[0-9]+')
                        local dscps=$(echo "$prio_line" | grep -oP 'dscp:\K[0-9,]+')
                        if [[ -n "$dscps" ]]; then
                            # 检查 dscp 值是否在这一行
                            IFS=',' read -ra dscp_arr <<< "$dscps"
                            for d in "${dscp_arr[@]}"; do
                                if [[ "$d" -eq "$dscp" ]] 2>/dev/null; then
                                    roce_prio="$pnum"
                                    break 2
                                fi
                            done
                        fi
                    done <<< "$(echo "$qos_full" | grep "prio:" | grep "dscp:")"

                    if [[ -n "$roce_prio" ]]; then
                        print_val "Priority" "$roce_prio" "DSCP $dscp → Priority $roce_prio"
                    else
                        print_val "Priority" "N/A" "DSCP $dscp 未在 dscp2prio 映射中找到"
                    fi

                    # 从 TC 配置中找 priority 对应的 TC
                    local roce_tc=""
                    while IFS= read -r tc_line; do
                        if [[ -n "$roce_prio" ]]; then
                            # tc:N ... priority: X Y Z
                            local tc_num=$(echo "$tc_line" | grep -oP '^tc:\K[0-9]+')
                            local prio_list=$(echo "$tc_line" | grep -oP 'priority:\s*\K.*')
                            if [[ -n "$tc_num" && -n "$prio_list" ]]; then
                                for p in $prio_list; do
                                    if [[ "$p" == "$roce_prio" ]]; then
                                        roce_tc="$tc_num"
                                        break 2
                                    fi
                                done
                            fi
                        fi
                    done <<< "$(echo "$qos_full" | grep -E "^tc:[0-9]")"

                    # 备选: 从 priority:  行匹配
                    if [[ -z "$roce_tc" && -n "$roce_prio" ]]; then
                        local cur_tc=""
                        while IFS= read -r line; do
                            if echo "$line" | grep -qE "^tc:[0-9]"; then
                                cur_tc=$(echo "$line" | grep -oP '^tc:\K[0-9]+')
                            elif echo "$line" | grep -qE "^\s*priority:"; then
                                local plist=$(echo "$line" | sed 's/.*priority:\s*//')
                                for p in $plist; do
                                    if [[ "$p" == "$roce_prio" ]]; then
                                        roce_tc="$cur_tc"
                                        break 2
                                    fi
                                done
                            fi
                        done <<< "$qos_full"
                    fi

                    if [[ -n "$roce_tc" ]]; then
                        print_val "Traffic Class (TC)" "TC$roce_tc" "Priority $roce_prio → TC$roce_tc"
                    else
                        print_val "Traffic Class (TC)" "N/A" "无法从 mlnx_qos 解析 TC 映射"
                    fi

                    # 检查该 priority 是否开启了 PFC (无损队列)
                    if [[ -n "$roce_prio" ]]; then
                        local pfc_line=$(echo "$qos_full" | grep -A2 "PFC configuration" | tail -1)
                        if [[ -n "$pfc_line" ]]; then
                            # pfc_line 格式: "  enabled  0  0  0  0  0  1  0  0"
                            local pfc_vals=($pfc_line)
                            # 跳过 "enabled" 标签, 取 priority 对应的值
                            local pfc_idx=$((roce_prio + 1))  # +1 跳过 "enabled" 标签
                            local pfc_val="${pfc_vals[$pfc_idx]:-N/A}"
                            if [[ "$pfc_val" == "1" ]]; then
                                print_val "PFC (Priority $roce_prio)" "开启 (无损队列)"
                            else
                                print_val "PFC (Priority $roce_prio)" "未开启 (有损队列)"
                            fi
                        fi
                    fi

                    # 汇总输出
                    echo -e "  ${BOLD}>>> RoCE 流量完整路径: ToS=$tos → DSCP=$dscp → Priority=${roce_prio:-?} → TC${roce_tc:-?}${NC}"
                    # 直接输出 RoCE 队列
                    if [[ -n "$roce_prio" ]]; then
                        print_val "RoCE 队列" "$roce_prio" "即 Priority $roce_prio, PFC 无损队列"
                    else
                        print_val "RoCE 队列" "N/A" "无法确定, DSCP→Priority 映射未找到"
                    fi
                fi
            fi

            # RDMA 资源概况
            if command -v rdma &>/dev/null; then
                local res_line=$(rdma resource show "$ib_dev" 2>/dev/null | head -1)
                [[ -n "$res_line" ]] && print_val "RDMA 资源" "$res_line"
            fi
        fi

        # cma_roce_tos (if available)
        if command -v cma_roce_tos &>/dev/null; then
            local cma_tos=$(cma_roce_tos -d "$dev" 2>/dev/null)
            [[ -n "$cma_tos" ]] && print_val "cma_roce_tos" "$cma_tos"
        fi
    done < <(get_mlx5_devs)
}

# ======================== 9. 拥塞控制 ========================
collect_cc_config() {
    log_header "9. 拥塞控制 (CC)"

    while read -r dev pci nic_type; do
        log_section "$dev ($pci) [$nic_type]"

        # mlxconfig 持久化配置
        if command -v mlxconfig &>/dev/null; then
            local mlx_out=$(mlxconfig -d "$pci" q 2>/dev/null)
            local cc_items=$(echo "$mlx_out" | grep -iE "ROCE_CC|DCQCN|ZTRCC|ECN|CONG")
            if [[ -n "$cc_items" ]]; then
                echo -e "  ${BOLD}mlxconfig CC 配置:${NC}"
                echo "$cc_items" | while read -r line; do echo "    $line"; done
            fi
        fi

        # sysfs debugfs cc_params
        local cc_path=""
        for try_path in \
            "/sys/kernel/debug/mlx5/${pci}/cc_params" \
            "/sys/kernel/debug/mlx5/$(echo "$pci" | sed 's/^0000://')/cc_params"; do
            [[ -d "$try_path" ]] && { cc_path="$try_path"; break; }
        done

        if [[ -n "$cc_path" ]]; then
            echo -e "  ${BOLD}运行时 CC 参数 ($cc_path):${NC}"
            for f in "$cc_path"/*; do
                [[ -f "$f" ]] || continue
                local name=$(basename "$f")
                local val=$(cat "$f" 2>/dev/null)
                printf "    %-35s = %s\n" "$name" "${val:-N/A}"
            done
        else
            echo -e "  ${YELLOW}debugfs cc_params 不可用 (需 mount debugfs)${NC}"
        fi

        # mlxreg PPCC — CC 算法启用检测 (DCQCN / ZTRCC)
        if command -v mlxreg &>/dev/null; then
            echo -e "  ${BOLD}CC 算法启用状态:${NC}"
            local algo_detected=false

            # algo=0: DCQCN
            local ppcc_dcqcn=$(mlxreg -d "$pci" --reg_name PPCC \
                --get --indexes "local_port=1,pnat=0,lp_msb=0,algo_slot=0,algo=0" 2>/dev/null)
            if [[ -n "$ppcc_dcqcn" ]] && echo "$ppcc_dcqcn" | grep -q "cb_enable"; then
                algo_detected=true
                local dcqcn_en=$(echo "$ppcc_dcqcn" | grep "cb_enable" | awk '{print $NF}')
                print_val "DCQCN (algo=0)" \
                    "$([ "$dcqcn_en" = "0x00000001" ] && echo 启用 || echo 未启用)" \
                    "cb_enable=$dcqcn_en"
            fi

            # algo=1: ZTRCC / RTT-based CC
            local ppcc_ztrcc=$(mlxreg -d "$pci" --reg_name PPCC \
                --get --indexes "local_port=1,pnat=0,lp_msb=0,algo_slot=0,algo=1" 2>/dev/null)
            if [[ -n "$ppcc_ztrcc" ]] && echo "$ppcc_ztrcc" | grep -q "cb_enable"; then
                algo_detected=true
                local ztrcc_en=$(echo "$ppcc_ztrcc" | grep "cb_enable" | awk '{print $NF}')
                print_val "ZTRCC (algo=1)" \
                    "$([ "$ztrcc_en" = "0x00000001" ] && echo 启用 || echo 未启用)" \
                    "cb_enable=$ztrcc_en"
            fi

            # 回退检测: PPCC 不可读时使用 mlxconfig + debugfs 辅助判断
            if ! $algo_detected; then
                echo "    PPCC 寄存器不可读, 使用替代方式检测..."
                # mlxconfig 中的算法相关配置
                if command -v mlxconfig &>/dev/null; then
                    local cc_algo_cfg=$(echo "$mlx_out" | grep -iE "CC_ALGO|ZTRCC|RTT_CC")
                    if [[ -n "$cc_algo_cfg" ]]; then
                        echo "$cc_algo_cfg" | while read -r line; do echo "    $line"; done
                    fi
                fi
                # debugfs 中是否存在 ZTRCC 相关参数文件
                if [[ -n "$cc_path" ]]; then
                    local has_ztrcc=false
                    for zf in "$cc_path"/ztrcc_* "$cc_path"/rtt_cc_*; do
                        [[ -f "$zf" ]] && { has_ztrcc=true; break; }
                    done
                    if $has_ztrcc; then
                        print_val "ZTRCC (debugfs)" "检测到参数文件"
                        for zf in "$cc_path"/ztrcc_* "$cc_path"/rtt_cc_*; do
                            [[ -f "$zf" ]] || continue
                            printf "    %-35s = %s\n" "$(basename "$zf")" "$(cat "$zf" 2>/dev/null)"
                        done
                    else
                        print_val "ZTRCC (debugfs)" "未检测到参数文件"
                    fi
                fi
                # DCQCN 推断: 如果 cc_params 中存在 rp_* 参数, 说明 DCQCN 在运行
                if [[ -n "$cc_path" ]] && ls "$cc_path"/rp_* &>/dev/null; then
                    print_val "DCQCN (debugfs)" "检测到 DCQCN 运行时参数 (rp_*)"
                fi
            fi

            # CC 生效模式 (per-IP / per-QP)
            echo -e "  ${BOLD}CC 生效模式:${NC}"
            local accl_cc=$(mlxreg -d "$pci" --reg_name ROCE_ACCL --get 2>/dev/null)
            if [[ -n "$accl_cc" ]]; then
                # 检查 ROCE_ACCL 中的 per-IP 相关字段
                local per_ip=$(echo "$accl_cc" | grep -iE "per_ip|per_flow" | awk '{print $NF}')
                if [[ -n "$per_ip" ]]; then
                    print_val "Per-IP CC" \
                        "$([ "$per_ip" = "0x00000001" ] && echo enable || echo disable)" \
                        "roce_cc_per_ip=$per_ip"
                else
                    print_val "Per-IP CC (ROCE_ACCL)" "N/A" "寄存器中无 per_ip 字段"
                fi
            fi
            # mlxconfig 中的 per-IP / flow-label 配置
            if command -v mlxconfig &>/dev/null; then
                local perip_cfg=$(echo "$mlx_out" | grep -iE "PER_IP|PER_QP|FLOW_LABEL_CC|CC_MODE")
                if [[ -n "$perip_cfg" ]]; then
                    echo "$perip_cfg" | while read -r line; do echo "    $line"; done
                else
                    print_val "Per-IP CC (mlxconfig)" "N/A" "未找到相关配置项"
                fi
            fi
        fi
    done < <(get_mlx5_devs)
}

# ======================== 10. 高级特性 ========================
collect_advanced_features() {
    log_header "10. 高级特性"

    while read -r dev pci nic_type; do
        log_section "$dev ($pci) [$nic_type]"

        # mlxconfig 持久化配置
        if command -v mlxconfig &>/dev/null; then
            local mlx_out=$(mlxconfig -d "$pci" q 2>/dev/null)
            local ar=$(echo "$mlx_out" | grep -i "ADAPTIVE_ROUTING" | awk '{print $NF}')
            print_val "Adaptive Routing (mlxconfig)" "${ar:-N/A}"

            local adv_items=$(echo "$mlx_out" | grep -iE "SLOW_RESTART|TX_WINDOW|ADP_RETRANS")
            if [[ -n "$adv_items" ]]; then
                echo "$adv_items" | while read -r line; do echo "    $line"; done
            fi
        fi

        # mlxreg ROCE_ACCL 运行时参数
        if command -v mlxreg &>/dev/null; then
            local accl=$(mlxreg -d "$pci" --reg_name ROCE_ACCL --get 2>/dev/null)
            if [[ -n "$accl" ]]; then
                echo -e "  ${BOLD}ROCE_ACCL 运行时参数:${NC}"
                # 只提取关键字段
                local tx_win=$(echo "$accl" | grep "roce_tx_window_en" | awk '{print $NF}')
                local slow_r=$(echo "$accl" | grep "roce_slow_restart_en" | grep -v idle | awk '{print $NF}')
                local slow_idle=$(echo "$accl" | grep "roce_slow_restart_idle_en" | awk '{print $NF}')
                local adp_r=$(echo "$accl" | grep "roce_adp_retrans_en" | awk '{print $NF}')
                local ar_en=$(echo "$accl" | grep "adaptive_routing_forced_en" | head -1 | awk '{print $NF}')

                print_val "TX Window" "$([ "$tx_win" = "0x00000001" ] && echo enable || echo disable)" "roce_tx_window_en=$tx_win"
                print_val "Slow Restart" "$([ "$slow_r" = "0x00000001" ] && echo enable || echo disable)" "roce_slow_restart_en=$slow_r"
                print_val "Slow Restart Idle" "$([ "$slow_idle" = "0x00000001" ] && echo enable || echo disable)" "roce_slow_restart_idle_en=$slow_idle"
                print_val "Adp Retrans" "$([ "$adp_r" = "0x00000001" ] && echo enable || echo disable)" "roce_adp_retrans_en=$adp_r"
                print_val "Adaptive Routing (runtime)" "$([ "$ar_en" = "0x00000001" ] && echo enable || echo disable)" "adaptive_routing_forced_en=$ar_en"
            else
                echo -e "  ${YELLOW}ROCE_ACCL 寄存器不可用${NC}"
            fi
        fi
    done < <(get_mlx5_devs)
}

# ======================== 汇总 ========================
generate_summary() {
    log_header "采集完成 - 环境信息"

    printf "  %-18s %s\n" "主机名:" "$(hostname)"
    printf "  %-18s %s\n" "采集时间:" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  %-18s %s\n" "内核版本:" "$(uname -r)"
    printf "  %-18s %s\n" "OS:" "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo ""
    echo -e "  完整报告已保存至: ${BOLD}$(pwd)/${REPORT_FILE}${NC}"
}

# ======================== 主流程 ========================
main() {
    preflight

    echo -e "${BOLD}${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║          RDMA 网络端侧配置采集脚本 (通用版)                    ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    {
        collect_discovery
        collect_driver_firmware
        collect_bond_config
        collect_kernel_params
        collect_nic_hw_config
        collect_mtu
        collect_routes
        collect_pcie_config
        collect_qos_config
        collect_cc_config
        collect_advanced_features
        generate_summary
    } 2>&1 | tee "$REPORT_FILE"
}

main "$@"
