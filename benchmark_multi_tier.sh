#!/bin/bash

#######################################
# 多档位 Token 压测脚本 (使用预生成数据)
# 输入规模: 1K, 5K, 10K, 15K, 30K tokens
# 每个 worker 使用不同的请求数据，避免 KV Cache
# 支持后台运行，详细记录每次调用结果
#######################################

set -o pipefail

# 加载统一配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/kong.conf"

ENDPOINT="${KONG_URL}/llm/v1/chat/completions"

# 压测参数
CONCURRENCY="${CONCURRENCY:-200}"
TOTAL_DURATION="${TOTAL_DURATION:-3600}"
BACKGROUND_MODE=false

# Token 档位配置 (1K, 5K, 10K, 15K, 30K)
#declare -a TOKEN_TIERS=(1000 5000 10000 15000 30000)
#declare -a TIER_NAMES=("1K" "5K" "10K" "15K" "30K")

declare -a TOKEN_TIERS=(15000)
declare -a TIER_NAMES=("15K")

# 预生成的测试数据目录
DATA_DIR="${DATA_DIR:-/tmp/llm_benchmark_data}"

# 结果目录 (固定名称便于查找)
RESULT_BASE_DIR="${RESULT_DIR:-/tmp/llm_benchmark_results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORK_DIR="${RESULT_BASE_DIR}/${TIMESTAMP}"
LOG_FILE="${WORK_DIR}/benchmark.log"
PID_FILE="${RESULT_BASE_DIR}/benchmark.pid"

# 颜色 (后台模式下禁用)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 日志函数
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [ "$BACKGROUND_MODE" = true ]; then
        echo "$msg" >> "$LOG_FILE"
    else
        echo -e "$msg"
    fi
}

log_color() {
    local color=$1
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [ "$BACKGROUND_MODE" = true ]; then
        echo "$msg" >> "$LOG_FILE"
    else
        echo -e "${color}${msg}${NC}"
    fi
}

