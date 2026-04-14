#!/bin/bash

# ============ 配置区 ============
REMOTE_HOST="10.36.33.170"
REMOTE_USER="root"
LOCAL_PKG="./perftest_ppu.tar.gz"
REMOTE_DIR="/opt/perftest_ppu"
REMOTE_PKG="${REMOTE_DIR}/perftest_ppu.tar.gz"
SYMLINK_DIR="/usr/local/bin"
SUFFIX="_ppu"
# =================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ============ 判断是否是本机 ============
LOCAL_IPS=$(hostname -I 2>/dev/null)
LOCAL_HOSTNAME=$(hostname 2>/dev/null)

IS_LOCAL=false
if [ "$REMOTE_HOST" = "localhost" ] || \
   [ "$REMOTE_HOST" = "127.0.0.1" ] || \
   [ "$REMOTE_HOST" = "$LOCAL_HOSTNAME" ] || \
   echo "$LOCAL_IPS" | grep -qw "$REMOTE_HOST"; then
    IS_LOCAL=true
fi

if $IS_LOCAL; then
    log_info "目标主机是本机，使用本地部署模式"
    DEPLOY_MODE="local"
else
    log_info "目标主机是远程机器 ${REMOTE_USER}@${REMOTE_HOST}，使用远程部署模式"
    DEPLOY_MODE="remote"
fi

# ============ 封装执行命令 ============
# 关键修复：ssh 加 -n 参数，防止消耗 while 循环的 stdin
run_cmd() {
    if [ "$DEPLOY_MODE" = "local" ]; then
        bash -c "$1"
    else
        ssh -n ${REMOTE_USER}@${REMOTE_HOST} "$1"
    fi
}

# 封装文件拷贝
copy_pkg() {
    local src=$1
    local dst=$2
    if [ "$DEPLOY_MODE" = "local" ]; then
        cp "$src" "$dst"
    else
        scp "$src" "${REMOTE_USER}@${REMOTE_HOST}:${dst}"
    fi
}

# ============ 检查本地压缩包 ============
log_step "========== 1. 检查本地压缩包 =========="
if [ ! -f "$LOCAL_PKG" ]; then
    log_error "本地压缩包不存在: $LOCAL_PKG"
    exit 1
fi
log_info "本地压缩包: $LOCAL_PKG ✓"

# ============ 检查目标机器上是否已有压缩包 ============
log_step "========== 2. 检查目标机器压缩包 =========="

run_cmd "test -f ${REMOTE_PKG}"
REMOTE_EXISTS=$?

if [ $REMOTE_EXISTS -eq 0 ]; then
    log_warn "目标机器已存在压缩包: ${REMOTE_PKG}，跳过拷贝"
else
    log_info "目标机器不存在压缩包，开始拷贝..."
    run_cmd "mkdir -p ${REMOTE_DIR}"
    copy_pkg "${LOCAL_PKG}" "${REMOTE_PKG}"
    if [ $? -ne 0 ]; then
        log_error "拷贝失败！"
        exit 1
    fi
    log_info "拷贝成功 ✓"
fi

# ============ 解压 ============
log_step "========== 3. 解压压缩包 =========="
log_info "解压压缩包到 ${REMOTE_DIR} ..."

run_cmd "cd ${REMOTE_DIR} && tar -xzf perftest_ppu.tar.gz"
if [ $? -ne 0 ]; then
    log_error "解压失败！"
    exit 1
fi
log_info "解压成功 ✓"

# ============ 查找所有 ib_xxx 可执行文件 ============
log_step "========== 4. 查找所有 ib_xxx 工具 =========="

IB_TOOLS=$(run_cmd "find ${REMOTE_DIR} -name 'ib_*' -type f -perm /111 2>/dev/null")

if [ -z "$IB_TOOLS" ]; then
    log_error "未找到任何 ib_xxx 可执行文件！"
    exit 1
fi

log_info "找到以下 ib_xxx 工具："
echo "$IB_TOOLS" | while read tool; do
    echo "    -> $tool"
done

# ============ 批量创建软链接 ============
log_step "========== 5. 批量创建软链接 =========="

SUCCESS_COUNT=0
FAIL_COUNT=0
SYMLINK_LIST=""

# 关键修复：用 for 循环替代 while read，避免 stdin 被 ssh 消耗
for tool_path in $IB_TOOLS; do
    [ -z "$tool_path" ] && continue

    tool_name=$(basename "$tool_path")
    symlink_name="${tool_name}${SUFFIX}"
    symlink_path="${SYMLINK_DIR}/${symlink_name}"

    run_cmd "[ -L ${symlink_path} ] && rm -f ${symlink_path}; ln -s ${tool_path} ${symlink_path}"

    if [ $? -eq 0 ]; then
        log_info "✓ ${symlink_name} -> ${tool_path}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        SYMLINK_LIST="${SYMLINK_LIST}\n    ${symlink_name} -> ${tool_path}"
    else
        log_error "✗ 创建软链接失败: ${symlink_name}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# ============ 验证所有软链接 ============
log_step "========== 6. 验证软链接 =========="

run_cmd "
    echo '--- 已创建的软链接列表 ---'
    ls -la ${SYMLINK_DIR}/ib_*${SUFFIX} 2>/dev/null
    echo ''
    echo '--- 验证可执行性 ---'
    for link in ${SYMLINK_DIR}/ib_*${SUFFIX}; do
        if [ -x \"\$link\" ]; then
            echo \"✓ \$(basename \$link) 可执行\"
        else
            echo \"✗ \$(basename \$link) 不可执行\"
        fi
    done
"

# ============ 汇总 ============
log_step "========== 部署完成 =========="
echo -e "${GREEN}"
echo "  部署模式  : $([ "$DEPLOY_MODE" = "local" ] && echo '本机部署' || echo "远程部署 ${REMOTE_USER}@${REMOTE_HOST}")"
echo "  安装目录  : ${REMOTE_DIR}"
echo "  软链接目录: ${SYMLINK_DIR}"
echo "  成功数量  : ${SUCCESS_COUNT}"
echo "  失败数量  : ${FAIL_COUNT}"
echo ""
echo "  已创建软链接："
echo -e "$SYMLINK_LIST"
echo -e "${NC}"
log_info "现在可以直接使用 ib_xxx${SUFFIX} 命令"
log_info "例如: ib_write_bw${SUFFIX} / ib_read_bw${SUFFIX} / ib_send_bw${SUFFIX} ..."
