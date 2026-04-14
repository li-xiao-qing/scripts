#!/bin/bash

IPLIST="./iplist"
LOCAL_BIN="./shuttle"
REMOTE_BIN="/usr/local/bin/shuttle"
SUCCESS=0
FAILED=0
FAILED_IPS=""

# 检查文件是否存在
if [ ! -f "$IPLIST" ]; then
    echo "Error: IP列表文件 $IPLIST 不存在"
    exit 1
fi

if [ ! -f "$LOCAL_BIN" ]; then
    echo "Error: shuttle二进制文件 $LOCAL_BIN 不存在"
    exit 1
fi

TOTAL=$(wc -l < "$IPLIST")
echo "========================================"
echo "   shuttle 批量分发"
echo "========================================"
echo "目标文件  : $LOCAL_BIN"
echo "目标路径  : $REMOTE_BIN"
echo "主机总数  : $TOTAL"
echo "========================================"

IDX=0
for ip in $(cat "$IPLIST"); do
    IDX=$((IDX + 1))
    echo -n "[$IDX/$TOTAL] $ip ... "

    # scp 分发
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$LOCAL_BIN" "$ip:$REMOTE_BIN" &>/dev/null
    if [ $? -ne 0 ]; then
        echo "FAILED (scp失败)"
        FAILED=$((FAILED + 1))
        FAILED_IPS="$FAILED_IPS $ip"
        continue
    fi

    # chmod 加执行权限
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$ip" "chmod +x $REMOTE_BIN" &>/dev/null
    if [ $? -ne 0 ]; then
        echo "FAILED (chmod失败)"
        FAILED=$((FAILED + 1))
        FAILED_IPS="$FAILED_IPS $ip"
        continue
    fi

    echo "OK"
    SUCCESS=$((SUCCESS + 1))
done

echo "========================================"
echo "分发完成！"
echo "总数    : $TOTAL"
echo "成功    : $SUCCESS"
echo "失败    : $FAILED"
if [ -n "$FAILED_IPS" ]; then
    echo "失败IP  :"
    for ip in $FAILED_IPS; do
        echo "  - $ip"
    done
fi
echo "========================================"
