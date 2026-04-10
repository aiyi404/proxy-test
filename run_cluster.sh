#!/bin/bash
#######################################
# 集群压测管理脚本
# 用法:
#   ./run_cluster.sh gen       # 并行生成测试数据
#   ./run_cluster.sh run       # 并行启动压测（后台）
#   ./run_cluster.sh status    # 查看各机器压测进度
#   ./run_cluster.sh collect   # 收集并汇总结果
#   ./run_cluster.sh stop      # 停止所有机器压测
#######################################

REMOTE_HOSTS=(
    "8.137.58.1"
    "47.108.49.239"
    "8.137.174.163"
    "8.137.175.12"
)
LOCAL_HOST="$(hostname -I | awk '{print $1}')"
ALL_HOSTS=("local" "${REMOTE_HOSTS[@]}")

REMOTE_USER="root"
REMOTE_PASS="Rds123456"
WORK_DIR="/root/proxy_test"

# 压测参数（按需修改）
CONCURRENCY="${CONCURRENCY:-400}"       # 每台机器并发数，5台合计2000
TOTAL_DURATION="${TOTAL_DURATION:-1800}" # 压测时长（秒）
NUM_VARIANTS="${NUM_VARIANTS:-500}"      # 每档测试数据份数
MAX_TOKENS="${MAX_TOKENS:-1000}"

# 结果汇总目录
COLLECT_DIR="/root/proxy_test/cluster_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================
# 远程执行命令
# =============================================
remote_exec() {
    local host=$1
    shift
    sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        "$REMOTE_USER@$host" "$@" 2>/dev/null
}

# =============================================
# 生成测试数据
# =============================================
cmd_gen() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  并行生成测试数据 (${NUM_VARIANTS} 份/档位)${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # 本机生成
    gen_local() {
        echo -e "${YELLOW}[本机] 生成测试数据...${NC}"
        cd "$WORK_DIR"
        NUM_VARIANTS=$NUM_VARIANTS ./generate_test_data.sh > /tmp/gen_local.log 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[本机] ✓ 数据生成完成${NC}"
        else
            echo -e "${RED}[本机] ✗ 数据生成失败，查看 /tmp/gen_local.log${NC}"
        fi
    }

    # 远程生成
    gen_remote() {
        local host=$1
        echo -e "${YELLOW}[$host] 生成测试数据...${NC}"
        remote_exec "$host" "cd $WORK_DIR && NUM_VARIANTS=$NUM_VARIANTS ./generate_test_data.sh" \
            > "/tmp/gen_${host}.log" 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[$host] ✓ 数据生成完成${NC}"
        else
            echo -e "${RED}[$host] ✗ 数据生成失败，查看 /tmp/gen_${host}.log${NC}"
        fi
    }

    # 并行执行
    gen_local &
    for host in "${REMOTE_HOSTS[@]}"; do
        gen_remote "$host" &
    done
    wait

    echo ""
    echo -e "${GREEN}所有机器数据生成完毕！${NC}"
}

# =============================================
# 启动压测
# =============================================
cmd_run() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  启动集群压测${NC}"
    echo -e "${CYAN}  每台并发: ${CONCURRENCY}  时长: ${TOTAL_DURATION}s${NC}"
    echo -e "${CYAN}  合计并发: $((CONCURRENCY * 5))${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # 本机启动（后台）
    echo -e "${YELLOW}[本机] 启动压测...${NC}"
    cd "$WORK_DIR"
    CONCURRENCY=$CONCURRENCY TOTAL_DURATION=$TOTAL_DURATION MAX_TOKENS=$MAX_TOKENS \
        nohup ./benchmark_multi_tier.sh > /tmp/bench_local.log 2>&1 &
    echo $! > /tmp/bench_local.pid
    echo -e "${GREEN}[本机] ✓ 已启动 (PID: $(cat /tmp/bench_local.pid))${NC}"

    # 远程启动
    for host in "${REMOTE_HOSTS[@]}"; do
        echo -e "${YELLOW}[$host] 启动压测...${NC}"
        remote_exec "$host" \
            "cd $WORK_DIR && CONCURRENCY=$CONCURRENCY TOTAL_DURATION=$TOTAL_DURATION MAX_TOKENS=$MAX_TOKENS nohup ./benchmark_multi_tier.sh > /tmp/bench.log 2>&1 & echo \$! > /tmp/bench.pid && echo 'started'"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[$host] ✓ 已启动${NC}"
        else
            echo -e "${RED}[$host] ✗ 启动失败${NC}"
        fi
    done

    echo ""
    echo -e "${GREEN}所有机器压测已启动！${NC}"
    echo -e "查看进度: ${CYAN}./run_cluster.sh status${NC}"
    echo -e "停止压测: ${CYAN}./run_cluster.sh stop${NC}"
    echo -e "收集结果: ${CYAN}./run_cluster.sh collect${NC}"
}

