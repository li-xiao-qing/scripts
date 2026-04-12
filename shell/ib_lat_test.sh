#!/bin/bash
# ib_lat_test.sh
# 支持 ib_write_lat / ib_read_lat / ib_send_lat
# 可指定单一类型或 all 执行全部延迟测试

#===========================================
# 使用方法
#===========================================
usage() {
    echo "用法: $0 [测试类型]"
    echo ""
    echo "测试类型:"
    echo "  all     - 依次执行 write/read/send (默认)"
    echo "  write   - ib_write_lat"
    echo "  read    - ib_read_lat"
    echo "  send    - ib_send_lat"
    echo ""
    echo "示例:"
    echo "  $0          # 执行全部"
    echo "  $0 all      # 执行全部"
    echo "  $0 write    # 仅 write"
    exit 1
}

#===========================================
# 解析参数
#===========================================
TEST_TYPE=${1:-"all"}

case ${TEST_TYPE} in
    all|write|read|send) ;;
    -h|--help) usage ;;
    *)
        echo "不支持的测试类型: ${TEST_TYPE}"
        usage
        ;;
esac

#===========================================
# 配置区域
#===========================================
SERVER_IP="10.36.33.170"     # 管理IP，仅用于SSH登录
SERVER_USER="root"
IB_DEV="mlx5_bond_2"
TCLASS="16"
GID_INDEX="3"
ITERATIONS="1000"
SERVER_WAIT_TIMEOUT=10
CLIENT_TIMEOUT=60

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="./ib_lat_result"
mkdir -p "${OUTPUT_DIR}"

SIZES=(2 4 8 16 32 64 128 256 512 1024 2048 4096 8192 16384 \
       32768 65536 131072 262144 524288 1048576 2097152 4194304 8388608)

#===========================================
# 颜色定义
#===========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# SSH公共参数（抑制banner输出）
SSH_OPTS="-o StrictHostKeyChecking=no \
          -o ConnectTimeout=5 \
          -o BatchMode=yes \
          -o LogLevel=ERROR"

# PSSH公共参数
PSSH_OPTS="-o StrictHostKeyChecking=no \
           -o LogLevel=ERROR"

#===========================================
# 获取本机 IB_DEV 对应的业务IP
#===========================================
get_local_bond_ip() {
    local netdev
    netdev=$(ibdev2netdev 2>/dev/null \
        | grep "${IB_DEV}" \
        | awk '{print $5}')

    if [ -z "${netdev}" ]; then
        echo -e "${RED}[ERROR] 本机未找到 ${IB_DEV} 对应的网络接口${NC}" >&2
        exit 1
    fi

    local bond_ip
    bond_ip=$(ip addr show "${netdev}" 2>/dev/null \
        | grep "inet " \
        | awk '{print $2}' \
        | cut -d'/' -f1)

    if [ -z "${bond_ip}" ]; then
        echo -e "${RED}[ERROR] 本机网络接口 ${netdev} 未获取到IP，请检查 ${IB_DEV} 配置${NC}" >&2
        exit 1
    fi

    echo "${bond_ip}"
}

#===========================================
# 获取server端 IB_DEV 对应的业务IP
#===========================================
get_server_bond_ip() {
    local netdev
    netdev=$(ssh ${SSH_OPTS} \
        ${SERVER_USER}@${SERVER_IP} \
        "ibdev2netdev 2>/dev/null \
         | grep '${IB_DEV}' \
         | awk '{print \$5}'" 2>/dev/null)

    if [ -z "${netdev}" ]; then
        echo -e "${RED}[ERROR] server端未找到 ${IB_DEV} 对应的网络接口${NC}" >&2
        exit 1
    fi

    local bond_ip
    bond_ip=$(ssh ${SSH_OPTS} \
        ${SERVER_USER}@${SERVER_IP} \
        "ip addr show ${netdev} 2>/dev/null \
         | grep 'inet ' \
         | awk '{print \$2}' \
         | cut -d'/' -f1" 2>/dev/null)

    if [ -z "${bond_ip}" ]; then
        echo -e "${RED}[ERROR] server端网络接口 ${netdev} 未获取到IP，请检查 ${IB_DEV} 配置${NC}" >&2
        exit 1
    fi

    echo "${bond_ip}"
}