cleanup() {
    rm -f "$PID_FILE" 2>/dev/null
    rm -f "$TIER_FILE_COUNTS_FILE" 2>/dev/null
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

    local missing=0
    for tier in "${TOKEN_TIERS[@]}"; do
        local tier_dir="${DATA_DIR}/tier_${tier}"
        if [ ! -d "$tier_dir" ]; then
            echo -e "  ${RED}缺少 tier_${tier} 数据${NC}"
            ((missing++))
            continue
        fi

        local count=$(ls -1 "${tier_dir}"/*.json 2>/dev/null | wc -l | tr -d '[:space:]')
        count=${count:-0}

        if [ "$count" -lt "$CONCURRENCY" ]; then
            echo -e "  ${YELLOW}tier_${tier}: ${count} 文件 (少于并发数 ${CONCURRENCY})${NC}"
        else
            echo -e "  ${GREEN}tier_${tier}: ${count} 文件 ✓${NC}"
        fi
    done

    if [ "$missing" -gt 0 ]; then
        echo -e "${RED}缺少 ${missing} 个档位的数据${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ 测试数据检查通过${NC}"
    return 0
}

# =============================================
# 获取请求文件（每个 worker 使用不同的文件）
# =============================================
# 缓存文件数量，避免重复 ls 操作
TIER_FILE_COUNTS_FILE=$(mktemp -t tier_counts.XXXXXX 2>/dev/null || mktemp /tmp/tier_counts.XXXXXX)

get_file_count() {
    local tier=$1
    local cached
    cached=$(grep "^${tier}:" "$TIER_FILE_COUNTS_FILE" 2>/dev/null | cut -d: -f2)
    if [ -n "$cached" ]; then
        echo "$cached"
        return
    fi

    local tier_dir="${DATA_DIR}/tier_${tier}"
    local count=$(ls -1 "${tier_dir}"/*.json 2>/dev/null | wc -l | tr -d '[:space:]')
    count=${count:-0}
    echo "${tier}:${count}" >> "$TIER_FILE_COUNTS_FILE"
    echo "$count"
}

get_request_file() {
    local tier=$1
    local worker_id=$2
    local request_id=$3

    local tier_dir="${DATA_DIR}/tier_${tier}"
    local file_count=$(get_file_count "$tier")

    if [ "$file_count" -eq 0 ]; then
        echo ""
        return
    fi

    # 关键: 确保同一时刻（同一 request_id）不同 worker 使用不同文件
    # worker_id 从 1 开始，文件从 1 开始
    # 公式: ((worker_id - 1) + request_id) % file_count + 1
    # request_0: worker_1→file_1, worker_2→file_2, ..., worker_200→file_200
    # request_1: worker_1→file_2, worker_2→file_3, ..., worker_200→file_1 (轮换)
    local file_idx=$(( ((worker_id - 1) + request_id) % file_count + 1 ))

    echo "${tier_dir}/request_${file_idx}.json"
}

# =============================================
# 发送单个请求 (记录完整结果)
# =============================================
send_request() {
    local worker_id=$1
    local tier=$2
    local tier_dir=$3
    local request_id=$4

    # 详细日志目录
    local detail_dir="${tier_dir}/details"
    mkdir -p "$detail_dir" 2>/dev/null

    local req_timestamp=$(date +%s%3N)
    local detail_file="${detail_dir}/w${worker_id}_r${request_id}_${req_timestamp}.json"

    # 获取该 worker 使用的请求文件
    local req_file=$(get_request_file "$tier" "$worker_id" "$request_id")

    if [ -z "$req_file" ] || [ ! -s "$req_file" ]; then
        # 记录错误
        cat > "$detail_file" << EOF
{"timestamp":"$(date -Iseconds)","worker_id":$worker_id,"request_id":$request_id,"status":"failed","error":"Request file not found or empty","request_file":"$req_file"}
EOF
        echo "failed,0,0,0,0,0,file_not_found" >> "${tier_dir}/worker_${worker_id}.csv"
        return
    fi

    local resp_file="${tier_dir}/.tmp_resp_${worker_id}"
    local err_file="${tier_dir}/.tmp_err_${worker_id}"

    local send_file="$req_file"
    if [ "$MODEL" != "glm-5" ]; then
        local patched_file="${tier_dir}/.tmp_patched_${worker_id}"
        local ts=$(date +%s%N)
        jq --arg model "$MODEL" --arg ts "TS:${ts}" '.messages[0].content = ($ts + "\n" + .messages[0].content)' "$req_file" > "$patched_file" 2>/dev/null
        send_file="$patched_file"
    fi

    # 按 worker_id + request_id 轮询选择 Kong 节点
    local ep_idx=$(( (worker_id - 1 + request_id) % KONG_ENDPOINT_COUNT ))
    get_endpoint "$ep_idx"
    local cur_endpoint="${EP_URL}${ENDPOINT_PATH}"
    local cur_token="${EP_TOKEN}"

    local http_code
    local time_total
    local curl_output
    local curl_exit_code=0

    curl_output=$(curl -s -w "%{http_code} %{time_total}" \
        -o "$resp_file" \
        -X POST "${cur_endpoint}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${cur_token}" \
        -d @"$send_file" \
        --connect-timeout 30 \
        --max-time 600 \
        --keepalive-time 60 2>"$err_file") || curl_exit_code=$?

    http_code="${curl_output%% *}"
    time_total="${curl_output##* }"

    # 如果 curl 完全失败（连接级错误），http_code 和 time_total 可能为空
    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        http_code=0
    fi
    if [ -z "$time_total" ] || ! [[ "$time_total" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        # 回退到 shell 计时
        local end_ms=$(date +%s%3N)
        time_total=$(echo "scale=3; ($end_ms - $start_ms) / 1000" | bc 2>/dev/null || echo "0")
    fi

    local curl_error=""
    if [ -s "$err_file" ]; then
        curl_error=$(cat "$err_file" | tr '\n' ' ' | head -c 200)
    fi

    [[ ! "$http_code" =~ ^[0-9]+$ ]] && http_code=0
    [[ -z "$time_total" || ! "$time_total" =~ ^[0-9.]+$ ]] && time_total=0

    local prompt_tokens=0
    local completion_tokens=0
    local total_tokens=0
    local error_msg=""
    local model_response=""

    if [ "$http_code" = "200" ]; then
        local usage
        usage=$(jq -r '[.usage.prompt_tokens // 0, .usage.completion_tokens // 0, .usage.total_tokens // 0, (.choices[0].message.content // "" | .[0:100])] | @tsv' "$resp_file" 2>/dev/null)
        if [ -n "$usage" ]; then
            prompt_tokens=$(echo "$usage" | cut -f1)
            completion_tokens=$(echo "$usage" | cut -f2)
            total_tokens=$(echo "$usage" | cut -f3)
            model_response=$(echo "$usage" | cut -f4)
        fi
        [[ ! "$prompt_tokens" =~ ^[0-9]+$ ]] && prompt_tokens=0
        [[ ! "$completion_tokens" =~ ^[0-9]+$ ]] && completion_tokens=0
        [[ ! "$total_tokens" =~ ^[0-9]+$ ]] && total_tokens=0
    elif [ -s "$resp_file" ]; then
        error_msg=$(jq -r '.error.message // .message // .error // "Unknown error"' "$resp_file" 2>/dev/null | head -c 200)
        [ -z "$error_msg" ] || [ "$error_msg" = "null" ] && error_msg="$curl_error"
    else
        error_msg="$curl_error"
    fi

    local status="success"
    if [ "$http_code" = "0" ] || [ "$curl_exit_code" -ne 0 ]; then
        status="timeout"
        [ -z "$error_msg" ] && error_msg="Connection failed (curl exit code: $curl_exit_code)"
    elif [ "$http_code" = "429" ]; then
        status="rate_limited"
    elif [ "$http_code" != "200" ]; then
        status="failed"
    fi

    local error_json
    local preview_json
    error_json=$(printf '%s' "$error_msg" | jq -Rs . 2>/dev/null || echo '""')
    preview_json=$(printf '%s' "$model_response" | jq -Rs . 2>/dev/null || echo '""')

    cat > "$detail_file" << EOF
{"timestamp":"$(date -Iseconds)","worker_id":$worker_id,"request_id":$request_id,"request_file":"$req_file","status":"$status","http_code":$http_code,"latency_sec":$time_total,"prompt_tokens":$prompt_tokens,"completion_tokens":$completion_tokens,"total_tokens":$total_tokens,"error":${error_json},"response_preview":${preview_json}}
EOF

    local error_brief
    error_brief=$(printf '%s' "$error_msg" | tr ',' ';' | tr '\n' ' ' | head -c 50)
    echo "${status},${http_code},${time_total},${prompt_tokens},${completion_tokens},${total_tokens},${error_brief}" >> "${tier_dir}/worker_${worker_id}.csv"
}

# =============================================
# 工作进程
# =============================================
worker() {
    local worker_id=$1
    local tier=$2
    local tier_dir=$3
    local end_time=$4

    local request_count=0
    while [ $(date +%s) -lt $end_time ]; do
        send_request "$worker_id" "$tier" "$tier_dir" "$request_count"
        ((request_count++))
        sleep 0.1
    done
}

# =============================================
# 统计单个批次结果 (精确计算)
# =============================================
calculate_tier_results() {
    local tier_dir=$1
    local duration=$2

    cat "${tier_dir}"/worker_*.csv > "${tier_dir}/all_results.csv" 2>/dev/null

    if [ ! -s "${tier_dir}/all_results.csv" ]; then
        echo "0,0,0,0,0,0,0,0,0,0,0,0,0,0"
        return
    fi

    local total=$(wc -l < "${tier_dir}/all_results.csv" | tr -d '[:space:]')
    total=${total:-0}
    [ "$total" -eq 0 ] && { echo "0,0,0,0,0,0,0,0,0,0,0,0,0,0"; return; }

    # 精确统计各状态
    local success=$(grep -c "^success," "${tier_dir}/all_results.csv" 2>/dev/null || echo 0)
    success=$(echo "$success" | tr -d '[:space:]')
    local rate_limited=$(grep -c "^rate_limited," "${tier_dir}/all_results.csv" 2>/dev/null || echo 0)
    rate_limited=$(echo "$rate_limited" | tr -d '[:space:]')
    local timeout_count=$(grep -c "^timeout," "${tier_dir}/all_results.csv" 2>/dev/null || echo 0)
    timeout_count=$(echo "$timeout_count" | tr -d '[:space:]')
    local failed=$(grep -c "^failed," "${tier_dir}/all_results.csv" 2>/dev/null || echo 0)
    failed=$(echo "$failed" | tr -d '[:space:]')

    # Token 统计 (只统计成功的请求)
    local prompt_tokens=$(awk -F',' '$1=="success" {sum+=$4} END {print int(sum)}' "${tier_dir}/all_results.csv")
    local completion_tokens=$(awk -F',' '$1=="success" {sum+=$5} END {print int(sum)}' "${tier_dir}/all_results.csv")
    local total_tokens=$(awk -F',' '$1=="success" {sum+=$6} END {print int(sum)}' "${tier_dir}/all_results.csv")

    # 延迟统计 (只统计成功的请求)
    local avg_latency=$(awk -F',' '$1=="success" {sum+=$3; n++} END {if(n>0) printf "%.3f", sum/n; else print 0}' "${tier_dir}/all_results.csv")
    local min_latency=$(awk -F',' '$1=="success" {if(min=="" || $3<min) min=$3} END {printf "%.3f", min+0}' "${tier_dir}/all_results.csv")
    local max_latency=$(awk -F',' '$1=="success" {if($3>max) max=$3} END {printf "%.3f", max+0}' "${tier_dir}/all_results.csv")
    local p95_latency=$(awk -F',' '$1=="success" {print $3}' "${tier_dir}/all_results.csv" | sort -n | awk '{a[NR]=$1} END {idx=int(NR*0.95); if(idx<1)idx=1; if(NR>0) printf "%.3f", a[idx]; else print 0}')

    # 精确计算 QPM 和 TPM (基于实际测试时长)
    # QPM = 成功请求数 * 60 / 实际时长(秒)
    # TPM = 总 Token 数 * 60 / 实际时长(秒)
    local qpm=$(echo "scale=4; $success * 60 / $duration" | bc 2>/dev/null || echo 0)
    local tpm=$(echo "scale=2; $total_tokens * 60 / $duration" | bc 2>/dev/null || echo 0)
    local input_tpm=$(echo "scale=2; $prompt_tokens * 60 / $duration" | bc 2>/dev/null || echo 0)
    local output_tpm=$(echo "scale=2; $completion_tokens * 60 / $duration" | bc 2>/dev/null || echo 0)

    echo "${total},${success},${failed},${rate_limited},${timeout_count},${prompt_tokens},${completion_tokens},${total_tokens},${avg_latency},${min_latency},${max_latency},${p95_latency},${qpm},${tpm},${input_tpm},${output_tpm}"
}

# =============================================
# 运行单个批次
# =============================================
run_tier_benchmark() {
    local tier_idx=$1
    local tier=${TOKEN_TIERS[$tier_idx]}
    local tier_name=${TIER_NAMES[$tier_idx]}
    local tier_duration=$2
    local result_dir="${WORK_DIR}/tier_${tier}"

    mkdir -p "$result_dir"
    mkdir -p "${result_dir}/details"

    log ""
    log "============================================================"
    log "批次 $((tier_idx+1))/5: ${tier_name} tokens 输入压测"
    log "============================================================"
    log "配置: 模型=${MODEL}, 并发=${CONCURRENCY}, 时长=${tier_duration}秒"
    log "数据: ${DATA_DIR}/tier_${tier}/ (每个 worker 使用不同请求)"
    log ""

    local start_time=$(date +%s)
    local end_time=$((start_time + tier_duration))

    # 记录批次开始时间
    echo "$start_time" > "${result_dir}/start_time.txt"

    # 启动 workers (错峰启动，避免惊群效应)
    local ramp_up_sec=10
    local batch_size=$(( CONCURRENCY / ramp_up_sec ))
    [ "$batch_size" -lt 1 ] && batch_size=1
    local launched=0
    for i in $(seq 1 $CONCURRENCY); do
        worker $i "$tier" "$result_dir" "$end_time" &
        launched=$((launched + 1))
        if [ $((launched % batch_size)) -eq 0 ] && [ $launched -lt $CONCURRENCY ]; then
            sleep 1
        fi
    done
    log "全部 ${CONCURRENCY} 个 worker 已启动 (${ramp_up_sec}s 爬坡)"

    # 显示进度
    while [ $(date +%s) -lt $end_time ]; do
        local elapsed=$(($(date +%s) - start_time))
        local count=0
        local csv_files=("${result_dir}"/worker_*.csv)
        if [ -e "${csv_files[0]}" ]; then
            count=$(cat "${csv_files[@]}" 2>/dev/null | wc -l | tr -d '[:space:]')
        fi

        if [ "$BACKGROUND_MODE" = true ]; then
            # 后台模式: 每 30 秒记录一次进度
            if [ $((elapsed % 30)) -eq 0 ]; then
                log "[${tier_name}] 进度: ${elapsed}/${tier_duration}秒 | 已完成: ${count} 请求"
            fi
        else
            printf "\r  [${tier_name}] 进度: %d/%d 秒 | 已完成: %s 请求" "$elapsed" "$tier_duration" "$count"
        fi
        sleep 2
    done

    [ "$BACKGROUND_MODE" != true ] && echo ""

    log "等待请求完成..."
    wait

    local actual_end=$(date +%s)
    local actual_duration=$((actual_end - start_time))
    [ "$actual_duration" -eq 0 ] && actual_duration=1

    # 记录批次结束时间
    echo "$actual_end" > "${result_dir}/end_time.txt"
    echo "$actual_duration" > "${result_dir}/duration.txt"

    # 统计结果
    local results=$(calculate_tier_results "$result_dir" "$actual_duration")
    IFS=',' read -r total success failed rate_limited timeout_count prompt_tokens completion_tokens total_tokens avg_latency min_latency max_latency p95_latency qpm tpm input_tpm output_tpm <<< "$results"

    # 保存到汇总文件 (扩展格式)
    echo "${tier_name},${total},${success},${failed},${rate_limited},${timeout_count},${prompt_tokens},${completion_tokens},${total_tokens},${avg_latency},${min_latency},${max_latency},${p95_latency},${qpm},${tpm},${input_tpm},${output_tpm},${actual_duration}" >> "${WORK_DIR}/summary.csv"

    # 保存详细指标到单独文件
    cat > "${result_dir}/metrics.json" << EOF
{
    "tier": "${tier_name}",
    "tier_tokens": ${tier},
    "duration_seconds": ${actual_duration},
    "concurrency": ${CONCURRENCY},
    "requests": {
        "total": ${total},
        "success": ${success},
        "failed": ${failed},
        "rate_limited": ${rate_limited},
        "timeout": ${timeout_count}
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
    }
}
EOF

    # 打印批次结果
    local success_rate=0
    [ "$total" -gt 0 ] && success_rate=$(echo "scale=2; $success * 100 / $total" | bc 2>/dev/null || echo 0)

    log ""
    log "【${tier_name} 批次结果】"
    log "  总请求: ${total} | 成功: ${success} | 失败: ${failed} | 限流: ${rate_limited} | 超时: ${timeout_count}"
    log "  成功率: ${success_rate}%"
    log "  延迟: 平均=${avg_latency}s, 最小=${min_latency}s, 最大=${max_latency}s, P95=${p95_latency}s"
    log "  QPM: ${qpm} (每分钟成功请求数)"
    log "  TPM: ${tpm} (每分钟Token总数, 入=${input_tpm}, 出=${output_tpm})"
    log "  Tokens: Prompt=${prompt_tokens}, Completion=${completion_tokens}, Total=${total_tokens}"
    log ""
}

# =============================================
# 打印最终汇总 (精确统计)
# =============================================
print_final_summary() {
    log ""
    log "============================================================================"
    log "                         最终汇总报告"
    log "============================================================================"
    log ""

    log "【测试配置】"
    log "  模型: ${MODEL}"
    log "  并发数: ${CONCURRENCY}"
    log "  总时长: ${TOTAL_DURATION} 秒 ($(echo "scale=1; $TOTAL_DURATION / 60" | bc) 分钟)"
    log "  输出 max_tokens: ${MAX_TOKENS}"
    log "  数据目录: ${DATA_DIR}"
    log ""

    log "【各档位结果对比】"
    log "  档位     总请求   成功     失败     限流     超时     成功率    QPM        TPM(总)    TPM(入)    TPM(出)   平均延迟    P95延迟"
    log "  ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    local grand_total=0
    local grand_success=0
    local grand_failed=0
    local grand_rate_limited=0
    local grand_timeout=0
    local grand_prompt=0
    local grand_completion=0
    local grand_tokens=0
    local grand_duration=0

    # CSV格式: tier,total,success,failed,rate_limited,timeout,prompt,completion,tokens,avg_lat,min_lat,max_lat,p95_lat,qpm,tpm,input_tpm,output_tpm,duration
    while IFS=',' read -r tier total success failed rate_limited timeout_count prompt completion tokens avg_lat min_lat max_lat p95_lat qpm tpm input_tpm output_tpm duration; do
        [ -z "$tier" ] && continue
        local rate=0
        [ "$total" -gt 0 ] && rate=$(echo "scale=2; $success * 100 / $total" | bc 2>/dev/null || echo 0)

        log "  $(printf '%-8s %8s %8s %8s %8s %8s %8s%% %10s %10s %10s %10s %10ss %10ss' "$tier" "$total" "$success" "$failed" "$rate_limited" "$timeout_count" "$rate" "$qpm" "$tpm" "$input_tpm" "$output_tpm" "$avg_lat" "$p95_lat")"

        grand_total=$((grand_total + total))
        grand_success=$((grand_success + success))
        grand_failed=$((grand_failed + failed))
        grand_rate_limited=$((grand_rate_limited + rate_limited))
        grand_timeout=$((grand_timeout + timeout_count))
        grand_prompt=$((grand_prompt + prompt))
        grand_completion=$((grand_completion + completion))
        grand_tokens=$((grand_tokens + tokens))
        grand_duration=$((grand_duration + duration))
    done < "${WORK_DIR}/summary.csv"

    log "  ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    # 计算汇总
    local grand_rate=0
    [ "$grand_total" -gt 0 ] && grand_rate=$(echo "scale=2; $grand_success * 100 / $grand_total" | bc 2>/dev/null || echo 0)
    local grand_qpm=$(echo "scale=4; $grand_success * 60 / $grand_duration" | bc 2>/dev/null || echo 0)
    local grand_tpm=$(echo "scale=2; $grand_tokens * 60 / $grand_duration" | bc 2>/dev/null || echo 0)
    local grand_input_tpm=$(echo "scale=2; $grand_prompt * 60 / $grand_duration" | bc 2>/dev/null || echo 0)
    local grand_output_tpm=$(echo "scale=2; $grand_completion * 60 / $grand_duration" | bc 2>/dev/null || echo 0)

    log "  $(printf '%-8s %8s %8s %8s %8s %8s %8s%% %10s %10s %10s %10s' '汇总' "$grand_total" "$grand_success" "$grand_failed" "$grand_rate_limited" "$grand_timeout" "$grand_rate" "$grand_qpm" "$grand_tpm" "$grand_input_tpm" "$grand_output_tpm")"
    log ""

    log "【Token 消耗汇总】"
    log "  总 Prompt Tokens:     ${grand_prompt}"
    log "  总 Completion Tokens: ${grand_completion}"
    log "  总 Tokens:            ${grand_tokens}"
    log ""

    log "【核心指标 (Precise)】"
    log "  综合 QPM (每分钟成功请求数):   ${grand_qpm}"
    log "  综合 TPM (每分钟 Token 总数):  ${grand_tpm}"
    log "  输入 TPM (每分钟 Prompt):     ${grand_input_tpm}"
    log "  输出 TPM (每分钟 Completion): ${grand_output_tpm}"
    log ""

    log "============================================================================"
    log ""

    # 生成汇总 JSON
    cat > "${WORK_DIR}/final_summary.json" << EOF
{
    "test_time": "$(date -Iseconds)",
    "config": {
        "model": "${MODEL}",
        "concurrency": ${CONCURRENCY},
        "total_duration_seconds": ${TOTAL_DURATION},
        "max_tokens": ${MAX_TOKENS},
        "data_dir": "${DATA_DIR}"
    },
    "summary": {
        "total_requests": ${grand_total},
        "successful_requests": ${grand_success},
        "failed_requests": ${grand_failed},
        "rate_limited_requests": ${grand_rate_limited},
        "timeout_requests": ${grand_timeout},
        "success_rate_percent": ${grand_rate}
    },
    "tokens": {
        "prompt": ${grand_prompt},
        "completion": ${grand_completion},
        "total": ${grand_tokens}
    },
    "throughput": {
        "qpm": ${grand_qpm},
        "tpm_total": ${grand_tpm},
        "tpm_input": ${grand_input_tpm},
        "tpm_output": ${grand_output_tpm}
    },
    "result_dir": "${WORK_DIR}"
}
EOF

    log "详细数据保存在: ${WORK_DIR}"
    log "  - summary.csv: 汇总数据"
    log "  - final_summary.json: 汇总 JSON"
    log "  - tier_*/metrics.json: 各档位指标"
    log "  - tier_*/details/: 每次调用详细记录"
    log "  - tier_*/all_results.csv: 各批次汇总数据"
}

# =============================================
# 帮助
# =============================================
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "多档位 Token 压测脚本 (1K/5K/10K/15K/30K)"
    echo "每个 worker 使用不同的请求数据，避免 KV Cache"
    echo ""
    echo "前置条件:"
    echo "  先运行 ./generate_test_data.sh 生成测试数据"
    echo ""
    echo "Options:"
    echo "  -h, --help         显示帮助"
    echo "  -b, --background   后台运行模式"
    echo "  -c, --concurrency  并发数 (默认: 200)"
    echo "  -d, --duration     总测试时长/秒 (默认: 3600 = 1小时)"
    echo "  -t, --tokens       每次请求的 max_tokens (默认: 1000)"
    echo "  -m, --model        测试模型 (默认: glm-5)"
    echo "  --data-dir         测试数据目录 (默认: /tmp/llm_benchmark_data)"
    echo "  --result-dir       结果保存目录 (默认: /tmp/llm_benchmark_results)"
    echo ""
    echo "Examples:"
    echo "  $0                      # 默认 1 小时压测 (前台)"
    echo "  $0 -b                   # 后台运行"
    echo "  $0 -b -d 1800 -c 100    # 后台运行，30 分钟，100 并发"
    echo "  $0 -m qwen-coder-plus   # 测试其他模型"
    echo ""
    echo "后台模式说明:"
    echo "  - 日志写入: /tmp/llm_benchmark_results/<timestamp>/benchmark.log"
    echo "  - PID文件: /tmp/llm_benchmark_results/benchmark.pid"
    echo "  - 查看进度: tail -f /tmp/llm_benchmark_results/<timestamp>/benchmark.log"
    echo "  - 停止测试: kill \$(cat /tmp/llm_benchmark_results/benchmark.pid)"
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -b|--background) BACKGROUND_MODE=true; shift ;;
        -c|--concurrency) CONCURRENCY="$2"; shift 2 ;;
        -d|--duration) TOTAL_DURATION="$2"; shift 2 ;;
        -t|--tokens) MAX_TOKENS="$2"; shift 2 ;;
        -m|--model) MODEL="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --result-dir) RESULT_BASE_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# =============================================
