#!/bin/bash
# switch_discover.sh
# 批量探测服务器Bond网卡上联交换机信息（优先 lldptool，备选 tcpdump）

#===========================================
# 使用方法
#===========================================
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -f, --file FILE    IP列表文件（每行一个IP，必需）"
    echo "  -b, --bond NAME    Bond名称（如 bond2，必需）"
    echo "  -h, --help         显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -f iplist.txt -b bond2"
    exit 1
}

#===========================================
# 解析参数
#===========================================
IP_LIST_FILE=""
BOND_NAME=""

while [ $# -gt 0 ]; do
    case $1 in
        -f|--file) IP_LIST_FILE="$2"; shift 2 ;;
        -b|--bond) BOND_NAME="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)
            echo "不支持的参数: $1"
            usage
            ;;
    esac
done

if [ -z "${IP_LIST_FILE}" ] || [ -z "${BOND_NAME}" ]; then
    echo "[ERROR] 必须指定 -f <IP列表文件> 和 -b <Bond名称>"
    usage
fi

if [ ! -f "${IP_LIST_FILE}" ]; then
    echo "[ERROR] IP列表文件不存在: ${IP_LIST_FILE}"
    exit 1
fi

#===========================================
# 配置区域
#===========================================
REMOTE_USER="root"
SSH_OPTS="-o StrictHostKeyChecking=no \
          -o ConnectTimeout=10 \
          -o BatchMode=yes \
          -o LogLevel=ERROR"
TCPDUMP_TIMEOUT=90
RESULT_FILE="./lldp_${BOND_NAME}_result_$(date +%Y%m%d_%H%M%S).txt"

#===========================================
# 颜色定义
#===========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

#===========================================
# 获取bond的slave网卡列表
#===========================================
get_bond_slaves() {
    local host=$1
    local bond=$2

    ssh ${SSH_OPTS} ${REMOTE_USER}@${host} \
        "cat /sys/class/net/${bond}/bonding/slaves 2>/dev/null" 2>/dev/null
}

#===========================================
# 检查SSH连通性
#===========================================
check_ssh() {
    local host=$1
    ssh ${SSH_OPTS} ${REMOTE_USER}@${host} "echo ok" &>/dev/null
    return $?
}

