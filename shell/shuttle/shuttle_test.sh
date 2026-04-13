#!/bin/bash
###############################################################################
# Shuttle 多维度组网测试脚本
# 测试维度: (incast, m2n, all2all) × (mem, gdr) × qp数量
# 运行命令: ./shuttle continuous -role master -cfg <config>
#
# Usage: ./shuttle_test.sh [OPTIONS]
#
# OPTIONS:
#   -h, --help              显示帮助信息
#   -s, --shuttle PATH      shuttle二进制路径 (默认: ./shuttle)
#   -c, --config-dir DIR    配置文件目录 (默认: 当前目录)
#   -r, --result-dir DIR    结果输出目录 (默认: ./shuttle_result)
#   -t, --type TYPE         测试类型: incast, m2n, all2all, all (默认: all)
#   -m, --mode MODE         测试模式: mem, gdr, all (默认: all)
#   -q, --qp-list LIST      QP列表, 逗号分隔 (默认: 1,4,8,16,32,64,128,256,512)
#   -d, --duration SEC      每个测试case的持续时间(秒) (默认: 30)
#   --dry-run               仅显示要执行的命令, 不实际运行
#
# 示例:
#   ./shuttle_test.sh                               # 执行所有测试
#   ./shuttle_test.sh -t incast -m mem              # 仅执行incast内存测试
#   ./shuttle_test.sh -t all2all -q "16,32,64"      # all2all测试, 指定QP列表
#   ./shuttle_test.sh --dry-run                     # 预览所有测试命令
#   ./shuttle_test.sh -t m2n -m gdr -q "8,16"       # m2n显存测试
#   ./shuttle_test.sh -d 30                         # 每个case测试30秒
###############################################################################

# ==================== 默认配置 ====================
SHUTTLE_BIN="./shuttle"
CONFIG_DIR="."
RESULT_DIR="./shuttle_result"

ALL_TEST_TYPES=("incast" "m2n" "all2all")
ALL_MODES=("mem" "gdr")
ALL_QP_LIST=(1 4 8 16 32 64 128 256 512)

DURATION=30
DRY_RUN="false"
SELECTED_TYPES=()
SELECTED_MODES=()
SELECTED_QP_LIST=()

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

TMP_FILES=()

# GDR 相关
GDR_AVAILABLE="false"
LOCAL_GPU_ID=""
IB_DEV_NAME=""

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 清理函数 ====================
cleanup() {
    for f in "${TMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null
    done
}

cleanup_on_exit() {
    echo ""
    echo -e "${YELLOW}[INFO] 捕获到中断信号，正在清理临时文件...${NC}"
    cleanup
    echo -e "${YELLOW}[INFO] 清理完成，退出${NC}"
    exit 130
}

trap cleanup_on_exit INT TERM
trap cleanup EXIT

# ==================== 帮助信息 ====================
show_help() {
    cat << 'EOF'
Shuttle 多维度组网测试脚本

Usage: ./shuttle_test.sh [OPTIONS]

OPTIONS:
    -h, --help              显示帮助信息
    -s, --shuttle PATH      shuttle二进制路径 (默认: ./shuttle)
    -c, --config-dir DIR    配置文件目录 (默认: 当前目录)
    -r, --result-dir DIR    结果输出目录 (默认: ./shuttle_result)
    -t, --type TYPE         测试类型: incast, m2n, all2all, all (默认: all)
    -m, --mode MODE         测试模式: mem, gdr, all (默认: all)
    -q, --qp-list LIST      QP列表, 逗号分隔, 如 "1,4,8,16" (默认: 1,4,8,16,32,64,128,256,512)
    -d, --duration SEC      每个测试case的持续时间, 秒 (默认: 30)
    --dry-run               仅显示要执行的命令, 不实际运行

示例:
    ./shuttle_test.sh                               # 执行所有测试 (默认)
    ./shuttle_test.sh -t incast -m mem              # 仅执行incast内存测试
    ./shuttle_test.sh -t all2all -q "16,32,64"      # all2all测试, 指定QP列表
    ./shuttle_test.sh --dry-run                     # 预览所有测试命令
    ./shuttle_test.sh -t m2n -m gdr -q "8,16"       # m2n显存测试, QP为8和16
    ./shuttle_test.sh -d 30                         # 每个case测试30秒

EOF
}