#===========================================
# 打印表头
#===========================================
print_header() {
    printf "%-12s %-14s %-14s %-14s %-18s %-14s %-16s %-24s %-s\n" \
        "#bytes" \
        "#iterations" \
        "t_min[usec]" \
        "t_max[usec]" \
        "t_typical[usec]" \
        "t_avg[usec]" \
        "t_stdev[usec]" \
        "99% percentile[usec]" \
        "99.9% percentile[usec]"
}

#===========================================
# 打印对齐的一行数据
#===========================================
print_row() {
    local line="$1"
    local bytes=$(echo "$line"     | awk '{print $1}')
    local iters=$(echo "$line"     | awk '{print $2}')
    local t_min=$(echo "$line"     | awk '{print $3}')
    local t_max=$(echo "$line"     | awk '{print $4}')
    local t_typical=$(echo "$line" | awk '{print $5}')
    local t_avg=$(echo "$line"     | awk '{print $6}')
    local t_stdev=$(echo "$line"   | awk '{print $7}')
    local p99=$(echo "$line"       | awk '{print $8}')
    local p999=$(echo "$line"      | awk '{print $9}')

    printf "%-12s %-14s %-14s %-14s %-18s %-14s %-16s %-24s %-s\n" \
        "$bytes" "$iters" "$t_min" "$t_max" \
        "$t_typical" "$t_avg" "$t_stdev" "$p99" "$p999"
}

#===========================================
# 检查pssh
#===========================================
check_pssh() {
    if ! command -v pssh &> /dev/null; then
        echo -e "${RED}[ERROR] pssh 未安装，请先执行: sudo yum install pssh -y${NC}"
        exit 1
    fi
}

#===========================================
# 检查SSH免密
#===========================================
check_ssh() {
    ssh ${SSH_OPTS} \
        ${SERVER_USER}@${SERVER_IP} "echo ok" &>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR] SSH免密登录失败，请先执行: ssh-copy-id ${SERVER_USER}@${SERVER_IP}${NC}"
        exit 1
    fi
}

#===========================================
# 检查工具是否存在
#===========================================
check_tool() {
    local tool=$1
    if ! command -v ${tool} &> /dev/null; then
        echo -e "${RED}[ERROR] 本机未找到 ${tool}，请安装 perftest${NC}"
        exit 1
    fi
    ssh ${SSH_OPTS} \
        ${SERVER_USER}@${SERVER_IP} \
        "command -v ${tool}" &>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR] server端未找到 ${tool}，请安装 perftest${NC}"
        exit 1
    fi
}

#===========================================
# 停止server端残留进程
#===========================================
kill_server() {
    pssh -H "${SERVER_USER}@${SERVER_IP}" \
         -t 10 -i \
         -x "${PSSH_OPTS}" \
         "pkill -f ${IB_TOOL} 2>/dev/null; sleep 0.5" &>/dev/null
}

#===========================================
# 启动server端
#===========================================
start_server() {
    local size=$1
    pssh -H "${SERVER_USER}@${SERVER_IP}" \
         -t 30 -i \
         -x "${PSSH_OPTS}" \
         "nohup ${IB_TOOL} \
             -x ${GID_INDEX} \
             -n ${ITERATIONS} \
             --tclass=${TCLASS} \
             --ib-dev=${IB_DEV} \
             -s ${size} \
             > /tmp/ib_lat_server_${size}.log 2>&1 &
          sleep 0.5" &>/dev/null
}

#===========================================
# 验证server端是否成功启动
# 返回: 0=成功 1=失败
#===========================================
verify_server() {
    local size=$1
    local timeout=${SERVER_WAIT_TIMEOUT}
    local waited=0

    echo "=== verify_server size=${size} ===" >> ${RAW_LOG}

    while [ ${waited} -lt ${timeout} ]; do
        local pid
        pid=$(ssh ${SSH_OPTS} \
            ${SERVER_USER}@${SERVER_IP} \
            "pgrep -f '${IB_TOOL}'" 2>/dev/null)

        if [ -n "${pid}" ]; then
            local log_status
            log_status=$(ssh ${SSH_OPTS} \
                ${SERVER_USER}@${SERVER_IP} \
                "cat /tmp/ib_lat_server_${size}.log 2>/dev/null")

            if echo "${log_status}" | grep -qiE "error|failed|cannot|unable"; then
                echo "[ERROR] server启动失败 size=${size}" >> ${RAW_LOG}
                echo "${log_status}"                       >> ${RAW_LOG}
                echo -e "${RED}[ERROR] size=${size} server启动失败，详情见: ${RAW_LOG}${NC}" >&2
                return 1
            fi

            echo "server已启动 pid=${pid} waited=${waited}s" >> ${RAW_LOG}
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    # 超时
    local timeout_log
    timeout_log=$(ssh ${SSH_OPTS} \
        ${SERVER_USER}@${SERVER_IP} \
        "cat /tmp/ib_lat_server_${size}.log 2>/dev/null")
    echo "[ERROR] server启动超时 size=${size}" >> ${RAW_LOG}
    echo "${timeout_log}"                      >> ${RAW_LOG}
    echo -e "${RED}[ERROR] size=${size} server启动超时，详情见: ${RAW_LOG}${NC}" >&2
    return 1
}

