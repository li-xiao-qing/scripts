#!/bin/bash
# ib_bw_test.sh
# 支持 ib_write_bw / ib_read_bw / ib_send_bw
# 测试场景: 内存单向 + 内存双向 + 内存单向CM + 内存双向CM
#           + 显存单向 + 显存双向 + 显存单向CM + 显存双向CM
# 可指定单一类型或 all 执行全部带宽测试

#===========================================
# 使用方法
#===========================================
usage() {
    echo "用法: $0 [测试类型]"
    echo ""
    echo "测试类型:"
    echo "  all     - 依次执行 write/read/send (默认)"
    echo "  write   - ib_write_bw"
    echo "  read    - ib_read_bw"
    echo "  send    - ib_send_bw"
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
SERVER_IP="10.36.33.170"        # 管理IP，仅用于SSH登录
SERVER_USER="root"
IB_DEV="mlx5_bond_2"
TCLASS="16"
GID_INDEX="3"
ITERATIONS="1000"
MSG_SIZE="65536"
SERVER_WAIT_TIMEOUT=10
CLIENT_TIMEOUT=60

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="./ib_bw_result"
mkdir -p "${OUTPUT_DIR}"

# QP数量列表
QPS=(1 4 16 64 128 256 512 1024)

#===========================================
# 颜色定义
#===========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# SSH公共参数（LogLevel=ERROR 抑制banner）
SSH_OPTS="-o StrictHostKeyChecking=no \
          -o ConnectTimeout=5 \
          -o BatchMode=yes \
          -o LogLevel=ERROR"

# PSSH额外SSH参数
PSSH_SSH_OPTS="-o StrictHostKeyChecking=no \
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
# 检查CUDA/GDR环境
# 返回: true / false
#===========================================
check_gdr() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "${RED}[WARN] 本机未找到nvidia-smi，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    if [ "${gpu_count}" -eq 0 ]; then
        echo -e "${RED}[WARN] 本机未检测到GPU，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    ssh ${SSH_OPTS} \
        ${SERVER_USER}@${SERVER_IP} \
        "command -v nvidia-smi" &>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}[WARN] server端未找到nvidia-smi，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    local server_gpu_count
    server_gpu_count=$(ssh ${SSH_OPTS} \
        ${SERVER_USER}@${SERVER_IP} \
        "nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l")
    if [ "${server_gpu_count}" -eq 0 ]; then
        echo -e "${RED}[WARN] server端未检测到GPU，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    echo "true"
}

