#!/bin/bash
# ib_lat_test.sh
# 支持 ib_write_lat / ib_read_lat / ib_send_lat
# 可指定单一类型或 all 执行全部延迟测试

#===========================================
# 使用方法
#===========================================
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -t TYPE           测试类型: all(默认)/write/read/send"
    echo "  --gdr             启用GDR时延测试（默认仅内存测试）"
    echo "  --no-gpu-affinity 禁用网卡-显卡亲和检测，GDR使用GPU 0（默认启用亲和）"
    echo "  --no-numa         禁用NUMA亲和绑定（默认启用）"
    echo "  --perftest-path PATH  指定perftest工具目录（如 /opt/pg1-tests/perftest/bin）"
    echo "                        默认使用系统PATH中的perftest"
    echo ""
    echo "示例:"
    echo "  $0                # 执行全部（仅内存）"
    echo "  $0 --gdr          # 执行全部（内存+GDR）"
    echo "  $0 -t write       # 仅 write"
    echo "  $0 -t read --gdr  # 仅 read（内存+GDR）"
    echo "  $0 --no-numa      # 全部测试，不绑定NUMA"
    echo "  $0 --perftest-path /opt/pg1-tests/perftest/bin"
    exit 1
}

#===========================================
# 解析参数
#===========================================
NUMA_AFFINITY=true
GPU_AFFINITY=true
ENABLE_GDR=false
PERFTEST_PATH=""
TEST_TYPE="all"

while [ $# -gt 0 ]; do
    case $1 in
        -t)                TEST_TYPE="$2"; shift 2 ;;
        --gdr)             ENABLE_GDR=true; shift ;;
        --no-numa)         NUMA_AFFINITY=false; shift ;;
        --no-gpu-affinity) GPU_AFFINITY=false; shift ;;
        --perftest-path)   PERFTEST_PATH="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *)
            echo "不支持的参数: $1"
            usage
            ;;
    esac
done

case ${TEST_TYPE} in
    all|write|read|send) ;;
    *) echo "不支持的测试类型: ${TEST_TYPE}"; usage ;;
esac

#===========================================
# 配置区域
#===========================================
SERVER_IP="10.36.33.111"     # 管理IP，仅用于SSH登录
SERVER_USER="root"
IB_DEV="mlx5_bond_2"
TCLASS="16"
GID_INDEX="3"
ITERATIONS="10000"
SERVER_WAIT_TIMEOUT=10
CLIENT_TIMEOUT=300

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="./ib_lat_result"
mkdir -p "${OUTPUT_DIR}"

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
# 获取 IB 设备的 NUMA 节点号
# 参数: ib_dev [remote]
# 返回: NUMA 节点号，检测失败返回空
#===========================================
get_numa_node() {
    local ib_dev=$1
    local remote=$2

    local numa_node
    if [ "${remote}" = "remote" ]; then
        numa_node=$(ssh ${SSH_OPTS} ${SERVER_USER}@${SERVER_IP} \
            "cat /sys/class/infiniband/${ib_dev}/device/numa_node 2>/dev/null")
    else
        numa_node=$(cat /sys/class/infiniband/${ib_dev}/device/numa_node 2>/dev/null)
    fi

    if [ -z "$numa_node" ] || [ "$numa_node" = "-1" ]; then
        echo ""
    else
        echo "$numa_node"
    fi
}