# 主函数
# =============================================
main() {
    # 创建结果目录
    mkdir -p "$WORK_DIR"
    mkdir -p "$RESULT_BASE_DIR"

    # 创建最新结果软链接
    ln -sfn "$WORK_DIR" "${RESULT_BASE_DIR}/latest"

    log ""
    log "============================================================"
    log "多档位 Token 压测 (1K/5K/10K/15K/30K)"
    log "每个 worker 使用不同数据，无 KV Cache 干扰"
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
    log ""

    log "【总体配置】"
    log "  Kong 节点数: ${KONG_ENDPOINT_COUNT}"
    for i in $(seq 0 $((KONG_ENDPOINT_COUNT - 1))); do
        get_endpoint "$i"
        log "    节点$((i+1)): ${EP_URL}"
    done
    log "  测试模型: ${MODEL}"
    log "  并发数:   ${CONCURRENCY}"
    log "  总时长:   ${TOTAL_DURATION} 秒 ($(echo "scale=1; $TOTAL_DURATION / 60" | bc) 分钟)"
    log "  档位:     ${TIER_NAMES[*]}"
    log "  数据目录: ${DATA_DIR}"
    log "  结果目录: ${WORK_DIR}"
    log ""

    # 测试所有节点连接
    log "测试连接 (${KONG_ENDPOINT_COUNT} 个节点)..."
    local conn_fail=0
    for i in $(seq 0 $((KONG_ENDPOINT_COUNT - 1))); do
        get_endpoint "$i"
        local test_url="${EP_URL}${ENDPOINT_PATH}"
        if curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" "${test_url}" > /dev/null 2>&1; then
            log "  ✓ 节点$((i+1)) ${EP_URL} 连接成功"
        else
            log "  ✗ 节点$((i+1)) ${EP_URL} 连接失败"
            ((conn_fail++))
        fi
    done
    if [ "$conn_fail" -eq "$KONG_ENDPOINT_COUNT" ]; then
        log "所有 Kong 节点均无法连接，退出"
        exit 1
    elif [ "$conn_fail" -gt 0 ]; then
        log "⚠ ${conn_fail} 个节点连接失败，继续使用可用节点"
    fi
    log "✓ 连接测试完成"

    # 初始化汇总文件
    > "${WORK_DIR}/summary.csv"

    # 计算每个批次时长
    local num_tiers=${#TOKEN_TIERS[@]}
    local tier_duration=$((TOTAL_DURATION / num_tiers))

    print_execution_plan "$num_tiers" "$tier_duration"

    log ""
    log "开始压测，每个档位 ${tier_duration} 秒，共 ${num_tiers} 个档位"

    local test_start=$(date +%s)

    # 运行各档位测试
    for idx in "${!TOKEN_TIERS[@]}"; do
        run_tier_benchmark "$idx" "$tier_duration"
    done

    local test_end=$(date +%s)
    local total_elapsed=$((test_end - test_start))

    log ""
    log "压测完成！总耗时: ${total_elapsed} 秒 ($(echo "scale=1; $total_elapsed / 60" | bc) 分钟)"

    print_final_summary

    analyze_results
}

print_execution_plan() {
    local num_tiers=$1
    local tier_duration=$2

    log ""
    log "============================================================================"
    log "                         执行计划"
    log "============================================================================"
    log ""
    log "【阶段 1: 环境检查】"
    log "  ✓ 依赖检查 (jq, bc)"
    log "  ✓ 测试数据验证 (${DATA_DIR})"
    log "  ✓ 网关连接测试 (${ENDPOINT})"
    log ""
    log "【阶段 2: 压测执行】"
    log "  并发数: ${CONCURRENCY} workers"
    log "  总时长: ${TOTAL_DURATION} 秒 ($(echo "scale=1; $TOTAL_DURATION / 60" | bc) 分钟)"
    log "  档位数: ${num_tiers}"
    log "  每档时长: ${tier_duration} 秒"
    log ""
    log "  执行顺序:"
    for idx in "${!TOKEN_TIERS[@]}"; do
        local tier=${TOKEN_TIERS[$idx]}
        local tier_name=${TIER_NAMES[$idx]}
        local file_count=$(get_file_count "$tier")
        log "    $((idx+1)). ${tier_name} tokens (${tier_duration}s) — ${file_count} 个测试数据文件"
    done
    log ""
    log "【阶段 3: 结果汇总】"
    log "  - 各档位成功率、延迟、QPM、TPM"
    log "  - 总体汇总 (加权平均)"
    log "  - 结果文件: ${WORK_DIR}/"
    log ""
    log "【阶段 4: 结果分析】"
    log "  - 错误分类与根因分析"
    log "  - 延迟分布分析"
    log "  - 性能瓶颈识别"
    log "  - 优化建议"
    log ""
    log "============================================================================"
}

analyze_results() {
    log ""
    log "============================================================================"
    log "                         结果分析"
    log "============================================================================"
    log ""

    local csv_file="${WORK_DIR}/summary.csv"
    if [ ! -s "$csv_file" ]; then
        log "⚠ 无结果数据可供分析"
        return
    fi

    local grand_total=0
    local grand_success=0
    local grand_failed=0
    local grand_rate_limited=0
    local grand_timeout=0
    local grand_tokens=0
    local grand_duration=0

    while IFS=',' read -r tier total success failed rate_limited timeout_count prompt completion tokens avg_lat min_lat max_lat p95_lat qpm tpm input_tpm output_tpm duration; do
        [ -z "$tier" ] && continue
        grand_total=$((grand_total + total))
        grand_success=$((grand_success + success))
        grand_failed=$((grand_failed + failed))
        grand_rate_limited=$((grand_rate_limited + rate_limited))
        grand_timeout=$((grand_timeout + timeout_count))
        grand_tokens=$((grand_tokens + tokens))
        grand_duration=$((grand_duration + duration))
    done < "$csv_file"

    local success_rate=0
    [ "$grand_total" -gt 0 ] && success_rate=$(echo "scale=2; $grand_success * 100 / $grand_total" | bc 2>/dev/null || echo 0)

    log "【1. 核心指标】"
    log "  总请求: ${grand_total}"
    log "  成功: ${grand_success} | 失败: ${grand_failed} | 限流: ${grand_rate_limited} | 超时: ${grand_timeout}"
    log "  成功率: ${success_rate}%"
    log "  总 Token 消耗: ${grand_tokens}"
    log ""

    log "【2. 错误分析】"
    if [ "$grand_failed" -gt 0 ]; then
        local failed_pct=$(echo "scale=2; $grand_failed * 100 / $grand_total" | bc 2>/dev/null || echo 0)
        log "  ⚠ 业务失败 (HTTP 4xx/5xx): ${grand_failed} 次 (${failed_pct}%)"
        log "    检查 Kong 网关日志和上游服务状态"
    fi
    if [ "$grand_timeout" -gt 0 ]; then
        local timeout_pct=$(echo "scale=2; $grand_timeout * 100 / $grand_total" | bc 2>/dev/null || echo 0)
        log "  ⚠ 连接超时/拒绝: ${grand_timeout} 次 (${timeout_pct}%)"
        log "    检查: 网关是否运行、端口是否正确、防火墙是否开放"
    fi
    if [ "$grand_rate_limited" -gt 0 ]; then
        local rl_pct=$(echo "scale=2; $grand_rate_limited * 100 / $grand_total" | bc 2>/dev/null || echo 0)
        log "  ⚠ 速率限制 (429): ${grand_rate_limited} 次 (${rl_pct}%)"
        log "    检查: 上游 API 配额、考虑在 Kong 侧添加 rate-limiting 插件"
    fi
    if [ "$grand_failed" -eq 0 ] && [ "$grand_timeout" -eq 0 ] && [ "$grand_rate_limited" -eq 0 ]; then
        log "  ✓ 无错误"
    fi
    log ""

    log "【3. 性能瓶颈】"
    if [ "$success_rate" = "0" ] || [ "$success_rate" = "0.00" ]; then
        log "  🔴 严重: 成功率为 0%，压测完全失败"
        log "    优先排查连接问题和网关配置"
    elif [ "$(echo "$success_rate < 50" | bc 2>/dev/null || echo 0)" = "1" ]; then
        log "  🔴 严重: 成功率低于 50%"
        log "    需立即排查失败原因"
    elif [ "$(echo "$success_rate < 90" | bc 2>/dev/null || echo 0)" = "1" ]; then
        log "  🟡 警告: 成功率低于 90%"
        log "    建议优化超时配置和上游配额"
    else
        log "  🟢 成功率 ${success_rate}%，表现良好"
    fi
    log ""

    log "【4. 优化建议】"
    if [ "$grand_timeout" -gt "$((grand_total / 10))" ]; then
        log "  → 超时占比过高: 检查网关连接配置 (端口、防火墙、backlog)"
    fi
    if [ "$grand_rate_limited" -gt "$((grand_total / 20))" ]; then
        log "  → 限流频繁: 升级上游配额或在 Kong 侧添加 rate-limiting 插件"
    fi
    if [ "$grand_failed" -gt 0 ]; then
        log "  → 业务失败: 检查 Kong 网关日志 (error.log) 定位具体错误"
    fi
    log "  → 建议检查 Kong 配置: client_body_buffer_size (建议 256k)"
    log "  → 建议检查 Service 超时: read_timeout (建议 30000ms)"
    log ""
    log "============================================================================"
}

# =============================================
# 启动入口
# =============================================
if [ "$BACKGROUND_MODE" = true ]; then
    # 后台模式
    mkdir -p "$WORK_DIR"
    echo $$ > "$PID_FILE"

    echo "压测已在后台启动..."
    echo "  PID: $$"
    echo "  日志: ${LOG_FILE}"
    echo "  结果: ${WORK_DIR}"
    echo ""
    echo "查看进度: tail -f ${LOG_FILE}"
    echo "停止测试: kill \$(cat ${PID_FILE})"

    # 禁用颜色
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    NC=''

    # 后台运行
    nohup bash -c '
        source "'"$0"'"
        BACKGROUND_MODE=true
        LOG_FILE="'"$LOG_FILE"'"
        WORK_DIR="'"$WORK_DIR"'"
        main
    ' > /dev/null 2>&1 &

    # 直接运行 main 并重定向输出
    exec > "$LOG_FILE" 2>&1
    main
else
    # 前台模式
    main
fi