# ==================== 获取与IB设备亲和的所有GPU设备号 ====================
# 通过 nvidia-smi/ppu-smi topo -m 解析 PIX 关系
# 参数: ib_dev
# 返回: 空格分隔的 GPU index 列表（至少返回 "0"）
get_affinity_gpus() {
    local ib_dev=$1

    local topo_file
    topo_file=$(mktemp)

    if command -v ppu-smi &>/dev/null; then
        ppu-smi topo -m > "${topo_file}" 2>/dev/null
    elif command -v nvidia-smi &>/dev/null; then
        nvidia-smi topo -m > "${topo_file}" 2>/dev/null
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

    local gpu_list=""
    local col_idx=0
    for col_name in $header_line; do
        if echo "$col_name" | grep -qiE "^(GPU|PPU)[0-9]+$"; then
            local awk_field=$((col_idx + 2))
            local val
            val=$(echo "$nic_row" | awk -v c=${awk_field} '{print $c}')
            if [ "$val" = "PIX" ]; then
                local gpu_num
                gpu_num=$(echo "$col_name" | sed 's/[^0-9]//g')
                gpu_list="${gpu_list:+${gpu_list} }${gpu_num}"
            fi
        fi
        col_idx=$((col_idx + 1))
    done

    if [ -z "$gpu_list" ]; then
        echo "0"
    else
        echo "$gpu_list"
    fi
}

# ==================== 从配置文件解析 IB 设备名 ====================
parse_ib_dev() {
    local config_file=$1
    local hosts_line
    hosts_line=$(grep '^hosts=' "$config_file" | head -1 | cut -d= -f2-)
    echo "$hosts_line" | tr ',' '\n' | head -1 | awk -F: '{print $2}'
}

# ==================== 检查 GDR 环境 ====================
check_gdr() {
    local ib_dev=$1

    if ! command -v ppu-smi &>/dev/null && ! command -v nvidia-smi &>/dev/null; then
        echo -e "${RED}[WARN] 本机未找到 nvidia-smi/ppu-smi，将跳过 GDR 测试${NC}" >&2
        echo "false"
        return
    fi

    local gpu_count=0
    if command -v ppu-smi &>/dev/null; then
        gpu_count=$(ppu-smi -q 2>/dev/null | grep -c "PPU UUID" || echo 0)
    elif command -v nvidia-smi &>/dev/null; then
        gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    fi

    if [ "${gpu_count}" -eq 0 ]; then
        echo -e "${RED}[WARN] 本机未检测到 GPU/PPU，将跳过 GDR 测试${NC}" >&2
        echo "false"
        return
    fi

    echo "true"
}

# ==================== 打印纵向汇总表 ====================
# 参数: mode_labels数组名 summary_data数组名
# 格式:
#   QP=1
#     Mem: 220.11/218.26/221.47/225.27
#     GDR: 230.00/225.10/228.30/226.50
#   QP=4
#     ...
print_summary_table() {
    local -n _mode_labels=$1
    local -n _summary_data=$2

    for ml in "${_mode_labels[@]}"; do
        printf "[%s]\n" "${ml}"
        for qi in "${!SELECTED_QP_LIST[@]}"; do
            local qp=${SELECTED_QP_LIST[$qi]}
            local val="${_summary_data["${ml}_${qi}"]:-N/A}"
            printf "  QP=%-6s %s\n" "${qp}" "${val}"
        done
        echo ""
    done
}