#===========================================
# 获取与IB设备亲和的GPU设备号
# 通过 nvidia-smi/ppu-smi topo -m 解析 PIX 关系
# 参数: ib_dev [remote]
# 返回: GPU index（默认 "0"）
#===========================================
get_affinity_gpus() {
    local ib_dev=$1
    local remote=$2

    local topo_file
    topo_file=$(mktemp)

    if [ "${remote}" = "remote" ]; then
        ssh ${SSH_OPTS} ${SERVER_USER}@${SERVER_IP} \
            'if command -v ppu-smi &>/dev/null; then ppu-smi topo -m 2>/dev/null; elif command -v nvidia-smi &>/dev/null; then nvidia-smi topo -m 2>/dev/null; fi' > "${topo_file}"
    else
        if command -v ppu-smi &>/dev/null; then
            ppu-smi topo -m > "${topo_file}" 2>/dev/null
        elif command -v nvidia-smi &>/dev/null; then
            nvidia-smi topo -m > "${topo_file}" 2>/dev/null
        fi
    fi

    if [ ! -s "${topo_file}" ]; then
        rm -f "${topo_file}"
        echo "0"
        return
    fi

    local nic_name=""
    local legend
    legend=$(sed -n '/NIC Legend/,$p' "${topo_file}")
    while IFS= read -r line; do
        if echo "$line" | grep -q "${ib_dev}"; then
            nic_name=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
            break
        fi
    done <<< "$legend"

    if [ -z "$nic_name" ]; then
        rm -f "${topo_file}"
        echo "0"
        return
    fi

    local nic_row=""
    while IFS= read -r line; do
        local first
        first=$(echo "$line" | awk '{print $1}')
        if [ "$first" = "$nic_name" ]; then
            nic_row="$line"
            break
        fi
    done < "${topo_file}"

    if [ -z "$nic_row" ]; then
        rm -f "${topo_file}"
        echo "0"
        return
    fi

    local header_line=""
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "(GPU|PPU)[0-9]"; then
            header_line="$line"
            break
        fi
    done < "${topo_file}"

    rm -f "${topo_file}"

    if [ -z "$header_line" ]; then
        echo "0"
        return
    fi

    local col_idx=0
    for col_name in $header_line; do
        if echo "$col_name" | grep -qiE "^(GPU|PPU)[0-9]+$"; then
            local awk_field=$((col_idx + 2))
            local val
            val=$(echo "$nic_row" | awk -v c=${awk_field} '{print $c}')
            if [ "$val" = "PIX" ]; then
                local gpu_num
                gpu_num=$(echo "$col_name" | sed 's/[^0-9]//g')
                echo "$gpu_num"
                return
            fi
        fi
        col_idx=$((col_idx + 1))
    done

    echo "0"
}

