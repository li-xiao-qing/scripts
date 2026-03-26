#!/bin/bash
# switch_discovery.sh

echo "=== 交换机型号探测脚本 ==="

# 1. 尝试 LLDP
echo ""
echo "[1] LLDP 探测..."

# 检查并安装 lldpd
if ! command -v lldpcli &> /dev/null; then
    echo "lldpd 未安装，正在安装..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y lldpd
    elif command -v yum &> /dev/null; then
        sudo yum install -y lldpd
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y lldpd
    else
        echo "错误: 无法找到包管理器，请手动安装 lldpd"
        exit 1
    fi
    echo "lldpd 安装完成"
fi

# 启动 lldpd 服务
sudo systemctl start lldpd 2>/dev/null || sudo service lldpd start 2>/dev/null
sleep 2

# 获取 LLDP 邻居信息
if command -v lldpcli &> /dev/null; then
    sudo lldpcli show neighbors details 2>/dev/null | grep -E "(SysName|SysDescr|ChassisID)" || echo "LLDP 未获取到信息"
else
    echo "LLDP 工具安装失败"
fi

# 2. 网关信息
echo ""
echo "[2] 网关信息..."
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
echo "默认网关: $GATEWAY"
if [ -n "$GATEWAY" ]; then
    echo "网关 MAC: $(ip neigh show | grep "$GATEWAY" | awk '{print $5}')"
    arp -a | grep "$GATEWAY" || true
fi

# 3. 路由跟踪
echo ""
echo "[3] 路由跟踪..."
traceroute -m 2 -n 8.8.8.8 2>/dev/null | head -5 || echo "traceroute 失败"

# 4. 本地网络配置
echo ""
echo "[4] 网络接口信息..."
ip addr show | grep -E "(^[0-9]|inet )"