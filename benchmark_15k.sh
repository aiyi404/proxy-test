#!/bin/bash

#######################################
# 15K Token 专项压测脚本 (使用预生成数据)
# 仅测试 15K tokens 输入规模
# 每个 worker 使用不同的请求数据，避免 KV Cache
# 每次调用实时打印请求和响应结果
#######################################

set -o pipefail

# 加载统一配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/kong.conf"

ENDPOINT="${KONG_URL}/llm/v1/chat/completions"

# 参数
CONCURRENCY="${CONCURRENCY:-1}"
MAX_TOKENS="${MAX_TOKENS:-1000}"

# 并发爬升配置
RAMP_ENABLED="${RAMP_ENABLED:-false}"        # 是否启用并发爬升
RAMP_START="${RAMP_START:-200}"              # 起始并发数
RAMP_END="${RAMP_END:-1200}"                 # 目标并发数
RAMP_DURATION="${RAMP_DURATION:-1800}"       # 总测试时长 (秒, 默认 30 分钟 = 1800 秒)
RAMP_STEP="${RAMP_STEP:-100}"                # 每次增加的并发数
RAMP_INTERVAL="${RAMP_INTERVAL:-60}"         # 每次增加间隔 (秒)

# 固定 15K 档位
TIER=15000
TIER_NAME="15K"

# 预生成的测试数据目录
DATA_DIR="${DATA_DIR:-/tmp/llm_benchmark_data}"

# 结果目录
RESULT_BASE_DIR="${RESULT_DIR:-/tmp/llm_benchmark_results_15k}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORK_DIR="${RESULT_BASE_DIR}/${TIMESTAMP}"
LOG_FILE="${WORK_DIR}/benchmark.log"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 输出锁文件 (用于多进程打印不混乱)
PRINT_LOCK=""

# 日志函数
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

# 带锁打印 (防止多 worker 输出交错, macOS 兼容)
safe_print() {
    # 使用 mkdir 原子操作作为锁 (macOS 无 flock)
    while ! mkdir "${PRINT_LOCK}.d" 2>/dev/null; do
        sleep 0.01
    done
    echo -e "$@"
    echo "$@" >> "$LOG_FILE" 2>/dev/null
    rmdir "${PRINT_LOCK}.d" 2>/dev/null
}

cleanup() {
    rm -f "$PRINT_LOCK" 2>/dev/null
    log "结果文件保存在: ${WORK_DIR}"
}
trap cleanup EXIT

