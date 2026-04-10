#!/bin/bash
#
# 快速验证测试：20并发，每个worker只调用1次
# 目的：验证 ai-proxy-advanced 多 API Key 轮转是否生效
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/kong.conf"

ENDPOINT="${KONG_URL}/llm/v1/chat/completions"
CONCURRENCY=20
TIER=15000
DATA_DIR="${DATA_DIR:-/tmp/llm_benchmark_data}"
TIER_DIR="${DATA_DIR}/tier_${TIER}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查数据
if [ ! -d "$TIER_DIR" ]; then
    echo -e "${RED}测试数据不存在: ${TIER_DIR}${NC}"
    echo "请先运行: ./generate_test_data.sh"
    exit 1
fi

FILE_COUNT=$(ls -1 "${TIER_DIR}"/*.json 2>/dev/null | wc -l | tr -d '[:space:]')
echo -e "${CYAN}目标: ${ENDPOINT}${NC}"
echo -e "${CYAN}模型: ${MODEL}${NC}"
echo -e "${CYAN}并发: ${CONCURRENCY}, 每worker 1次请求${NC}"
echo -e "${CYAN}数据: ${TIER_DIR} (${FILE_COUNT} 文件)${NC}"
echo ""
echo "────────────────────────────────────────────────────────────"
echo ""

RESULT_DIR=$(mktemp -d /tmp/quick_test_XXXXXX)

send_one() {
    local wid=$1
    local file_idx=$(( (wid - 1) % FILE_COUNT + 1 ))
    local req_file="${TIER_DIR}/request_${file_idx}.json"

    if [ ! -f "$req_file" ]; then
        echo "W${wid}|failed|0|0|no_file|" > "${RESULT_DIR}/w${wid}.txt"
        return
    fi

    local header_file=$(mktemp /tmp/qt_hdr_XXXXXX)
    local resp_file=$(mktemp /tmp/qt_resp_XXXXXX)
    local start_ms=$(date +%s%3N)

    local http_code
    http_code=$(jq --arg m "$MODEL" '.model = $m' "$req_file" | \
        curl -s -w "%{http_code}" \
        -D "$header_file" \
        -o "$resp_file" \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -d @- \
        --connect-timeout 30 \
        --max-time 300 2>/dev/null)

    local end_ms=$(date +%s%3N)
    local latency=$(echo "scale=3; ($end_ms - $start_ms) / 1000" | bc 2>/dev/null || echo "0")
    [[ "$latency" == .* ]] && latency="0${latency}"

    local api_key_index=""
    if [ -s "$header_file" ]; then
        api_key_index=$(grep -i "X-API-Key-Index:" "$header_file" | tr -d '\r' | awk '{print $2}')
    fi

    local tokens=0
    local error=""
    if [ "$http_code" = "200" ]; then
        tokens=$(cat "$resp_file" | jq -r '.usage.total_tokens // 0' 2>/dev/null)
        echo "W${wid}|success|${http_code}|${latency}|${tokens}|${api_key_index}" > "${RESULT_DIR}/w${wid}.txt"
    else
        error=$(cat "$resp_file" | jq -r '.error.message // .message // "unknown"' 2>/dev/null | head -c 100)
        echo "W${wid}|failed|${http_code}|${latency}|${error}|${api_key_index}" > "${RESULT_DIR}/w${wid}.txt"
    fi

    rm -f "$header_file" "$resp_file" 2>/dev/null
}

# 并发发送
for i in $(seq 1 $CONCURRENCY); do
    send_one $i &
done
wait

# 汇总
echo -e "${CYAN}结果汇总:${NC}"
echo ""
printf "  %-6s %-10s %-6s %-10s %-12s %-10s\n" "Worker" "状态" "HTTP" "延迟(s)" "Tokens" "KeyIndex"
printf "  %-6s %-10s %-6s %-10s %-12s %-10s\n" "------" "------" "----" "-------" "------" "--------"

success=0
failed=0
KEY_CSV="${RESULT_DIR}/keys.csv"
> "$KEY_CSV"

for i in $(seq 1 $CONCURRENCY); do
    if [ -f "${RESULT_DIR}/w${i}.txt" ]; then
        line=$(cat "${RESULT_DIR}/w${i}.txt")
        IFS='|' read -r wid status code lat info key_idx <<< "$line"

        if [ "$status" = "success" ]; then
            printf "  ${GREEN}%-6s %-10s %-6s %-10s %-12s %-10s${NC}\n" "$wid" "$status" "$code" "$lat" "$info" "$key_idx"
            success=$((success + 1))
            key_idx_clean=$(echo "$key_idx" | tr -d '[:space:]')
            [ -z "$key_idx_clean" ] && key_idx_clean="unknown"
            echo "$key_idx_clean" >> "$KEY_CSV"
        else
            printf "  ${RED}%-6s %-10s %-6s %-10s %-12s %-10s${NC}\n" "$wid" "$status" "$code" "$lat" "$info" "$key_idx"
            failed=$((failed + 1))
        fi
    fi
done

echo ""
echo "────────────────────────────────────────────────────────────"
echo ""
echo -e "  总请求: ${CONCURRENCY} | ${GREEN}成功: ${success}${NC} | ${RED}失败: ${failed}${NC}"
echo ""

# Round-Robin 分布 (兼容 bash 3.x，不用 declare -A)
echo -e "${YELLOW}Round-Robin Key 分布:${NC}"
echo ""
key_count=$(sort "$KEY_CSV" | uniq -c | sort -rn)
unique_keys=$(echo "$key_count" | wc -l | tr -d '[:space:]')
echo "$key_count" | while read cnt key; do
    [ -z "$key" ] && continue
    pct=$(echo "scale=1; $cnt * 100 / $success" | bc 2>/dev/null || echo "0")
    echo -e "  Key Index ${CYAN}${key}${NC}: ${cnt} 次 (${pct}%)"
done

echo ""
if [ "$unique_keys" -le 1 ]; then
    echo -e "  ${RED}⚠ 只有 1 个 key index，round-robin 未生效！${NC}"
else
    echo -e "  ${GREEN}✅ 检测到 ${unique_keys} 个 key index，round-robin 已生效${NC}"
fi
echo ""

rm -rf "$RESULT_DIR" 2>/dev/null