#===========================================
# 打印表头
#===========================================
print_header() {
    printf "%-28s" "测试场景(Gbps)"
    for qp in "${QPS[@]}"; do
        printf "%-12s" "QP=${qp}"
    done
    printf "\n"

    local sep_len=$((28 + 12 * ${#QPS[@]}))
    printf '%*s\n' "${sep_len}" '' | tr ' ' '-'
}

#===========================================
# 打印一行数据
#===========================================
print_row() {
    local label=$1
    shift
    local values=("$@")

    printf "%-28s" "${label}"
    for val in "${values[@]}"; do
        printf "%-12s" "${val}"
    done
    printf "\n"
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
         -x "${PSSH_SSH_OPTS}" \
         -t 10 -i \
         "pkill -f ${IB_TOOL} 2>/dev/null; sleep 0.5" &>/dev/null
}

#===========================================
# 构建GID参数（CM模式不需要GID）
#===========================================
build_gid_param() {
    local use_cm=$1
    if [ "${use_cm}" = "-R" ]; then
        echo ""
    else
        echo "-x ${GID_INDEX}"
    fi
}

#===========================================
# 构建完整命令字符串（用于日志展示）
#===========================================
build_cmd_str() {
    local side=$1
    local qp=$2
    local bidir=$3
    local use_cuda=$4
    local use_cm=$5

    local gid_param
    gid_param=$(build_gid_param "${use_cm}")

    local cmd="${IB_TOOL}"
    [ -n "${gid_param}" ] && cmd="${cmd} ${gid_param}"
    cmd="${cmd} -n ${ITERATIONS}"
    cmd="${cmd} --tclass=${TCLASS}"
    cmd="${cmd} --ib-dev=${IB_DEV}"
    cmd="${cmd} -s ${MSG_SIZE}"
    cmd="${cmd} --qp=${qp}"
    cmd="${cmd} --report_gbits"
    [ -n "${bidir}"    ] && cmd="${cmd} ${bidir}"
    [ -n "${use_cuda}" ] && cmd="${cmd} ${use_cuda}"
    [ -n "${use_cm}"   ] && cmd="${cmd} ${use_cm}"
    [ "${side}" = "client" ] && cmd="${cmd} ${SERVER_BOND_IP}"

    echo "${cmd}"
}

#===========================================
# 生成场景对应命令说明
#===========================================
build_cmd_info() {
    local idx=$1
    local label=$2
    local bidir=$3
    local use_cuda=$4
    local use_cm=$5

    local server_cmd
    local client_cmd
    server_cmd=$(build_cmd_str "server" "<qp>" "${bidir}" "${use_cuda}" "${use_cm}")
    client_cmd=$(build_cmd_str "client" "<qp>" "${bidir}" "${use_cuda}" "${use_cm}")

    echo "#   场景${idx} [${label}]"
    echo "#     Server端: ${server_cmd}"
    echo "#     Client端: ${client_cmd}"
    echo "#"
}

#===========================================
# 启动server端
# 参数: qp bidir use_cuda use_cm
#===========================================
start_server() {
    local qp=$1
    local bidir=$2
    local use_cuda=$3
    local use_cm=$4

    local gid_param
    gid_param=$(build_gid_param "${use_cm}")

    pssh -H "${SERVER_USER}@${SERVER_IP}" \
         -x "${PSSH_SSH_OPTS}" \
         -t 30 -i \
         "nohup ${IB_TOOL} \
             ${gid_param} \
             -n ${ITERATIONS} \
             --tclass=${TCLASS} \
             --ib-dev=${IB_DEV} \
             -s ${MSG_SIZE} \
             --qp=${qp} \
             --report_gbits \
             ${bidir} \
             ${use_cuda} \
             ${use_cm} \
             > /tmp/ib_bw_server_qp${qp}.log 2>&1 &
          sleep 0.5" &>/dev/null
}

#===========================================
# 验证server端是否成功启动
# 返回: 0=成功 1=失败
#===========================================
verify_server() {
    local qp=$1
    local timeout=${SERVER_WAIT_TIMEOUT}
    local waited=0

    echo "=== verify_server qp=${qp} ===" >> ${RAW_LOG}

    while [ ${waited} -lt ${timeout} ]; do
        local pid
        pid=$(ssh ${SSH_OPTS} \
            ${SERVER_USER}@${SERVER_IP} \
            "pgrep -f '${IB_TOOL}'" 2>/dev/null)

        if [ -n "${pid}" ]; then
            local log_status
            log_status=$(ssh ${SSH_OPTS} \
                ${SERVER_USER}@${SERVER_IP} \
                "cat /tmp/ib_bw_server_qp${qp}.log 2>/dev/null")

            if echo "${log_status}" | grep -qiE "error|failed|cannot|unable"; then
                echo "[ERROR] server启动失败 qp=${qp}" >> ${RAW_LOG}
                echo "${log_status}"                   >> ${RAW_LOG}
                echo -e "${RED}[ERROR] QP=${qp} server启动失败，详情见: ${RAW_LOG}${NC}" >&2
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
        "cat /tmp/ib_bw_server_qp${qp}.log 2>/dev/null")
    echo "[ERROR] server启动超时 qp=${qp}" >> ${RAW_LOG}
    echo "${timeout_log}"                  >> ${RAW_LOG}
    echo -e "${RED}[ERROR] QP=${qp} server启动超时，详情见: ${RAW_LOG}${NC}" >&2
    return 1
}

#===========================================
# 执行client测试，返回带宽值(Gbps)
# 参数: qp bidir use_cuda use_cm
#===========================================
run_client() {
    local qp=$1
    local bidir=$2
    local use_cuda=$3
    local use_cm=$4

    local gid_param
    gid_param=$(build_gid_param "${use_cm}")

    local stderr_tmp=$(mktemp)
    local raw_output
    raw_output=$(timeout ${CLIENT_TIMEOUT} ${IB_TOOL} \
        ${gid_param} \
        -n ${ITERATIONS} \
        --tclass=${TCLASS} \
        --ib-dev=${IB_DEV} \
        -s ${MSG_SIZE} \
        --qp=${qp} \
        --report_gbits \
        ${bidir} \
        ${use_cuda} \
        ${use_cm} \
        ${SERVER_BOND_IP} 2>${stderr_tmp})
    local rc=$?

    {
        echo "=== qp=${qp} bidir=${bidir} cuda=${use_cuda} cm=${use_cm} rc=${rc} ==="
        echo "$raw_output"
        if [ -s "${stderr_tmp}" ]; then
            echo "--- stderr ---"
            cat "${stderr_tmp}"
        fi
    } >> ${RAW_LOG}
    rm -f "${stderr_tmp}"

    if [ ${rc} -eq 124 ]; then
        echo -e "${RED}[ERROR] QP=${qp} client测试超时(${CLIENT_TIMEOUT}s)${NC}" >&2
        echo "TIMEOUT"
        return 0
    elif [ ${rc} -ne 0 ]; then
        echo -e "${RED}[ERROR] QP=${qp} client测试失败(rc=${rc})，详情见: ${RAW_LOG}${NC}" >&2
    fi

    # 取第4列 BW average[Gb/sec]
    local bw
    bw=$(echo "$raw_output" \
        | grep -E "^[[:space:]]*[0-9]+" \
        | grep -v "^[[:space:]]*#" \
        | awk '{print $4}' \
        | tail -1)

    if [ -n "$bw" ]; then
        echo "${bw}"
    else
        echo "N/A"
    fi
}

#===========================================
# 运行一组测试（遍历所有QP数量）
# 参数: label bidir use_cuda use_cm
#===========================================
run_test_group() {
    local label=$1
    local bidir=$2
    local use_cuda=$3
    local use_cm=$4

    local bw_values=()

    local total=${#QPS[@]}
    local idx=0

    for qp in "${QPS[@]}"; do
        idx=$((idx + 1))
        echo -ne "${YELLOW}  [${idx}/${total}] QP=${qp} 测试中...${NC}\r" >&2

        start_server ${qp} "${bidir}" "${use_cuda}" "${use_cm}"

        if ! verify_server ${qp}; then
            echo -e "${RED}  [${idx}/${total}] QP=${qp} server启动失败，跳过${NC}" >&2
            bw_values+=("ERR")
            kill_server
            continue
        fi

        local bw
        bw=$(run_client ${qp} "${bidir}" "${use_cuda}" "${use_cm}")
        kill_server

        bw_values+=("${bw}")
        echo -e "  QP=${qp}: ${bw} Gbps" >&2
    done

    echo ""
    print_row "${label}" "${bw_values[@]}"
    print_row "${label}" "${bw_values[@]}" >> ${RESULT_FILE}
}

#===========================================
# Ctrl+C 退出时清理server端残留进程
#===========================================
cleanup_on_exit() {
    echo ""
    echo -e "${YELLOW}[INFO] 捕获到中断信号，正在清理本地和server端进程...${NC}"
    pkill -f "ib_write_bw\|ib_read_bw\|ib_send_bw" 2>/dev/null
    for tool in ib_write_bw ib_read_bw ib_send_bw; do
        pssh -H "${SERVER_USER}@${SERVER_IP}" \
             -x "${PSSH_SSH_OPTS}" \
             -t 10 -i \
             "pkill -f ${tool} 2>/dev/null" &>/dev/null
    done
    echo -e "${YELLOW}[INFO] 清理完成，退出${NC}"
    exit 130
}
trap cleanup_on_exit INT TERM

#===========================================
# 执行单个类型的带宽测试
# 参数: test_name (write/read/send)
#===========================================
run_single_test() {
    local test_name=$1

    case ${test_name} in
        write) IB_TOOL="ib_write_bw" ;;
        read)  IB_TOOL="ib_read_bw"  ;;
        send)  IB_TOOL="ib_send_bw"  ;;
    esac

    local client_ip_tag=${CLIENT_MGMT_IP//./-}
    local server_ip_tag=${SERVER_IP//./-}
    RESULT_FILE="${OUTPUT_DIR}/ib_${test_name}_bw_${client_ip_tag}_${server_ip_tag}_result_${TIMESTAMP}.txt"
    RAW_LOG="${OUTPUT_DIR}/ib_${test_name}_bw_${client_ip_tag}_${server_ip_tag}_raw_${TIMESTAMP}.log"

    check_tool "${IB_TOOL}"

    # 检查GDR环境
    GDR_AVAILABLE=$(check_gdr)

    # 初始化文件
    > ${RAW_LOG}

    # 写入结果文件头部（仅基本信息）
    {
        echo "########################################"
        echo "# ${IB_TOOL} 带宽测试结果"
        echo "########################################"
        echo "# 时间         : $(date)"
        echo "# Client 管理IP: ${CLIENT_MGMT_IP}"
        echo "# Server 管理IP: ${SERVER_IP}"
        echo "# Client 业务IP: ${CLIENT_BOND_IP}"
        echo "# Server 业务IP: ${SERVER_BOND_IP}"
        echo "# Device       : ${IB_DEV}"
        echo "# 迭代数       : ${ITERATIONS}"
        echo "# 消息大小     : ${MSG_SIZE} bytes"
        echo "# QP列表       : ${QPS[*]}"
        echo "# GDR可用      : ${GDR_AVAILABLE}"
        echo "########################################"
        echo ""
    } > ${RESULT_FILE}

    # 写入RAW日志头部（含详细测试命令信息）
    {
        echo "########################################"
        echo "# ${IB_TOOL} 带宽测试 RAW LOG"
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
        echo "# 消息大小     : ${MSG_SIZE} bytes"
        echo "# QP列表       : ${QPS[*]}"
        echo "# GDR可用      : ${GDR_AVAILABLE}"
        echo "#"
        echo "# 测试场景及对应命令:"
        echo "#"
        build_cmd_info "1" "内存单向"    ""                 ""           ""
        build_cmd_info "2" "内存双向"    "--bidirectional"  ""           ""
        build_cmd_info "3" "内存单向 CM" ""                 ""           "-R"
        build_cmd_info "4" "内存双向 CM" "--bidirectional"  ""           "-R"
        if [ "${GDR_AVAILABLE}" = "true" ]; then
            build_cmd_info "5" "显存单向"    ""                "--use_cuda"  ""
            build_cmd_info "6" "显存双向"    "--bidirectional" "--use_cuda"  ""
            build_cmd_info "7" "显存单向 CM" ""                "--use_cuda"  "-R"
            build_cmd_info "8" "显存双向 CM" "--bidirectional" "--use_cuda"  "-R"
        else
            echo "# 场景5-8: 显存测试 (跳过，GPU不可用)"
            echo "#"
        fi
        echo "########################################"
        echo ""
    } >> ${RAW_LOG}

    # 终端打印信息
    echo ""
    echo -e "${BLUE}========== ${IB_TOOL} ==========${NC}"
    echo "消息大小     : ${MSG_SIZE} bytes"
    echo "QP列表       : ${QPS[*]}"
    echo "GDR可用      : ${GDR_AVAILABLE}"
    echo "结果文件     : ${RESULT_FILE}"
    echo ""

    # 清理残留进程
    kill_server

    # 打印表头（终端+文件）
    local header
    header=$(print_header)
    echo "$header"
    echo "$header" >> ${RESULT_FILE}

    # 1. 内存单向
    echo ""
    echo -e "${BLUE}--- 1/8 内存单向 ---${NC}"
    echo "# 1. 内存单向" >> ${RAW_LOG}
    run_test_group "Mem 单向" "" "" ""

    # 2. 内存双向
    echo ""
    echo -e "${BLUE}--- 2/8 内存双向 ---${NC}"
    echo "# 2. 内存双向" >> ${RAW_LOG}
    run_test_group "Mem 双向" "--bidirectional" "" ""

    # 3. 内存单向 CM
    echo ""
    echo -e "${BLUE}--- 3/8 内存单向 CM ---${NC}"
    echo "# 3. 内存单向 CM" >> ${RAW_LOG}
    run_test_group "Mem 单向 CM" "" "" "-R"

    # 4. 内存双向 CM
    echo ""
    echo -e "${BLUE}--- 4/8 内存双向 CM ---${NC}"
    echo "# 4. 内存双向 CM" >> ${RAW_LOG}
    run_test_group "Mem 双向 CM" "--bidirectional" "" "-R"

    # 5-8. 显存测试
    if [ "${GDR_AVAILABLE}" = "true" ]; then
        echo ""
        echo -e "${BLUE}--- 5/8 显存单向 ---${NC}"
        echo "# 5. 显存单向" >> ${RAW_LOG}
        run_test_group "GDR 单向" "" "--use_cuda" ""

        echo ""
        echo -e "${BLUE}--- 6/8 显存双向 ---${NC}"
        echo "# 6. 显存双向" >> ${RAW_LOG}
        run_test_group "GDR 双向" "--bidirectional" "--use_cuda" ""

        echo ""
        echo -e "${BLUE}--- 7/8 显存单向 CM ---${NC}"
        echo "# 7. 显存单向 CM" >> ${RAW_LOG}
        run_test_group "GDR 单向 CM" "" "--use_cuda" "-R"

        echo ""
        echo -e "${BLUE}--- 8/8 显存双向 CM ---${NC}"
        echo "# 8. 显存双向 CM" >> ${RAW_LOG}
        run_test_group "GDR 双向 CM" "--bidirectional" "--use_cuda" "-R"
    else
        echo ""
        echo -e "${RED}[SKIP] GPU不可用，跳过显存相关测试(5-8)${NC}"
        {
            echo "# 5. 显存单向    (跳过)"
            echo "# 6. 显存双向    (跳过)"
            echo "# 7. 显存单向 CM (跳过)"
            echo "# 8. 显存双向 CM (跳过)"
        } >> ${RAW_LOG}
    fi

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