# =============================================
# 检查测试数据是否存在
# =============================================
check_test_data() {
    echo -e "${YELLOW}检查测试数据...${NC}"

    if [ ! -d "$DATA_DIR" ]; then
        echo -e "${RED}测试数据目录不存在: ${DATA_DIR}${NC}"
        echo -e "${YELLOW}请先运行数据生成脚本:${NC}"
        echo -e "  ${GREEN}./generate_test_data.sh${NC}"
        return 1
    fi

    local tier_dir="${DATA_DIR}/tier_${TIER}"
    if [ ! -d "$tier_dir" ]; then
        echo -e "  ${RED}缺少 tier_${TIER} 数据${NC}"
        return 1
    fi

    local count=$(ls -1 "${tier_dir}"/*.json 2>/dev/null | wc -l | tr -d '[:space:]')
    count=${count:-0}

    if [ "$count" -lt "$CONCURRENCY" ]; then
        echo -e "  ${YELLOW}tier_${TIER}: ${count} 文件 (少于并发数 ${CONCURRENCY})${NC}"
    else
        echo -e "  ${GREEN}tier_${TIER}: ${count} 文件 ✓${NC}"
    fi

    echo -e "${GREEN}✓ 测试数据检查通过${NC}"
    return 0
}

# =============================================
# 获取请求文件
# =============================================
# 全局文件计数 (在 main 中启动 worker 前赋值)
TIER_FILE_COUNT=0

get_file_count() {
    echo "$TIER_FILE_COUNT"
}

get_request_file() {
    local worker_id=$1
    local request_id=$2

    local tier_dir="${DATA_DIR}/tier_${TIER}"
    local file_count=$(get_file_count)

    if [ "$file_count" -eq 0 ]; then
        echo ""
        return
    fi

    local file_idx=$(( ((worker_id - 1) + request_id) % file_count + 1 ))
    echo "${tier_dir}/request_${file_idx}.json"
}

# =============================================
# 发送单个请求 (打印完整结果)
# =============================================
send_request() {
    local worker_id=$1
    local result_dir=$2
    local request_id=$3

    local detail_dir="${result_dir}/details"
    mkdir -p "$detail_dir" 2>/dev/null

    local req_timestamp=$(date +%s%3N)
    local detail_file="${detail_dir}/w${worker_id}_r${request_id}_${req_timestamp}.json"

    # 获取该 worker 使用的请求文件
    local req_file=$(get_request_file "$worker_id" "$request_id")

    if [ -z "$req_file" ] || [ ! -s "$req_file" ]; then
        safe_print "${RED}[W${worker_id}][R${request_id}] ✗ 请求文件不存在: ${req_file}${NC}"
        echo "failed,0,0,0,0,0,file_not_found" >> "${result_dir}/worker_${worker_id}.csv"
        return
    fi

    # 使用临时文件存储响应 (指定 /tmp 目录, 兼容沙箱)
    local resp_file=$(mktemp /tmp/bench_resp_XXXXXX)
    local err_file=$(mktemp /tmp/bench_err_XXXXXX)

    local api_key_index=""
    local header_file=$(mktemp /tmp/bench_hdr_XXXXXX)

    # 发送请求
    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        -D "$header_file" \
        -o "$resp_file" \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -d @"$req_file" \
        --connect-timeout 30 \
        --max-time 600 2>"$err_file")

    # 提取 X-API-Key-Index header
    if [ -s "$header_file" ]; then
        api_key_index=$(grep -i "X-API-Key-Index:" "$header_file" | tr -d '\r' | awk '{print $2}')
    fi
    rm -f "$header_file" 2>/dev/null

    local end_ms=$(date +%s%3N)
    local time_total=$(echo "scale=3; ($end_ms - $req_timestamp) / 1000" | bc 2>/dev/null || echo "0")
    # macOS bc 不输出前导零，补上
    [[ "$time_total" == .* ]] && time_total="0${time_total}"

    local curl_error=""
    if [ -s "$err_file" ]; then
        curl_error=$(cat "$err_file" | tr '\n' ' ' | head -c 200)
    fi

    local body=""
    if [ -s "$resp_file" ]; then
        body=$(cat "$resp_file")
    fi

    [[ ! "$http_code" =~ ^[0-9]+$ ]] && http_code=0
    [[ -z "$time_total" || ! "$time_total" =~ ^[0-9.]+$ ]] && time_total=0

    local prompt_tokens=0
    local completion_tokens=0
    local total_tokens=0
    local error_msg=""
    local model_response=""

    if [ "$http_code" = "200" ]; then
        prompt_tokens=$(echo "$body" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
        completion_tokens=$(echo "$body" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
        total_tokens=$(echo "$body" | jq -r '.usage.total_tokens // 0' 2>/dev/null)
        model_response=$(echo "$body" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
        [[ ! "$prompt_tokens" =~ ^[0-9]+$ ]] && prompt_tokens=0
        [[ ! "$completion_tokens" =~ ^[0-9]+$ ]] && completion_tokens=0
        [[ ! "$total_tokens" =~ ^[0-9]+$ ]] && total_tokens=0
    else
        error_msg=$(echo "$body" | jq -r '.error.message // .message // .error // "Unknown error"' 2>/dev/null | head -c 200)
        [ -z "$error_msg" ] && error_msg="$curl_error"
    fi

    local status="success"
    [ "$http_code" = "429" ] && status="rate_limited"
    [ "$http_code" != "200" ] && [ "$http_code" != "429" ] && status="failed"
    [ "$http_code" = "0" ] && status="timeout"

    # ========== 实时打印调用结果 ==========
    local response_preview=$(echo "$model_response" | head -c 200)

    if [ "$status" = "success" ]; then
        safe_print "${GREEN}[W${worker_id}][R${request_id}] ✓ HTTP ${http_code} | ${time_total}s | Tokens: in=${prompt_tokens} out=${completion_tokens} total=${total_tokens}${NC}"
        safe_print "${CYAN}  文件: $(basename "$req_file")${NC}"
        safe_print "${BLUE}  回复: ${response_preview}${NC}"
        safe_print ""
    elif [ "$status" = "rate_limited" ]; then
        safe_print "${YELLOW}[W${worker_id}][R${request_id}] ⚠ HTTP 429 限流 | ${time_total}s${NC}"
        safe_print "${YELLOW}  错误: ${error_msg}${NC}"
        safe_print ""
    elif [ "$status" = "timeout" ]; then
        safe_print "${RED}[W${worker_id}][R${request_id}] ✗ 超时 | ${time_total}s${NC}"
        safe_print "${RED}  错误: ${error_msg}${NC}"
        safe_print ""
    else
        safe_print "${RED}[W${worker_id}][R${request_id}] ✗ HTTP ${http_code} | ${time_total}s${NC}"
        safe_print "${RED}  错误: ${error_msg}${NC}"
        safe_print ""
    fi

    # 记录详细结果到 JSON 文件
    cat > "$detail_file" << EOF
{"timestamp":"$(date -Iseconds)","worker_id":$worker_id,"request_id":$request_id,"request_file":"$req_file","status":"$status","http_code":$http_code,"latency_sec":$time_total,"prompt_tokens":$prompt_tokens,"completion_tokens":$completion_tokens,"total_tokens":$total_tokens,"error":$(echo "$error_msg" | jq -Rs .),"response":$(echo "$model_response" | jq -Rs .)}
EOF

    # 计算相对开始时间 (秒) — 用于分段统计
    local bench_start_ts
    bench_start_ts=$(cat "${result_dir}/start_time.txt" 2>/dev/null || echo "0")
    local elapsed_sec=0
    if [ "$bench_start_ts" != "0" ]; then
        local start_s=$(echo "${bench_start_ts}" | cut -c1-10)
        local elapsed_ms=$(( req_timestamp - bench_start_ts ))
        elapsed_sec=$(( elapsed_ms / 1000 ))
        [ $elapsed_sec -lt 0 ] && elapsed_sec=0
    fi

    # 记录到 CSV (列1=elapsed_sec, 列2=status, 列8=key_index, 列10=error)
    local error_brief=$(echo "$error_msg" | tr ',' ';' | tr '\n' ' ' | head -c 50)
    echo "${elapsed_sec},${status},${http_code},${time_total},${prompt_tokens},${completion_tokens},${total_tokens},${api_key_index},${error_brief}" >> "${result_dir}/worker_${worker_id}.csv"

    rm -f "$resp_file" "$err_file" 2>/dev/null
}

# =============================================
# 工作进程 - 持续循环发送请求
# =============================================
worker() {
    local worker_id=$1
    local result_dir=$2
    local stop_file="${result_dir}/.stop"

    rm -f "$stop_file" 2>/dev/null

    local request_id=0
    while [ ! -f "$stop_file" ]; do
        send_request "$worker_id" "$result_dir" "$request_id"
        request_id=$((request_id + 1))

        # 短暂间隔避免过快请求
        sleep 0.1
    done
}

# =============================================
# 统计结果
# =============================================
calculate_results() {
    local result_dir=$1
    local duration=$2

    cat "${result_dir}"/worker_*.csv > "${result_dir}/all_results.csv" 2>/dev/null

    if [ ! -s "${result_dir}/all_results.csv" ]; then
        echo "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"
        return
    fi

    local total=$(wc -l < "${result_dir}/all_results.csv" | tr -d '[:space:]')
    total=${total:-0}
    [ "$total" -eq 0 ] && { echo "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"; return; }

    local success=$(grep -c "^success," "${result_dir}/all_results.csv" 2>/dev/null || echo 0)
    success=$(echo "$success" | tr -d '[:space:]')
    local rate_limited=$(grep -c "^rate_limited," "${result_dir}/all_results.csv" 2>/dev/null || echo 0)
    rate_limited=$(echo "$rate_limited" | tr -d '[:space:]')
    local timeout_count=$(grep -c "^timeout," "${result_dir}/all_results.csv" 2>/dev/null || echo 0)
    timeout_count=$(echo "$timeout_count" | tr -d '[:space:]')
    local failed=$(grep -c "^failed," "${result_dir}/all_results.csv" 2>/dev/null || echo 0)
    failed=$(echo "$failed" | tr -d '[:space:]')

    local prompt_tokens=$(awk -F',' '$1=="success" {sum+=$4} END {print int(sum)}' "${result_dir}/all_results.csv")
    local completion_tokens=$(awk -F',' '$1=="success" {sum+=$5} END {print int(sum)}' "${result_dir}/all_results.csv")
    local total_tokens=$(awk -F',' '$1=="success" {sum+=$6} END {print int(sum)}' "${result_dir}/all_results.csv")

    local avg_latency=$(awk -F',' '$1=="success" {sum+=$3; n++} END {if(n>0) printf "%.3f", sum/n; else print 0}' "${result_dir}/all_results.csv")
    local min_latency=$(awk -F',' '$1=="success" {if(min=="" || $3<min) min=$3} END {printf "%.3f", min+0}' "${result_dir}/all_results.csv")
    local max_latency=$(awk -F',' '$1=="success" {if($3>max) max=$3} END {printf "%.3f", max+0}' "${result_dir}/all_results.csv")
    local p95_latency=$(awk -F',' '$1=="success" {latencies[NR]=$3} END {n=asort(latencies); idx=int(n*0.95); if(idx<1)idx=1; printf "%.3f", latencies[idx]}' "${result_dir}/all_results.csv")

    local qpm=$(echo "scale=4; $success * 60 / $duration" | bc 2>/dev/null || echo 0)
    local tpm=$(echo "scale=2; $total_tokens * 60 / $duration" | bc 2>/dev/null || echo 0)
    local input_tpm=$(echo "scale=2; $prompt_tokens * 60 / $duration" | bc 2>/dev/null || echo 0)
    local output_tpm=$(echo "scale=2; $completion_tokens * 60 / $duration" | bc 2>/dev/null || echo 0)

    echo "${total},${success},${failed},${rate_limited},${timeout_count},${prompt_tokens},${completion_tokens},${total_tokens},${avg_latency},${min_latency},${max_latency},${p95_latency},${qpm},${tpm},${input_tpm},${output_tpm}"
}

# =============================================
# 分析 Round-Robin 分布
# =============================================
analyze_round_robin() {
    local result_dir=$1

    log ""
    log "============================================================================"
    log "                    Round-Robin 分布分析"
    log "============================================================================"
    log ""

    if [ ! -s "${result_dir}/all_results.csv" ]; then
        log "  无结果数据可分析"
        return
    fi

    local total_success=$(grep -c "^success," "${result_dir}/all_results.csv" 2>/dev/null || echo 0)
    total_success=$(echo "$total_success" | tr -d '[:space:]')

    if [ "$total_success" -eq 0 ]; then
        log "  无成功请求可分析"
        return
    fi

    awk -F',' '
    $1 == "success" {
        key_idx = $7
        if (key_idx == "" || key_idx == "0") key_idx = "unknown"
        count[key_idx]++
        total++
    }
    END {
        printf "  总成功请求数: %d\n\n", total
        printf "  %-15s %-15s %-15s\n", "Key Index", "请求数", "占比"
        printf "  %-15s %-15s %-15s\n", "--------", "------", "----"

        n = asorti(count, sorted, "@ind_num_asc")
        for (i = 1; i <= n; i++) {
            idx = sorted[i]
            pct = sprintf("%.2f%%", count[idx] * 100 / total)
            printf "  %-15s %-15d %-15s\n", idx, count[idx], pct
        }

        printf "\n"

        if (n <= 1) {
            printf "  ⚠️  警告: 只检测到一个 key index，round-robin 可能未生效\n"
        } else {
            min_count = 999999999
            max_count = 0
            for (idx in count) {
                if (count[idx] < min_count) min_count = count[idx]
                if (count[idx] > max_count) max_count = count[idx]
            }
            if (min_count > 0) {
                ratio = max_count / min_count
                printf "  最大/最小比例: %.2f\n", ratio
                if (ratio < 1.5) {
                    printf "  ✅ Round-robin 分布均匀 (比例 < 1.5)\n"
                } else if (ratio < 3.0) {
                    printf "  ⚠️  Round-robin 分布基本均匀 (比例 < 3.0)\n"
                } else {
                    printf "  ❌ Round-robin 分布不均 (比例 >= 3.0)\n"
                }
            }
        }
    }
    ' "${result_dir}/all_results.csv"

    log ""
    log "  提示: 如果 key index 全部为 'unknown' 或 '0'，说明 Kong 未返回 X-API-Key-Index header"
    log "        请确认插件代码已部署且包含 kong.service.response.set_header() 调用"
}

# =============================================
# 打印最终汇总
# =============================================
print_summary() {
    local result_dir=$1
    local actual_duration=$2

    local results=$(calculate_results "$result_dir" "$actual_duration")
    IFS=',' read -r total success failed rate_limited timeout_count prompt_tokens completion_tokens total_tokens avg_latency min_latency max_latency p95_latency qpm tpm input_tpm output_tpm <<< "$results"

    local success_rate=0
    [ "$total" -gt 0 ] && success_rate=$(echo "scale=2; $success * 100 / $total" | bc 2>/dev/null || echo 0)

    log ""
    log "============================================================================"
    log "                    15K Token 压测 - 最终汇总报告"
    log "============================================================================"
    log ""
    log "【测试配置】"
    log "  模型: ${MODEL}"
    log "  并发数: ${CONCURRENCY}"
    log "  测试时长: ${actual_duration} 秒 ($(echo "scale=1; $actual_duration / 60" | bc) 分钟)"
    log "  输出 max_tokens: ${MAX_TOKENS}"
    log "  数据目录: ${DATA_DIR}/tier_${TIER}"
    log ""
    log "【请求统计】"
    log "  总请求:   ${total}"
    log "  成功:     ${success}"
    log "  失败:     ${failed}"
    log "  限流:     ${rate_limited}"
    log "  超时:     ${timeout_count}"
    log "  成功率:   ${success_rate}%"
    log ""
    log "【延迟统计】"
    log "  平均延迟: ${avg_latency}s"
    log "  最小延迟: ${min_latency}s"
    log "  最大延迟: ${max_latency}s"
    log "  P95 延迟: ${p95_latency}s"
    log ""
    log "【吞吐量】"
    log "  QPM (每分钟成功请求数):   ${qpm}"
    log "  TPM (每分钟 Token 总数):  ${tpm}"
    log "  输入 TPM (Prompt):       ${input_tpm}"
    log "  输出 TPM (Completion):   ${output_tpm}"
    log ""
    log "【Token 消耗】"
    log "  Prompt Tokens:     ${prompt_tokens}"
    log "  Completion Tokens: ${completion_tokens}"
    log "  Total Tokens:      ${total_tokens}"
    log ""
    log "============================================================================"

    # 生成汇总 JSON
    cat > "${result_dir}/final_summary.json" << EOF
{
    "test_time": "$(date -Iseconds)",
    "tier": "${TIER_NAME}",
    "tier_tokens": ${TIER},
    "config": {
        "model": "${MODEL}",
        "concurrency": ${CONCURRENCY},
        "duration_seconds": ${actual_duration},
        "max_tokens": ${MAX_TOKENS},
        "data_dir": "${DATA_DIR}/tier_${TIER}"
    },
    "requests": {
        "total": ${total},
        "success": ${success},
        "failed": ${failed},
        "rate_limited": ${rate_limited},
        "timeout": ${timeout_count},
        "success_rate_percent": ${success_rate}
    },
    "tokens": {
        "prompt": ${prompt_tokens},
        "completion": ${completion_tokens},
        "total": ${total_tokens}
    },
    "latency": {
        "avg": ${avg_latency},
        "min": ${min_latency},
        "max": ${max_latency},
        "p95": ${p95_latency}
    },
    "throughput": {
        "qpm": ${qpm},
        "tpm_total": ${tpm},
        "tpm_input": ${input_tpm},
        "tpm_output": ${output_tpm}
    },
    "result_dir": "${result_dir}"
}
EOF

    log ""
    log "详细数据保存在: ${result_dir}"
    log "  - final_summary.json: 汇总 JSON"
    log "  - all_results.csv: 全部请求数据"
    log "  - details/: 每次调用详细记录"
}

# =============================================
# 帮助
# =============================================
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "15K Token 专项压测脚本"
    echo "仅测试 15K tokens 输入，每次调用实时打印结果"
    echo ""
    echo "前置条件:"
    echo "  先运行 ./generate_test_data.sh 生成测试数据"
    echo ""
    echo "Options:"
    echo "  -h, --help         显示帮助"
    echo "  -c, --concurrency  并发数 (默认: 200)"
    echo "  -d, --duration     测试时长/秒 (默认: 600 = 10分钟)"
    echo "  -t, --tokens       每次请求的 max_tokens (默认: 1000)"
    echo "  -m, --model        测试模型 (默认: glm-5)"
    echo "  --data-dir         测试数据目录 (默认: /tmp/llm_benchmark_data)"
    echo "  --result-dir       结果保存目录 (默认: /tmp/llm_benchmark_results_15k)"
    echo ""
    echo "并发爬升选项:"
    echo "  --ramp-enabled     启用并发爬升 (true/false, 默认: false)"
    echo "  --ramp-start       起始并发数 (默认: 200)"
    echo "  --ramp-end         目标并发数 (默认: 1200)"
    echo "  --ramp-duration    总测试时长/秒 (默认: 1800 = 30分钟)"
    echo "  --ramp-step        每次增加的并发数 (默认: 100)"
    echo "  --ramp-interval    每次增加间隔/秒 (默认: 60)"
    echo ""
    echo "Examples:"
    echo "  $0                      # 默认 10 分钟压测"
    echo "  $0 -d 600 -c 800        # 10 分钟，800 并发"
    echo "  $0 -m qwen-coder-plus   # 测试其他模型"
    echo "  $0 -d 60 -c 1           # 1 分钟，单并发 (调试用)"
    echo "  $0 --ramp-enabled true  # 并发爬升: 200→1200, 30分钟"
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
    -h|--help) show_help; exit 0 ;;
    -c|--concurrency) CONCURRENCY="$2"; shift 2 ;;
    -d|--duration) TOTAL_DURATION="$2"; shift 2 ;;
    -t|--tokens) MAX_TOKENS="$2"; shift 2 ;;
    -m|--model) MODEL="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --result-dir) RESULT_BASE_DIR="$2"; shift 2 ;;
    --ramp-enabled) RAMP_ENABLED="$2"; shift 2 ;;
    --ramp-start) RAMP_START="$2"; shift 2 ;;
    --ramp-end) RAMP_END="$2"; shift 2 ;;
    --ramp-duration) RAMP_DURATION="$2"; shift 2 ;;
    --ramp-step) RAMP_STEP="$2"; shift 2 ;;
    --ramp-interval) RAMP_INTERVAL="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# =============================================
# 主函数
# =============================================
main() {
    mkdir -p "$WORK_DIR"
    mkdir -p "${WORK_DIR}/details"

    # 初始化锁文件
    PRINT_LOCK="${WORK_DIR}/.print_lock"
    touch "$PRINT_LOCK"

    # 创建最新结果软链接
    ln -sfn "$WORK_DIR" "${RESULT_BASE_DIR}/latest"

    log ""
    log "============================================================"
    log "  15K Token 专项压测"
    log "  每次调用实时打印结果"
    log "============================================================"
    log ""

    # 检查依赖
    if ! command -v jq &> /dev/null; then
        log "Error: jq 未安装"
        exit 1
    fi
    if ! command -v bc &> /dev/null; then
        log "Error: bc 未安装"
        exit 1
    fi

    # 检查测试数据
    if ! check_test_data; then
        exit 1
    fi

    # 预计算文件数量 (在 fork worker 前)
    TIER_FILE_COUNT=$(ls -1 "${DATA_DIR}/tier_${TIER}"/*.json 2>/dev/null | wc -l | tr -d '[:space:]')
    TIER_FILE_COUNT=${TIER_FILE_COUNT:-0}
    export TIER_FILE_COUNT
    log ""

    log "【配置】"
    log "  目标地址: ${ENDPOINT}"
    log "  测试模型: ${MODEL}"
    log "  并发数:   ${CONCURRENCY}"
    log "  档位:     ${TIER_NAME} (${TIER} tokens)"
    log "  数据目录: ${DATA_DIR}/tier_${TIER}"
    log "  结果目录: ${WORK_DIR}"
    log ""

    TOTAL_DURATION="${TOTAL_DURATION:-600}"

    if [ "$RAMP_ENABLED" = "true" ]; then
        TOTAL_DURATION="$RAMP_DURATION"
        log "【并发爬升配置】"
        log "  起始并发: ${RAMP_START}"
        log "  目标并发: ${RAMP_END}"
        log "  爬升步长: ${RAMP_STEP} (每次增加并发数)"
        log "  爬升间隔: ${RAMP_INTERVAL} 秒"
        log "  总时长:   ${TOTAL_DURATION} 秒 ($(echo "scale=1; $TOTAL_DURATION / 60" | bc) 分钟)"
        log ""
    fi

    log "开始调用 (${TIER_NAME} tokens, 持续 ${TOTAL_DURATION} 秒)..."
    log "────────────────────────────────────────────────────────────"
    log ""

    local start_time=$(date +%s)
    echo "$start_time" > "${WORK_DIR}/start_time.txt"

    if [ "$RAMP_ENABLED" = "true" ]; then
        local current_concurrency=$RAMP_START
        local worker_id_counter=0
        local elapsed=0

        while [ $elapsed -lt $TOTAL_DURATION ]; do
            local new_workers=0

            if [ $current_concurrency -gt $RAMP_END ]; then
                current_concurrency=$RAMP_END
            fi

            while [ $worker_id_counter -lt $current_concurrency ]; do
                worker_id_counter=$((worker_id_counter + 1))
                worker $worker_id_counter "$WORK_DIR" &
                new_workers=$((new_workers + 1))
                sleep 0.05
            done

            log "[$(date '+%H:%M:%S')] 当前并发: ${current_concurrency} (已启动 ${worker_id_counter} 个 worker)"

            sleep $RAMP_INTERVAL
            elapsed=$((elapsed + RAMP_INTERVAL))

            current_concurrency=$((current_concurrency + RAMP_STEP))
        done

        touch "${WORK_DIR}/.stop"
        wait
    else
        local ramp_up_sec=10
        local batch_size=$(( CONCURRENCY / ramp_up_sec ))
        [ "$batch_size" -lt 1 ] && batch_size=1
        local launched=0
        for i in $(seq 1 $CONCURRENCY); do
            worker $i "$WORK_DIR" &
            launched=$((launched + 1))
            if [ $((launched % batch_size)) -eq 0 ] && [ $launched -lt $CONCURRENCY ]; then
                sleep 1
            fi
        done
        log "全部 ${CONCURRENCY} 个 worker 已启动 (${ramp_up_sec}s 错峰)"

        sleep "$TOTAL_DURATION"
        touch "${WORK_DIR}/.stop"
        wait
    fi

    local actual_end=$(date +%s)
    local actual_duration=$((actual_end - start_time))
    [ "$actual_duration" -eq 0 ] && actual_duration=1

    echo "$actual_end" > "${WORK_DIR}/end_time.txt"
    echo "$actual_duration" > "${WORK_DIR}/duration.txt"

    log ""
    log "────────────────────────────────────────────────────────────"
    log "调用完成！总耗时: ${actual_duration} 秒"

    # 打印汇总
    print_summary "$WORK_DIR" "$actual_duration"

    # 分析 round-robin 分布
    analyze_round_robin "$WORK_DIR"
}

main