# ==================== 生成临时配置文件 ====================
generate_config() {
    local test_type=$1
    local mode=$2
    local qp=$3

    local base_config="${CONFIG_DIR}/config.ini.${test_type}"
    local tmp_config="${CONFIG_DIR}/.config.ini.${test_type}.${mode}.qp${qp}.tmp"

    if [[ ! -f "$base_config" ]]; then
        echo -e "${RED}[ERROR] 基准配置文件不存在: $base_config${NC}" >&2
        return 1
    fi

    if ! cp "$base_config" "$tmp_config"; then
        echo -e "${RED}[ERROR] 复制配置文件失败: $base_config -> $tmp_config${NC}" >&2
        return 1
    fi

    # 修改 qp 值
    if ! grep -q '^qp=' "$tmp_config"; then
        echo -e "${RED}[ERROR] 配置文件中缺少 qp= 字段: $base_config${NC}" >&2
        rm -f "$tmp_config"
        return 1
    fi
    sed -i "s/^qp=.*/qp=${qp}/" "$tmp_config"

    # 修改 duration 值
    if grep -q '^duration=' "$tmp_config"; then
        sed -i "s/^duration=.*/duration=${DURATION}/" "$tmp_config"
    fi

    # gdr 字段保持 false（shuttle 的 gdr=true 不生效，GDR 通过 cmds 中 --use_cuda 控制）
    if grep -q '^gdr=' "$tmp_config"; then
        sed -i "s/^gdr=.*/gdr=false/" "$tmp_config"
    fi

    # gdr 模式: cmds 追加 --use_cuda=<gpu_id>
    if [[ "$mode" == "gdr" ]]; then
        local base_cmds
        base_cmds=$(grep '^cmds=' "$tmp_config" | head -1 | cut -d= -f2-)
        local new_cmds="${base_cmds} --use_cuda=${LOCAL_GPU_ID}"
        sed -i "s|^cmds=.*|cmds=${new_cmds}|" "$tmp_config"
    fi

    # 验证修改结果
    local actual_qp
    actual_qp=$(grep '^qp=' "$tmp_config" | head -1 | cut -d= -f2)
    if [[ "$actual_qp" != "$qp" ]]; then
        echo -e "${RED}[ERROR] qp 修改验证失败: 期望 $qp, 实际 $actual_qp${NC}" >&2
        rm -f "$tmp_config"
        return 1
    fi

    TMP_FILES+=("$tmp_config")

    echo "$tmp_config"
}

# ==================== 执行单次 shuttle 测试 ====================
# 返回 sum(rx) 带宽值，写入 RAW_LOG
run_shuttle() {
    local config_file=$1
    local test_label=$2
    local result_file=$3
    local raw_log=$4

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}[ERROR] 配置文件不存在: $config_file${NC}" >&2
        echo "ERR"
        return 1
    fi

    if [[ ! -x "$SHUTTLE_BIN" ]]; then
        echo -e "${RED}[ERROR] shuttle 工具不存在或无执行权限: $SHUTTLE_BIN${NC}" >&2
        echo "ERR"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] $SHUTTLE_BIN continuous -role master -cfg $config_file" >&2
        echo "DRY"
        return 0
    fi

    rm -rf /tmp/shuttle/report

    local start_time
    start_time=$(date +%s)

    {
        echo "=== ${test_label} ==="
        echo "配置文件: ${config_file}"
        echo "开始时间: $(date)"
        echo "---"
    } >> "${raw_log}"

    local shuttle_output
    shuttle_output=$("$SHUTTLE_BIN" continuous -role master -cfg "$config_file" 2>&1)
    local exit_code=$?

    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    {
        echo "--- shuttle stdout ---"
        echo "$shuttle_output"
        echo "--- 退出码: ${exit_code}, 耗时: ${elapsed}s ---"
        echo ""
    } >> "${raw_log}"

    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}[ERROR] shuttle 执行失败 (退出码: $exit_code, 耗时: ${elapsed}s)${NC}" >&2
        echo "ERR"
        return 1
    fi

    # 提取 report.csv
    if [[ ! -f "/tmp/shuttle/report/report.csv" ]]; then
        echo -e "${RED}[WARN] 未找到 report.csv${NC}" >&2
        echo "N/A"
        return 1
    fi

    local csv_content
    csv_content=$(cat /tmp/shuttle/report/report.csv)

    # 保存完整 CSV 到结果文件
    {
        echo "--- ${test_label} ---"
        echo "$csv_content"
        echo ""
    } >> "${result_file}"

    # 也记录到 RAW LOG
    {
        echo "--- report.csv ---"
        echo "$csv_content"
        echo ""
    } >> "${raw_log}"

    # 打印 report.csv 到控制台
    echo "$csv_content" >&2

    # 提取 sum(rx)，多个 server 时用 / 分隔
    local sum_rx_line
    sum_rx_line=$(echo "$csv_content" | grep '^sum(rx)')

    if [[ -z "$sum_rx_line" ]]; then
        echo "N/A"
    else
        echo "$sum_rx_line" | awk -F',' '{
            result=""
            for (i=2; i<=NF; i++) {
                if ($i != "" && $i != " ") {
                    if (result != "") result = result "/"
                    result = result $i
                }
            }
            print result
        }'
    fi
}

