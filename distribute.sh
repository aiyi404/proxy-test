#!/bin/bash
#######################################
# 分发项目到多台机器
# 用法: ./distribute.sh
#######################################

REMOTE_HOSTS=(
    "8.137.58.1"
    "47.108.49.239"
    "8.137.174.163"
    "8.137.175.12"
)
REMOTE_USER="root"
REMOTE_PASS="Rds123456"
REMOTE_DIR="/root/proxy_test"
LOCAL_DIR="/root/proxy_test"

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查 sshpass
if ! command -v sshpass &>/dev/null; then
    echo -e "${YELLOW}安装 sshpass...${NC}"
    apt-get install -y sshpass 2>/dev/null || yum install -y sshpass 2>/dev/null
fi

# 打包项目（排除临时文件和结果）
TARBALL="/tmp/proxy_test_dist.tar.gz"
echo -e "${YELLOW}打包项目...${NC}"
tar -czf "$TARBALL" \
    -C "$(dirname $LOCAL_DIR)" \
    --exclude="proxy_test/benchmark_results" \
    --exclude="proxy_test/node-v*" \
    --exclude="proxy_test/*.md" \
    "$(basename $LOCAL_DIR)"
echo -e "${GREEN}打包完成: $(du -sh $TARBALL | cut -f1)${NC}"

# 并行分发到各机器
distribute_to_host() {
    local host=$1
    echo -e "${YELLOW}[$host] 开始分发...${NC}"

    # 创建远程目录
    sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
        "$REMOTE_USER@$host" "mkdir -p $REMOTE_DIR" 2>/dev/null

    # 上传并解压
    sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no \
        "$TARBALL" "$REMOTE_USER@$host:/tmp/" 2>/dev/null

    sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
        "$REMOTE_USER@$host" \
        "tar -xzf /tmp/proxy_test_dist.tar.gz -C /root/ && chmod +x /root/proxy_test/*.sh && rm /tmp/proxy_test_dist.tar.gz" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[$host] ✓ 分发成功${NC}"
    else
        echo -e "${RED}[$host] ✗ 分发失败${NC}"
    fi
}

# 并行执行
for host in "${REMOTE_HOSTS[@]}"; do
    distribute_to_host "$host" &
done
wait

echo ""
echo -e "${GREEN}分发完成！${NC}"
rm -f "$TARBALL"