#===========================================
# 检查CUDA/GDR环境
# 返回: true / false
#===========================================
check_gdr() {
    local local_smi="" remote_smi=""

    if command -v ppu-smi &>/dev/null; then
        local_smi="ppu-smi"
    elif command -v nvidia-smi &>/dev/null; then
        local_smi="nvidia-smi"
    else
        echo -e "${RED}[WARN] 本机未找到nvidia-smi/ppu-smi，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    local gpu_count
    if [ "${local_smi}" = "ppu-smi" ]; then
        gpu_count=$(ppu-smi -q 2>/dev/null | grep -c "PPU UUID" || echo 0)
    else
        gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    fi
    if [ "${gpu_count}" -eq 0 ]; then
        echo -e "${RED}[WARN] 本机未检测到GPU/PPU，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    remote_smi=$(ssh ${SSH_OPTS} ${SERVER_USER}@${SERVER_IP} \
        'if command -v ppu-smi &>/dev/null; then echo ppu-smi; elif command -v nvidia-smi &>/dev/null; then echo nvidia-smi; fi' 2>/dev/null)
    if [ -z "${remote_smi}" ]; then
        echo -e "${RED}[WARN] server端未找到nvidia-smi/ppu-smi，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    local server_gpu_count
    if [ "${remote_smi}" = "ppu-smi" ]; then
        server_gpu_count=$(ssh ${SSH_OPTS} ${SERVER_USER}@${SERVER_IP} \
            "ppu-smi -q 2>/dev/null | grep -c 'PPU UUID' || echo 0" 2>/dev/null)
    else
        server_gpu_count=$(ssh ${SSH_OPTS} ${SERVER_USER}@${SERVER_IP} \
            "nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l")
    fi
    if [ "${server_gpu_count}" -eq 0 ]; then
        echo -e "${RED}[WARN] server端未检测到GPU/PPU，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    if ! ${IB_TOOL} --help 2>&1 | grep -q "use_cuda"; then
        echo -e "${RED}[WARN] 本机perftest未编译CUDA支持，将跳过GDR测试${NC}" >&2
        echo "false"; return
    fi

    echo "true"
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
    if [[ "${tool}" == /* ]]; then
        if [ ! -x "${tool}" ]; then
            echo -e "${RED}[ERROR] 本机未找到 ${tool}${NC}"
            exit 1
        fi
        ssh ${SSH_OPTS} ${SERVER_USER}@${SERVER_IP} \
            "test -x ${tool}" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}[ERROR] server端未找到 ${tool}${NC}"
            exit 1
        fi
    else
        if ! command -v ${tool} &> /dev/null; then
            echo -e "${RED}[ERROR] 本机未找到 ${tool}，请安装 perftest${NC}"
            exit 1
        fi
        ssh ${SSH_OPTS} ${SERVER_USER}@${SERVER_IP} \
            "command -v ${tool}" &>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}[ERROR] server端未找到 ${tool}，请安装 perftest${NC}"
            exit 1
        fi
    fi
}

#===========================================
# 停止server端残留进程
#===========================================
kill_server() {
    pssh -H "${SERVER_USER}@${SERVER_IP}" \
         -t 10 -i \
         -x "${PSSH_OPTS}" \
         "pkill -f ${IB_TOOL} 2>/dev/null; wait 2>/dev/null; sleep 0.5" &>/dev/null
    wait 2>/dev/null
}

#===========================================
# 启动server端（-a 模式，所有size一次性测完）
# 参数: [use_cuda]  - "cuda" 表示使用GDR
#===========================================
start_server() {
    local use_cuda=$1
    local cuda_param=""
    [ "${use_cuda}" = "cuda" ] && cuda_param="--use_cuda=${REMOTE_GPU_ID}"

    pssh -H "${SERVER_USER}@${SERVER_IP}" \
         -t 30 -i \
         -x "${PSSH_OPTS}" \
         "nohup ${REMOTE_NUMA_PREFIX} ${IB_TOOL} \
             -x ${GID_INDEX} \
             -n ${ITERATIONS} \
             --tclass=${TCLASS} \
             --ib-dev=${IB_DEV} \
             -a -F \
             ${cuda_param} \
             > /tmp/ib_lat_server.log 2>&1 &
          sleep 0.5" &>/dev/null
}

#===========================================
# 验证server端是否成功启动
# 返回: 0=成功 1=失败
#===========================================
verify_server() {
    local timeout=${SERVER_WAIT_TIMEOUT}
    local waited=0

    echo "=== verify_server ===" >> ${RAW_LOG}

    while [ ${waited} -lt ${timeout} ]; do
        local pid
        pid=$(ssh ${SSH_OPTS} \
            ${SERVER_USER}@${SERVER_IP} \
            "pgrep -f '${IB_TOOL}'" 2>/dev/null)

        if [ -n "${pid}" ]; then
            local log_status
            log_status=$(ssh ${SSH_OPTS} \
                ${SERVER_USER}@${SERVER_IP} \
                "cat /tmp/ib_lat_server.log 2>/dev/null")

            if echo "${log_status}" | grep -qiE "error|failed|cannot|unable"; then
                echo "[ERROR] server启动失败" >> ${RAW_LOG}
                echo "${log_status}"           >> ${RAW_LOG}
                echo -e "${RED}[ERROR] server启动失败，详情见: ${RAW_LOG}${NC}" >&2
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
        "cat /tmp/ib_lat_server.log 2>/dev/null")
    echo "[ERROR] server启动超时" >> ${RAW_LOG}
    echo "${timeout_log}"          >> ${RAW_LOG}
    echo -e "${RED}[ERROR] server启动超时，详情见: ${RAW_LOG}${NC}" >&2
    return 1
}

#===========================================
# 执行client测试（-a模式，测试完成后一次性输出结果）
# 参数: [use_cuda]  - "cuda" 表示使用GDR
#===========================================
run_client() {
    local use_cuda=$1
    local cuda_param=""
    [ "${use_cuda}" = "cuda" ] && cuda_param="--use_cuda=${LOCAL_GPU_ID}"

    local stderr_tmp=$(mktemp)
    local stdout_tmp=$(mktemp)

    echo -ne "${YELLOW}  测试中（所有消息大小）...${NC}" >&2

    timeout ${CLIENT_TIMEOUT} ${LOCAL_NUMA_PREFIX} ${IB_TOOL} \
        -x ${GID_INDEX} \
        -n ${ITERATIONS} \
        --tclass=${TCLASS} \
        --ib-dev=${IB_DEV} \
        -a -F \
        ${cuda_param} \
        ${SERVER_BOND_IP} >${stdout_tmp} 2>${stderr_tmp} &
    local client_pid=$!
    wait ${client_pid} 2>/dev/null
    local rc=$?

    {
        echo "=== rc=${rc} ==="
        cat "${stdout_tmp}"
        if [ -s "${stderr_tmp}" ]; then
            echo "--- stderr ---"
            cat "${stderr_tmp}"
        fi
    } >> ${RAW_LOG}

    printf "\r\033[2K" >&2

    if [ ${rc} -eq 124 ]; then
        echo -e "${RED}[ERROR] client测试超时(${CLIENT_TIMEOUT}s)${NC}" >&2
        rm -f "${stderr_tmp}" "${stdout_tmp}"
        return 124
    elif [ ${rc} -ne 0 ] && [ ${rc} -ne 143 ]; then
        echo -e "${RED}[ERROR] client测试失败(rc=${rc})，详情见: ${RAW_LOG}${NC}" >&2
        rm -f "${stderr_tmp}" "${stdout_tmp}"
        return ${rc}
    fi

    local data_lines
    data_lines=$(grep -E "^[[:space:]]*[0-9]+" "${stdout_tmp}" | grep -v "^[[:space:]]*#")

    rm -f "${stderr_tmp}" "${stdout_tmp}"

    if [ -z "$data_lines" ]; then
        echo -e "${RED}[WARN] 未获取到数据，详情见: ${RAW_LOG}${NC}" >&2
        return 1
    fi

    while IFS= read -r line; do
        local formatted
        formatted=$(print_row "$line")
        echo "$formatted"
        echo "$formatted" >> ${RESULT_FILE}
    done <<< "$data_lines"
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

    local prefix=""
    [ -n "${PERFTEST_PATH}" ] && prefix="${PERFTEST_PATH%/}/"
    case ${test_name} in
        write) IB_TOOL="${prefix}ib_write_lat" ;;
        read)  IB_TOOL="${prefix}ib_read_lat"  ;;
        send)  IB_TOOL="${prefix}ib_send_lat"  ;;
    esac

    local client_ip_tag=${CLIENT_MGMT_IP}
    local server_ip_tag=${SERVER_IP}
    RESULT_FILE="${OUTPUT_DIR}/perf_${client_ip_tag}_${server_ip_tag}_ib_${test_name}_lat_result_${TIMESTAMP}.txt"
    RAW_LOG="${OUTPUT_DIR}/perf_${client_ip_tag}_${server_ip_tag}_ib_${test_name}_lat_raw_${TIMESTAMP}.log"

    check_tool "${IB_TOOL}"

    # 检查GDR环境（仅在 --gdr 时检测）
    GDR_AVAILABLE="false"
    if [ "${ENABLE_GDR}" = "true" ]; then
        GDR_AVAILABLE=$(check_gdr)
    fi

    # 获取GPU ID
    LOCAL_GPU_ID=""
    REMOTE_GPU_ID=""
    if [ "${GDR_AVAILABLE}" = "true" ]; then
        if [ "${GPU_AFFINITY}" = "true" ]; then
            LOCAL_GPU_ID=$(get_affinity_gpus "${IB_DEV}")
            REMOTE_GPU_ID=$(get_affinity_gpus "${IB_DEV}" "remote")
        else
            LOCAL_GPU_ID="0"
            REMOTE_GPU_ID="0"
        fi
    fi

    # 获取 NUMA 节点
    LOCAL_NUMA=$(get_numa_node "${IB_DEV}")
    REMOTE_NUMA=$(get_numa_node "${IB_DEV}" "remote")

    # 构建 numactl 前缀（受 --no-numa 控制）
    LOCAL_NUMA_PREFIX=""
    REMOTE_NUMA_PREFIX=""
    if [ "${NUMA_AFFINITY}" = "true" ]; then
        if [ -n "${LOCAL_NUMA}" ]; then
            LOCAL_NUMA_PREFIX="numactl --cpunodebind=${LOCAL_NUMA} --membind=${LOCAL_NUMA}"
        fi
        if [ -n "${REMOTE_NUMA}" ]; then
            REMOTE_NUMA_PREFIX="numactl --cpunodebind=${REMOTE_NUMA} --membind=${REMOTE_NUMA}"
        fi
    fi

    # 初始化文件
    > ${RAW_LOG}

    # 构建测试命令字符串
    local numa_srv_prefix=""
    [ -n "${REMOTE_NUMA_PREFIX}" ] && numa_srv_prefix="${REMOTE_NUMA_PREFIX} "
    local numa_cli_prefix=""
    [ -n "${LOCAL_NUMA_PREFIX}" ] && numa_cli_prefix="${LOCAL_NUMA_PREFIX} "
    local server_cmd_mem="${numa_srv_prefix}${IB_TOOL} -x ${GID_INDEX} -n ${ITERATIONS} --tclass=${TCLASS} --ib-dev=${IB_DEV} -a -F"
    local client_cmd_mem="${numa_cli_prefix}${IB_TOOL} -x ${GID_INDEX} -n ${ITERATIONS} --tclass=${TCLASS} --ib-dev=${IB_DEV} -a -F ${SERVER_BOND_IP}"
    local server_cmd_gdr="${server_cmd_mem} --use_cuda=${REMOTE_GPU_ID}"
    local client_cmd_gdr="${client_cmd_mem} --use_cuda=${LOCAL_GPU_ID}"

    # 写入结果文件头部
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
        echo "# Client NUMA  : ${LOCAL_NUMA:-N/A}"
        echo "# Server NUMA  : ${REMOTE_NUMA:-N/A}"
        echo "# NUMA绑定    : ${NUMA_AFFINITY}"
        echo "# GDR可用      : ${GDR_AVAILABLE}"
        if [ "${GDR_AVAILABLE}" = "true" ]; then
            echo "# GPU亲和      : ${GPU_AFFINITY}"
            echo "# Client GPU   : ${LOCAL_GPU_ID}"
            echo "# Server GPU   : ${REMOTE_GPU_ID}"
        fi
        echo "########################################"
        echo ""
    } > ${RESULT_FILE}

    # 写入RAW日志头部
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
        echo "# Client NUMA  : ${LOCAL_NUMA:-N/A}"
        echo "# Server NUMA  : ${REMOTE_NUMA:-N/A}"
        echo "# NUMA绑定    : ${NUMA_AFFINITY}"
        echo "# GDR可用      : ${GDR_AVAILABLE}"
        if [ "${GDR_AVAILABLE}" = "true" ]; then
            echo "# GPU亲和      : ${GPU_AFFINITY}"
            echo "# Client GPU   : ${LOCAL_GPU_ID}"
            echo "# Server GPU   : ${REMOTE_GPU_ID}"
        fi
        echo "#"
        echo "# 测试命令 (Mem):"
        echo "#   [Server端] ${server_cmd_mem}"
        echo "#   [Client端] ${client_cmd_mem}"
        if [ "${GDR_AVAILABLE}" = "true" ]; then
            echo "# 测试命令 (GDR):"
            echo "#   [Server端] ${server_cmd_gdr}"
            echo "#   [Client端] ${client_cmd_gdr}"
        fi
        echo "########################################"
        echo ""
    } >> ${RAW_LOG}

    # 终端打印信息
    echo ""
    echo -e "${BLUE}========== ${IB_TOOL} ==========${NC}"
    echo "Client NUMA  : ${LOCAL_NUMA:-N/A}"
    echo "Server NUMA  : ${REMOTE_NUMA:-N/A}"
    echo "NUMA绑定     : ${NUMA_AFFINITY}"
    echo "GDR可用      : ${GDR_AVAILABLE}"
    if [ "${GDR_AVAILABLE}" = "true" ]; then
        echo "GPU亲和      : ${GPU_AFFINITY}"
        echo "Client GPU   : ${LOCAL_GPU_ID}"
        echo "Server GPU   : ${REMOTE_GPU_ID}"
    fi
    echo "结果文件     : ${RESULT_FILE}"

    # 清理残留进程
    kill_server 2>/dev/null

    local total_scenes=1
    [ "${GDR_AVAILABLE}" = "true" ] && total_scenes=2

    # === 1. 内存测试 ===
    echo ""
    echo -e "${BLUE}--- 1/${total_scenes} Mem ---${NC}"
    echo "# 1. Mem" >> ${RAW_LOG}

    local header
    header=$(print_header)
    echo "$header"
    echo "$header" >> ${RESULT_FILE}

    start_server ""

    if ! verify_server; then
        echo -e "${RED}[ERROR] Mem server启动失败${NC}" >&2
        kill_server 2>/dev/null
    else
        run_client ""
        kill_server 2>/dev/null
    fi

    # === 2. GDR测试（仅 --gdr 且 GPU 可用时执行）===
    if [ "${GDR_AVAILABLE}" = "true" ]; then
        echo ""
        echo -e "${BLUE}--- 2/${total_scenes} GDR (Client GPU ${LOCAL_GPU_ID}, Server GPU ${REMOTE_GPU_ID}) ---${NC}"
        echo "# 2. GDR" >> ${RAW_LOG}
        echo "" >> ${RESULT_FILE}
        echo "# GDR (Client GPU ${LOCAL_GPU_ID}, Server GPU ${REMOTE_GPU_ID})" >> ${RESULT_FILE}

        header=$(print_header)
        echo "$header"
        echo "$header" >> ${RESULT_FILE}

        start_server "cuda"

        if ! verify_server; then
            echo -e "${RED}[ERROR] GDR server启动失败${NC}" >&2
            kill_server 2>/dev/null
        else
            run_client "cuda"
            kill_server 2>/dev/null
        fi
    elif [ "${ENABLE_GDR}" = "true" ]; then
        echo ""
        echo -e "${RED}[SKIP] GPU不可用，跳过GDR时延测试${NC}"
        echo "# 2. GDR (跳过)" >> ${RAW_LOG}
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