# =============================================
# 查看状态
# =============================================
cmd_status() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  各机器压测状态${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # 本机状态
    check_local() {
        local log="/tmp/bench_local.log"
        if [ -f /tmp/bench_local.pid ] && kill -0 $(cat /tmp/bench_local.pid) 2>/dev/null; then
            local count=$(grep -c "^success\|^failed\|^rate_limited\|^timeout" \
                /tmp/llm_benchmark_results/latest/tier_15000/all_results.csv 2>/dev/null || echo "?")
            local last=$(tail -3 "$log" 2>/dev/null | tr '\n' ' ')
            echo -e "${GREEN}[本机] 运行中 | 已完成请求: ${count}${NC}"
            echo -e "  最新日志: ${last}"
        else
            echo -e "${YELLOW}[本机] 未运行${NC}"
        fi
    }

    check_remote() {
        local host=$1
        local result
        result=$(remote_exec "$host" \
            "if [ -f /tmp/bench.pid ] && kill -0 \$(cat /tmp/bench.pid) 2>/dev/null; then
                count=\$(wc -l < /tmp/llm_benchmark_results/latest/tier_15000/all_results.csv 2>/dev/null || echo 0)
                echo \"running|\$count\"
            else
                echo 'stopped'
            fi")

        if [[ "$result" == running* ]]; then
            local count=$(echo "$result" | cut -d'|' -f2)
            echo -e "${GREEN}[$host] 运行中 | 已完成请求: ${count}${NC}"
        else
            echo -e "${YELLOW}[$host] 未运行${NC}"
        fi
    }

    check_local
    for host in "${REMOTE_HOSTS[@]}"; do
        check_remote "$host" &
    done
    wait
    echo ""
}

# =============================================
# 停止压测
# =============================================
cmd_stop() {
    echo -e "${YELLOW}停止所有机器压测...${NC}"

    # 本机
    if [ -f /tmp/bench_local.pid ]; then
        kill $(cat /tmp/bench_local.pid) 2>/dev/null
        pkill -f benchmark_multi_tier 2>/dev/null
        echo -e "${GREEN}[本机] ✓ 已停止${NC}"
    fi

    # 远程
    for host in "${REMOTE_HOSTS[@]}"; do
        remote_exec "$host" \
            "[ -f /tmp/bench.pid ] && kill \$(cat /tmp/bench.pid) 2>/dev/null; pkill -f benchmark_multi_tier 2>/dev/null; echo stopped" &
    done
    wait
    echo -e "${GREEN}所有机器已停止${NC}"
}

# =============================================
# 收集并汇总结果
# =============================================
cmd_collect() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  收集并汇总压测结果${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    mkdir -p "$COLLECT_DIR/$TIMESTAMP"

    # 收集本机结果
    collect_local() {
        local latest="/tmp/llm_benchmark_results/latest"
        if [ -f "$latest/final_summary.json" ]; then
            cp "$latest/final_summary.json" "$COLLECT_DIR/$TIMESTAMP/summary_local.json"
            cp "$latest/tier_15000/all_results.csv" "$COLLECT_DIR/$TIMESTAMP/results_local.csv" 2>/dev/null
            echo -e "${GREEN}[本机] ✓ 结果已收集${NC}"
        else
            echo -e "${RED}[本机] ✗ 未找到结果文件${NC}"
        fi
    }

    # 收集远程结果
    collect_remote() {
        local host=$1
        sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no \
            "$REMOTE_USER@$host:/tmp/llm_benchmark_results/latest/final_summary.json" \
            "$COLLECT_DIR/$TIMESTAMP/summary_${host}.json" 2>/dev/null
        sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no \
            "$REMOTE_USER@$host:/tmp/llm_benchmark_results/latest/tier_15000/all_results.csv" \
            "$COLLECT_DIR/$TIMESTAMP/results_${host}.csv" 2>/dev/null

        if [ -f "$COLLECT_DIR/$TIMESTAMP/summary_${host}.json" ]; then
            echo -e "${GREEN}[$host] ✓ 结果已收集${NC}"
        else
            echo -e "${RED}[$host] ✗ 未找到结果文件${NC}"
        fi
    }

    collect_local
    for host in "${REMOTE_HOSTS[@]}"; do
        collect_remote "$host" &
    done
    wait

    echo ""
    echo -e "${YELLOW}汇总结果...${NC}"
    aggregate_results
}

# =============================================
# 汇总所有机器结果
# =============================================
aggregate_results() {
    local result_dir="$COLLECT_DIR/$TIMESTAMP"
    local output="$result_dir/cluster_summary.json"
    local csv_merged="$result_dir/all_results_merged.csv"

    # 合并所有 CSV
    cat "$result_dir"/results_*.csv > "$csv_merged" 2>/dev/null
    local total_lines=$(wc -l < "$csv_merged" 2>/dev/null || echo 0)

    # 从各机器 JSON 汇总数据
    local grand_total=0
    local grand_success=0
    local grand_failed=0
    local grand_rate_limited=0
    local grand_timeout=0
    local grand_prompt=0
    local grand_completion=0
    local grand_tokens=0
    local grand_duration=0
    local machine_count=0

    echo ""
    echo -e "${BLUE}【各机器结果】${NC}"
    printf "  %-20s %8s %8s %8s %8s %12s %12s\n" "机器" "总请求" "成功" "失败" "限流" "TPM" "平均延迟"
    printf "  %-20s %8s %8s %8s %8s %12s %12s\n" "----" "------" "----" "----" "----" "---" "------"

    for f in "$result_dir"/summary_*.json; do
        [ -f "$f" ] || continue
        local host=$(basename "$f" | sed 's/summary_//;s/\.json//')

        local total=$(jq -r '.summary.total_requests // 0' "$f" 2>/dev/null)
        local success=$(jq -r '.summary.successful_requests // 0' "$f" 2>/dev/null)
        local failed=$(jq -r '.summary.failed_requests // 0' "$f" 2>/dev/null)
        local rate_limited=$(jq -r '.summary.rate_limited_requests // 0' "$f" 2>/dev/null)
        local timeout=$(jq -r '.summary.timeout_requests // 0' "$f" 2>/dev/null)
        local prompt=$(jq -r '.tokens.prompt // 0' "$f" 2>/dev/null)
        local completion=$(jq -r '.tokens.completion // 0' "$f" 2>/dev/null)
        local tokens=$(jq -r '.tokens.total // 0' "$f" 2>/dev/null)
        local tpm=$(jq -r '.throughput.tpm_total // 0' "$f" 2>/dev/null)
        local duration=$(jq -r '.config.total_duration_seconds // 300' "$f" 2>/dev/null)

        # 从 metrics.json 取延迟（如果有）
        local avg_lat=$(jq -r '.latency.avg // "N/A"' \
            "$(dirname $f)/$(basename $f | sed 's/summary/metrics/')" 2>/dev/null || echo "N/A")

        printf "  %-20s %8s %8s %8s %8s %12s %12s\n" \
            "$host" "$total" "$success" "$failed" "$rate_limited" \
            "$(printf '%.0f' $tpm)" "${avg_lat}s"

        grand_total=$((grand_total + total))
        grand_success=$((grand_success + success))
        grand_failed=$((grand_failed + failed))
        grand_rate_limited=$((grand_rate_limited + rate_limited))
        grand_timeout=$((grand_timeout + timeout))
        grand_prompt=$((grand_prompt + prompt))
        grand_completion=$((grand_completion + completion))
        grand_tokens=$((grand_tokens + tokens))
        grand_duration=$((grand_duration + duration))
        machine_count=$((machine_count + 1))
    done

    # 计算汇总指标
    local avg_duration=$((grand_duration / (machine_count > 0 ? machine_count : 1)))
    local grand_qpm=$(echo "scale=2; $grand_success * 60 / $avg_duration" | bc 2>/dev/null || echo 0)
    local grand_tpm=$(echo "scale=2; $grand_tokens * 60 / $avg_duration" | bc 2>/dev/null || echo 0)
    local grand_input_tpm=$(echo "scale=2; $grand_prompt * 60 / $avg_duration" | bc 2>/dev/null || echo 0)
    local grand_output_tpm=$(echo "scale=2; $grand_completion * 60 / $avg_duration" | bc 2>/dev/null || echo 0)
    local success_rate=0
    [ "$grand_total" -gt 0 ] && success_rate=$(echo "scale=2; $grand_success * 100 / $grand_total" | bc 2>/dev/null || echo 0)

    printf "  %-20s %8s %8s %8s %8s %12s\n" \
        "----" "------" "----" "----" "----" "---"
    printf "  %-20s %8s %8s %8s %8s %12s\n" \
        "合计($machine_count台)" "$grand_total" "$grand_success" "$grand_failed" "$grand_rate_limited" \
        "$(printf '%.0f' $grand_tpm)"

    echo ""
    echo -e "${BLUE}【集群汇总指标】${NC}"
    echo "  参与机器数:    ${machine_count} 台"
    echo "  总请求数:      ${grand_total}"
    echo "  成功率:        ${success_rate}%"
    echo "  集群 QPM:      ${grand_qpm}"
    echo "  集群 TPM 总量: ${grand_tpm}"
    echo "  集群输入 TPM:  ${grand_input_tpm}"
    echo "  集群输出 TPM:  ${grand_output_tpm}"
    echo "  总 Token 消耗: ${grand_tokens}"
    echo ""

    # 写入汇总 JSON
    cat > "$output" << EOF
{
    "test_time": "$(date -Iseconds)",
    "cluster": {
        "machine_count": ${machine_count},
        "concurrency_per_machine": ${CONCURRENCY},
        "total_concurrency": $((CONCURRENCY * machine_count)),
        "duration_seconds": ${avg_duration}
    },
    "summary": {
        "total_requests": ${grand_total},
        "successful_requests": ${grand_success},
        "failed_requests": ${grand_failed},
        "rate_limited_requests": ${grand_rate_limited},
        "timeout_requests": ${grand_timeout},
        "success_rate_percent": ${success_rate}
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
    "result_dir": "${result_dir}"
}
EOF

    echo -e "${GREEN}汇总结果已保存: ${result_dir}/cluster_summary.json${NC}"
    echo -e "${GREEN}合并 CSV 已保存: ${result_dir}/all_results_merged.csv${NC}"
}

# =============================================
# 入口
# =============================================
case "${1:-help}" in
    gen)     cmd_gen ;;
    run)     cmd_run ;;
    status)  cmd_status ;;
    stop)    cmd_stop ;;
    collect) cmd_collect ;;
    *)
        echo "用法: $0 {gen|run|status|stop|collect}"
        echo ""
        echo "  gen      并行在所有机器上生成测试数据"
        echo "  run      并行启动所有机器压测（后台运行）"
        echo "  status   查看各机器压测进度"
        echo "  stop     停止所有机器压测"
        echo "  collect  收集并汇总所有机器结果"
        echo ""
        echo "环境变量:"
        echo "  CONCURRENCY=400      每台机器并发数（5台合计2000）"
        echo "  TOTAL_DURATION=1800  压测时长（秒）"
        echo "  NUM_VARIANTS=500     每档测试数据份数"
        ;;
esac