#===========================================
# 执行client测试
#===========================================
run_client() {
    local size=$1

    local stderr_tmp=$(mktemp)
    local raw_output
    raw_output=$(timeout ${CLIENT_TIMEOUT} ${IB_TOOL} \
        -x ${GID_INDEX} \
        -n ${ITERATIONS} \
        --tclass=${TCLASS} \
        --ib-dev=${IB_DEV} \
        -s ${size} \
        ${SERVER_BOND_IP} 2>${stderr_tmp})
    local rc=$?

    {
        echo "=== size=${size} rc=${rc} ==="
        echo "$raw_output"
        if [ -s "${stderr_tmp}" ]; then
            echo "--- stderr ---"
            cat "${stderr_tmp}"
        fi
    } >> ${RAW_LOG}
    rm -f "${stderr_tmp}"

    if [ ${rc} -eq 124 ]; then
        echo -e "${RED}[ERROR] size=${size} client测试超时(${CLIENT_TIMEOUT}s)${NC}" >&2
    elif [ ${rc} -ne 0 ]; then
        echo -e "${RED}[ERROR] size=${size} client测试失败(rc=${rc})，详情见: ${RAW_LOG}${NC}" >&2
    fi

    # 提取数据行
    local data_line
    data_line=$(echo "$raw_output" \
        | grep -E "^[[:space:]]*[0-9]+" \
        | grep -v "^[[:space:]]*#" \
        | tail -1)

    if [ -n "$data_line" ]; then
        local formatted
        formatted=$(print_row "$data_line")
        echo "$formatted"
        echo "$formatted" >> ${RESULT_FILE}
    else
        echo -e "${RED}[WARN] size=${size} 未获取到数据，详情见: ${RAW_LOG}${NC}" >&2
        printf "%-12s %-14s %-14s %-14s %-18s %-14s %-16s %-24s %-s\n" \
            "${size}" "-" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" \
            >> ${RESULT_FILE}
    fi
}

#===========================================
# Ctrl+C 退出时清理server端残留进程
#===========================================
cleanup_on_exit() {
    echo ""
    echo -e "${YELLOW}[INFO] 捕获到中断信号，正在清理本地和server端进程...${NC}"
    pkill -f "ib_write_lat\|ib_read_lat\|ib_send_lat" 2>/dev/null
    for tool in ib_write_lat ib_read_lat ib_send_lat; do
        pssh -H "${SERVER_USER}@${SERVER_IP}" \
             -t 10 -i \
             -x "${PSSH_OPTS}" \
             "pkill -f ${tool} 2>/dev/null" &>/dev/null
    done
    echo -e "${YELLOW}[INFO] 清理完成，退出${NC}"
    exit 130
}
trap cleanup_on_exit INT TERM