# ==================== 执行单个 test_type 的全部测试 ====================
run_type_tests() {
    local test_type=$1

    local base_config="${CONFIG_DIR}/config.ini.${test_type}"
    local result_file="${RESULT_DIR}/perf_shuttle_${test_type}_result_${TIMESTAMP}.txt"
    local raw_log="${RESULT_DIR}/perf_shuttle_${test_type}_raw_${TIMESTAMP}.log"

    > "${raw_log}"

    # 写入结果文件头部
    {
        echo "########################################"
        echo "# Shuttle ${test_type} 组网测试结果"
        echo "########################################"
        echo "# 时间         : $(date)"
        echo "# 配置文件     : ${base_config}"
        echo "# IB设备       : ${IB_DEV_NAME}"
        echo "# 测试时长     : ${DURATION}s/case"
        echo "# QP列表       : ${SELECTED_QP_LIST[*]}"
        echo "# 测试模式     : ${SELECTED_MODES[*]}"
        echo "# GDR可用      : ${GDR_AVAILABLE}"
        if [[ "${GDR_AVAILABLE}" == "true" ]]; then
            echo "# GPU ID       : ${LOCAL_GPU_ID}"
        fi
        echo "########################################"
        echo ""
    } > "${result_file}"

    # 写入 RAW LOG 头部
    {
        echo "########################################"
        echo "# Shuttle ${test_type} 组网测试 RAW LOG"
        echo "########################################"
        echo "# 时间         : $(date)"
        echo "# 配置文件     : ${base_config}"
        echo "# IB设备       : ${IB_DEV_NAME}"
        echo "# 测试时长     : ${DURATION}s/case"
        echo "# QP列表       : ${SELECTED_QP_LIST[*]}"
        echo "# 测试模式     : ${SELECTED_MODES[*]}"
        echo "# GDR可用      : ${GDR_AVAILABLE}"
        if [[ "${GDR_AVAILABLE}" == "true" ]]; then
            echo "# GPU ID       : ${LOCAL_GPU_ID}"
        fi
        echo "########################################"
        echo ""
    } >> "${raw_log}"

    # 终端打印信息
    echo ""
    echo -e "${BLUE}========== shuttle ${test_type} 测试 ==========${NC}"
    echo "配置文件     : ${base_config}"
    echo "IB设备       : ${IB_DEV_NAME}"
    echo "测试时长     : ${DURATION}s/case"
    echo "QP列表       : ${SELECTED_QP_LIST[*]}"
    echo "GDR可用      : ${GDR_AVAILABLE}"
    if [[ "${GDR_AVAILABLE}" == "true" ]]; then
        echo "GPU ID       : ${LOCAL_GPU_ID}"
    fi
    echo "结果文件     : ${result_file}"
    echo ""

    # 计算总测试数
    local total_tests=$(( ${#SELECTED_MODES[@]} * ${#SELECTED_QP_LIST[@]} ))
    local count=0

    # 存储汇总数据
    declare -A summary_data
    local mode_labels=()

    for mode in "${SELECTED_MODES[@]}"; do
        # 跳过 gdr 模式（如果不可用）
        if [[ "$mode" == "gdr" && "${GDR_AVAILABLE}" != "true" ]]; then
            echo -e "${RED}[SKIP] GPU 不可用，跳过 GDR 测试${NC}"
            local skip_values=()
            for qp in "${SELECTED_QP_LIST[@]}"; do
                skip_values+=("-")
                count=$((count + 1))
            done

            local mode_label="GDR"
            mode_labels+=("$mode_label")
            local key_prefix="${mode_label}"
            local qi=0
            for qp in "${SELECTED_QP_LIST[@]}"; do
                summary_data["${key_prefix}_${qi}"]="${skip_values[$qi]}"
                qi=$((qi + 1))
            done
            continue
        fi

        local mode_label
        if [[ "$mode" == "mem" ]]; then
            mode_label="Mem"
        else
            mode_label="GDR"
        fi
        mode_labels+=("$mode_label")

        local bw_values=()

        for qp in "${SELECTED_QP_LIST[@]}"; do
            count=$((count + 1))
            local test_label="${test_type} ${mode} qp${qp}"

            echo ""
            echo -e "${BLUE}--- ${count}/${total_tests} ${mode_label} QP=${qp} ---${NC}"

            # 生成临时配置
            local config_file
            config_file=$(generate_config "$test_type" "$mode" "$qp")
            if [[ $? -ne 0 || -z "$config_file" ]]; then
                echo -e "${RED}  配置文件生成失败，跳过${NC}"
                bw_values+=("ERR")
                continue
            fi

            echo -ne "${YELLOW}  测试中...${NC}\r"

            # 执行测试
            local bw
            bw=$(run_shuttle "$config_file" "$test_label" "$result_file" "$raw_log")

            # 清理临时配置
            rm -f "$config_file"

            bw_values+=("$bw")
            printf "\r\033[2K"

            # 测试间等待
            if [[ "$DRY_RUN" != "true" ]]; then
                sleep 5
            fi
        done

        # 存储到汇总数据
        local qi=0
        for qp in "${SELECTED_QP_LIST[@]}"; do
            summary_data["${mode_label}_${qi}"]="${bw_values[$qi]}"
            qi=$((qi + 1))
        done
    done

    # 打印汇总表
    echo ""
    echo -e "${BLUE}========== shuttle ${test_type} 测试结果汇总 ==========${NC}"

    local summary_output
    summary_output=$(print_summary_table mode_labels summary_data)
    echo "$summary_output"

    {
        echo ""
        echo "# 汇总表 (sum(rx) Gbps, 多server用/分隔)"
        echo "$summary_output"
    } >> "${result_file}"

    echo ""
    echo -e "${GREEN}shuttle ${test_type} 测试完成，结果文件: ${result_file}${NC}"
}

# ==================== 参数校验 ====================
validate_type() {
    local t=$1
    [[ "$t" == "incast" || "$t" == "m2n" || "$t" == "all2all" || "$t" == "all" ]]
}

validate_mode() {
    local m=$1
    [[ "$m" == "mem" || "$m" == "gdr" || "$m" == "all" ]]
}

# ==================== 主函数 ====================
main() {
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--shuttle)
                [[ $# -ge 2 ]] || { echo -e "${RED}[ERROR] -s/--shuttle 需要指定路径${NC}" >&2; exit 1; }
                SHUTTLE_BIN="$2"
                shift 2
                ;;
            -c|--config-dir)
                [[ $# -ge 2 ]] || { echo -e "${RED}[ERROR] -c/--config-dir 需要指定目录${NC}" >&2; exit 1; }
                CONFIG_DIR="$2"
                shift 2
                ;;
            -r|--result-dir)
                [[ $# -ge 2 ]] || { echo -e "${RED}[ERROR] -r/--result-dir 需要指定目录${NC}" >&2; exit 1; }
                RESULT_DIR="$2"
                shift 2
                ;;
            -t|--type)
                [[ $# -ge 2 ]] || { echo -e "${RED}[ERROR] -t/--type 需要指定类型${NC}" >&2; exit 1; }
                IFS=',' read -ra SELECTED_TYPES <<< "$2"
                for t in "${SELECTED_TYPES[@]}"; do
                    if ! validate_type "$t"; then
                        echo -e "${RED}[ERROR] 无效的测试类型: $t (可选: incast, m2n, all2all, all)${NC}" >&2
                        exit 1
                    fi
                done
                shift 2
                ;;
            -m|--mode)
                [[ $# -ge 2 ]] || { echo -e "${RED}[ERROR] -m/--mode 需要指定模式${NC}" >&2; exit 1; }
                IFS=',' read -ra SELECTED_MODES <<< "$2"
                for m in "${SELECTED_MODES[@]}"; do
                    if ! validate_mode "$m"; then
                        echo -e "${RED}[ERROR] 无效的测试模式: $m (可选: mem, gdr, all)${NC}" >&2
                        exit 1
                    fi
                done
                shift 2
                ;;
            -q|--qp-list)
                [[ $# -ge 2 ]] || { echo -e "${RED}[ERROR] -q/--qp-list 需要指定QP列表${NC}" >&2; exit 1; }
                IFS=',' read -ra SELECTED_QP_LIST <<< "$2"
                shift 2
                ;;
            -d|--duration)
                [[ $# -ge 2 ]] || { echo -e "${RED}[ERROR] -d/--duration 需要指定秒数${NC}" >&2; exit 1; }
                DURATION="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            *)
                echo -e "${RED}[ERROR] 未知参数: $1${NC}" >&2
                show_help
                exit 1
                ;;
        esac
    done

    # 默认值展开
    if [[ ${#SELECTED_TYPES[@]} -eq 0 ]]; then
        SELECTED_TYPES=("${ALL_TEST_TYPES[@]}")
    else
        local expanded=()
        for t in "${SELECTED_TYPES[@]}"; do
            if [[ "$t" == "all" ]]; then
                expanded=("${ALL_TEST_TYPES[@]}")
                break
            else
                expanded+=("$t")
            fi
        done
        SELECTED_TYPES=("${expanded[@]}")
    fi

    if [[ ${#SELECTED_MODES[@]} -eq 0 ]]; then
        SELECTED_MODES=("${ALL_MODES[@]}")
    else
        local expanded=()
        for m in "${SELECTED_MODES[@]}"; do
            if [[ "$m" == "all" ]]; then
                expanded=("${ALL_MODES[@]}")
                break
            else
                expanded+=("$m")
            fi
        done
        SELECTED_MODES=("${expanded[@]}")
    fi

    if [[ ${#SELECTED_QP_LIST[@]} -eq 0 ]]; then
        SELECTED_QP_LIST=("${ALL_QP_LIST[@]}")
    fi

    # 检查基准配置文件，同时解析 IB 设备名
    local missing=0
    for type in "${SELECTED_TYPES[@]}"; do
        if [[ ! -f "${CONFIG_DIR}/config.ini.${type}" ]]; then
            echo -e "${RED}[ERROR] 缺少基准配置文件: ${CONFIG_DIR}/config.ini.${type}${NC}" >&2
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        exit 1
    fi

    # 从第一个配置文件解析 IB 设备名
    IB_DEV_NAME=$(parse_ib_dev "${CONFIG_DIR}/config.ini.${SELECTED_TYPES[0]}")
    if [[ -z "$IB_DEV_NAME" ]]; then
        echo -e "${RED}[ERROR] 无法从配置文件解析 IB 设备名${NC}" >&2
        exit 1
    fi

    # 创建结果目录
    mkdir -p "$RESULT_DIR"

    # 检查 GDR 环境（仅当选择了 gdr 模式时）
    local need_gdr=false
    for m in "${SELECTED_MODES[@]}"; do
        [[ "$m" == "gdr" ]] && need_gdr=true
    done

    if [[ "$need_gdr" == "true" ]]; then
        GDR_AVAILABLE=$(check_gdr "$IB_DEV_NAME")
        if [[ "$GDR_AVAILABLE" == "true" ]]; then
            local gpu_str
            gpu_str=$(get_affinity_gpus "$IB_DEV_NAME")
            LOCAL_GPU_ID=$(echo "$gpu_str" | awk '{print $1}')
        fi
    fi

    # 计算测试总数
    local total_types=${#SELECTED_TYPES[@]}
    local total_per_type=$(( ${#SELECTED_MODES[@]} * ${#SELECTED_QP_LIST[@]} ))
    local total=$(( total_types * total_per_type ))

    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BLUE} Shuttle 多维度组网测试${NC}"
    echo -e "${BLUE}======================================================${NC}"
    echo "测试类型     : ${SELECTED_TYPES[*]}"
    echo "测试模式     : ${SELECTED_MODES[*]}"
    echo "QP列表       : ${SELECTED_QP_LIST[*]}"
    echo "IB设备       : ${IB_DEV_NAME}"
    echo "测试时长     : ${DURATION}s/case"
    echo "GDR可用      : ${GDR_AVAILABLE}"
    if [[ "${GDR_AVAILABLE}" == "true" ]]; then
        echo "GPU ID       : ${LOCAL_GPU_ID}"
    fi
    echo "总测试数     : ${total}"
    echo "结果目录     : ${RESULT_DIR}"
    echo -e "${BLUE}======================================================${NC}"

    # 逐个 type 执行测试
    for type in "${SELECTED_TYPES[@]}"; do
        run_type_tests "$type"
    done

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} 全部测试完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "结果目录: ${RESULT_DIR}"
    for type in "${SELECTED_TYPES[@]}"; do
        echo "  ${type}: perf_shuttle_${type}_result_${TIMESTAMP}.txt"
    done
}

main "$@"