#===========================================
# 远程采集LLDP信息（优先 lldptool，备选 tcpdump）
#===========================================
check_lldp() {
    local host=$1
    local slaves=$2

    local iface_list=($slaves)
    if [ ${#iface_list[@]} -eq 0 ]; then
        echo "  [WARN] 未找到slave网卡"
        return
    fi

    ssh ${SSH_OPTS} ${REMOTE_USER}@${host} "bash -s ${slaves}" << 'REMOTE_SCRIPT'
slaves="$@"
for iface in ${slaves}; do
    echo "---------- ${iface} ----------"

    if ! ip link show ${iface} &>/dev/null; then
        echo "  [SKIP] 网卡不存在"
        echo ""
        continue
    fi

    if command -v lldptool &>/dev/null; then
        output=$(lldptool -t -i ${iface} -n 2>/dev/null)

        if [ -z "$output" ]; then
            echo "  [WARN] lldptool 未获取到数据"
            echo ""
            continue
        fi

        sysname=$(echo "$output" | awk '/System Name TLV/{getline; gsub(/^[ \t]+/,""); print}')
        portid=$(echo "$output"  | awk '/Port ID TLV/{getline; gsub(/^[ \t]+/,""); gsub(/Ifname: /,""); print}')
        portdesc=$(echo "$output"| awk '/Port Description TLV/{getline; gsub(/^[ \t]+/,""); print}')
        mgmtip=$(echo "$output"  | awk '/IPv4:/{print $2}')
        model=$(echo "$output"   | awk '/System Description TLV/{
            getline
            while ($0 !~ /TLV/ && $0 != "") {
                gsub(/^[ \t]+/,"")
                if (length($0) > 0) { print; exit }
                getline
            }
        }')

        echo "  交换机名称: ${sysname}"
        echo "  交换机端口: ${portid}"
        echo "  对端描述  : ${portdesc}"
        echo "  管理IP    : ${mgmtip}"
        echo "  设备型号  : ${model}"

    elif command -v tcpdump &>/dev/null; then
        echo "  [INFO] 使用tcpdump采集（等待LLDP包，最长TCPDUMP_TIMEOUTs）..."
        timeout TCPDUMP_TIMEOUT tcpdump -i ${iface} ether proto 0x88cc -Q in -vv -nn -c 1 2>&1 | awk '
            /System Name TLV/      { sub(/.*length [0-9]+: /,""); sysname=$0 }
            /Port ID TLV/          { getline; gsub(/^[ \t]+|Ifname: /,""); portid=$0 }
            /Port Description TLV/ { match($0, /: (.+)$/, a); portdesc=a[1] }
            END {
                print "  交换机名称: " sysname
                print "  交换机端口: " portid
                print "  对端描述  : " portdesc
            }
        '
    else
        echo "  [ERROR] 未找到 lldptool 或 tcpdump"
        echo "  请安装: yum install -y lldpad tcpdump"
    fi

    echo ""
done
REMOTE_SCRIPT
}

#===========================================
# 处理单台主机
#===========================================
process_host() {
    local host=$1

    local header="=============================="
    local host_line="# 主机: ${host}"
    local bond_line="# Bond: ${BOND_NAME}"

    echo -e "${YELLOW}[INFO] 正在处理 ${host} ...${NC}"

    if ! check_ssh ${host}; then
        echo -e "${RED}[ERROR] ${host} SSH连接失败，跳过${NC}"
        {
            echo "${header}"
            echo "${host_line}"
            echo "${bond_line}"
            echo "${header}"
            echo "  [ERROR] SSH连接失败"
            echo ""
        } >> ${RESULT_FILE}
        return 1
    fi

    local slaves
    slaves=$(get_bond_slaves ${host} ${BOND_NAME})

    if [ -z "$slaves" ]; then
        echo -e "${RED}[WARN] ${host} 未找到 ${BOND_NAME} 的slave网卡${NC}"
        {
            echo "${header}"
            echo "${host_line}"
            echo "${bond_line}"
            echo "# Slaves: 未找到"
            echo "${header}"
            echo "  [WARN] 未找到 ${BOND_NAME} 的slave网卡"
            echo ""
        } >> ${RESULT_FILE}
        return 1
    fi

    echo -e "  ${GREEN}Bond slave: ${slaves}${NC}"

    local lldp_output
    lldp_output=$(check_lldp ${host} "${slaves}")

    {
        echo "${header}"
        echo "${host_line}"
        echo "${bond_line}"
        echo "# Slaves: ${slaves}"
        echo "${header}"
        echo "${lldp_output}"
        echo ""
    } >> ${RESULT_FILE}

    echo "${lldp_output}"
    echo ""
}

#===========================================
# 主流程
#===========================================
main() {
    local total
    total=$(grep -c -v '^\s*$' ${IP_LIST_FILE})

    {
        echo "########################################"
        echo "# LLDP 对端交换机信息采集结果"
        echo "########################################"
        echo "# 时间      : $(date)"
        echo "# Bond      : ${BOND_NAME}"
        echo "# IP列表    : ${IP_LIST_FILE}"
        echo "# 主机总数  : ${total}"
        echo "########################################"
        echo ""
    } > ${RESULT_FILE}

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   LLDP 对端交换机信息采集              ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "Bond      : ${BOND_NAME}"
    echo "IP列表    : ${IP_LIST_FILE}"
    echo "主机总数  : ${total}"
    echo "结果文件  : ${RESULT_FILE}"
    echo ""

    local count=0
    local success=0
    local failed=0

    while IFS= read -r host <&3 || [ -n "$host" ]; do
        [[ -z "$host" || "$host" =~ ^# ]] && continue

        host=$(echo "$host" | tr -d '[:space:]')

        count=$((count + 1))
        echo -e "${YELLOW}[${count}/${total}] 处理主机: ${host}${NC}"

        if process_host "${host}"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi

    done 3< "${IP_LIST_FILE}"

    {
        echo "########################################"
        echo "# 采集完成"
        echo "# 总数  : ${count}"
        echo "# 成功  : ${success}"
        echo "# 失败  : ${failed}"
        echo "########################################"
    } >> ${RESULT_FILE}

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} 采集完成！${NC}"
    echo -e " 总数    : ${count}"
    echo -e " 成功    : ${success}"
    echo -e " 失败    : ${failed}"
    echo -e " 结果文件: ${RESULT_FILE}"
    echo -e "${GREEN}========================================${NC}"
}

main