#===========================================
# 执行单个类型的延迟测试
# 参数: test_name (write/read/send)
#===========================================
run_single_test() {
    local test_name=$1

    case ${test_name} in
        write) IB_TOOL="ib_write_lat" ;;
        read)  IB_TOOL="ib_read_lat"  ;;
        send)  IB_TOOL="ib_send_lat"  ;;
    esac

    RESULT_FILE="${OUTPUT_DIR}/ib_${test_name}_lat_result_${TIMESTAMP}.txt"
    RAW_LOG="${OUTPUT_DIR}/ib_${test_name}_lat_raw_${TIMESTAMP}.log"

    check_tool "${IB_TOOL}"

    # 初始化文件
    > ${RAW_LOG}

    # 构建测试命令字符串
    local server_cmd="${IB_TOOL} -x ${GID_INDEX} -n ${ITERATIONS} --tclass=${TCLASS} --ib-dev=${IB_DEV} -s <size>"
    local client_cmd="${IB_TOOL} -x ${GID_INDEX} -n ${ITERATIONS} --tclass=${TCLASS} --ib-dev=${IB_DEV} -s <size> ${SERVER_BOND_IP}"

    # 写入结果文件头部（仅基本信息）
    {
        echo "########################################"
        echo "# ${IB_TOOL} 延迟测试结果"
        echo "########################################"
        echo "# 时间         : $(date)"
        echo "# Client 管理IP: ${CLIENT_MGMT_IP}"
        echo "# Server 管理IP: ${SERVER_IP}"
        echo "# Client 业务IP: ${CLIENT_BOND_IP}"
        echo "# Server 业务IP: ${SERVER_BOND_IP}"
        echo "# Device       : ${IB_DEV}"
        echo "# 迭代数       : ${ITERATIONS}"
        echo "########################################"
        echo ""
    } > ${RESULT_FILE}

    # 写入RAW日志头部（含详细测试命令信息）
    {
        echo "########################################"
        echo "# ${IB_TOOL} 延迟测试 RAW LOG"
        echo "########################################"
        echo "# 时间         : $(date)"
        echo "# Client 管理IP: ${CLIENT_MGMT_IP}"
        echo "# Server 管理IP: ${SERVER_IP}"
        echo "# Client 业务IP: ${CLIENT_BOND_IP}"
        echo "# Server 业务IP: ${SERVER_BOND_IP}"
        echo "# Device       : ${IB_DEV}"
        echo "# tclass       : ${TCLASS}"
        echo "# GID          : ${GID_INDEX}"
        echo "# 迭代数       : ${ITERATIONS}"
        echo "#"
        echo "# 测试命令:"
        echo "#   [Server端] ${server_cmd}"
        echo "#   [Client端] ${client_cmd}"
        echo "########################################"
        echo ""
    } >> ${RAW_LOG}

    # 终端打印信息
    echo ""
    echo -e "${BLUE}========== ${IB_TOOL} ==========${NC}"
    echo "结果文件     : ${RESULT_FILE}"
    echo ""

    # 清理残留进程
    kill_server

    # 打印表头（终端+文件）
    local header
    header=$(print_header)
    echo "$header"
    echo "$header" >> ${RESULT_FILE}

    local total=${#SIZES[@]}
    local idx=0

    for size in "${SIZES[@]}"; do
        idx=$((idx + 1))
        echo -ne "${YELLOW}  [${idx}/${total}] size=${size} 测试中...${NC}\r" >&2

        start_server ${size}

        if ! verify_server ${size}; then
            echo -e "${RED}  [${idx}/${total}] size=${size} server启动失败${NC}" >&2
            printf "%-12s %-14s %-14s %-14s %-18s %-14s %-16s %-24s %-s\n" \
                "${size}" "-" "ERR" "ERR" "ERR" "ERR" "ERR" "ERR" "ERR" \
                | tee -a ${RESULT_FILE}
            kill_server
            continue
        fi

        run_client ${size}
        kill_server
    done

    echo ""
    echo -e "${GREEN}${IB_TOOL} 测试完成，结果文件: ${RESULT_FILE}${NC}"
}

#===========================================
# 主流程
#===========================================
main() {
    check_pssh
    check_ssh

    CLIENT_BOND_IP=$(get_local_bond_ip)
    SERVER_BOND_IP=$(get_server_bond_ip)
    CLIENT_MGMT_IP=$(hostname -i 2>/dev/null | awk '{print $1}')

    echo "Client 管理IP: ${CLIENT_MGMT_IP}"
    echo "Server 管理IP: ${SERVER_IP}"
    echo "Client 业务IP: ${CLIENT_BOND_IP}"
    echo "Server 业务IP: ${SERVER_BOND_IP}"
    echo "Device       : ${IB_DEV}"
    echo "迭代数       : ${ITERATIONS}"

    local test_list=()
    if [ "${TEST_TYPE}" = "all" ]; then
        test_list=(write read send)
    else
        test_list=("${TEST_TYPE}")
    fi

    for t in "${test_list[@]}"; do
        run_single_test "${t}"
    done

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} 全部测试完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
}

main
