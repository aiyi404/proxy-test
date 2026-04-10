#!/bin/bash

#######################################
# LLM 压测数据生成器
# 为每个档位生成多份不同的请求体，避免 KV Cache
#######################################

set -e

# 加载统一配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/kong.conf"

NUM_VARIANTS="${NUM_VARIANTS:-200}"

# 档位配置
declare -a TOKEN_TIERS=(1000 5000 10000 15000 30000)
declare -a TIER_NAMES=("1K" "5K" "10K" "15K" "30K")

# 输出目录
DATA_DIR="${DATA_DIR:-/tmp/llm_benchmark_data}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 多种代码片段模板（用于生成不同的 prompt）
declare -a CODE_TEMPLATES=(
'function calculateTotal(items) {
    var total = 0;
    for (var i = 0; i < items.length; i++) {
        total = total + items[i].price * items[i].quantity;
    }
    return total;
}'

'async function fetchUserData(userId) {
    const response = await fetch("/api/users/" + userId);
    const data = await response.json();
    return data;
}'

'class ShoppingCart {
    constructor() {
        this.items = [];
    }
    addItem(item) {
        this.items.push(item);
    }
    getTotal() {
        let sum = 0;
        this.items.forEach(item => sum += item.price);
        return sum;
    }
}'

'def process_data(records):
    results = []
    for record in records:
        if record["status"] == "active":
            processed = {
                "id": record["id"],
                "value": record["amount"] * 1.1
            }
            results.append(processed)
    return results'

'func handleRequest(w http.ResponseWriter, r *http.Request) {
    data := r.URL.Query().Get("data")
    result := processData(data)
    json.NewEncoder(w).Encode(result)
}'

'public List<User> filterActiveUsers(List<User> users) {
    List<User> active = new ArrayList<>();
    for (User user : users) {
        if (user.isActive()) {
            active.add(user);
        }
    }
    return active;
}'

'SELECT u.id, u.name, COUNT(o.id) as order_count
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
WHERE u.created_at > NOW() - INTERVAL 30 DAY
GROUP BY u.id
HAVING order_count > 5
ORDER BY order_count DESC;'

'const validateInput = (input) => {
    if (!input || typeof input !== "object") {
        throw new Error("Invalid input");
    }
    const required = ["name", "email", "age"];
    for (const field of required) {
        if (!input[field]) {
            throw new Error("Missing field: " + field);
        }
    }
    return true;
};'
)

# 多种任务类型
declare -a TASK_TYPES=(
    "Review this code for security vulnerabilities and suggest fixes"
    "Optimize this code for better performance"
    "Refactor this code to follow SOLID principles"
    "Add comprehensive error handling to this code"
    "Convert this code to TypeScript with proper types"
    "Write unit tests for this code using Jest"
    "Add detailed documentation and comments"
    "Identify potential memory leaks and fix them"
    "Make this code more readable and maintainable"
    "Add input validation and sanitization"
)

# 生成随机 prompt
generate_unique_prompt() {
    local target_tokens=$1
    local variant_id=$2
    
    # 选择随机代码模板和任务
    local code_idx=$((RANDOM % ${#CODE_TEMPLATES[@]}))
    local task_idx=$((RANDOM % ${#TASK_TYPES[@]}))
    local code="${CODE_TEMPLATES[$code_idx]}"
    local task="${TASK_TYPES[$task_idx]}"
    
    # 基础 prompt 带唯一标识
    local base_prompt="Request ID: ${variant_id}-$(date +%s%N)

Task: ${task}

Context: This is part of a large-scale application handling user data processing, authentication, and real-time updates. The codebase follows microservices architecture with multiple teams working on different components.

Code to analyze:
\`\`\`
${code}
\`\`\`

Additional requirements:
- Consider scalability for 10M+ users
- Ensure thread safety for concurrent access
- Follow company coding standards
- Consider backwards compatibility
- Add proper logging for debugging

Please provide detailed analysis covering:
1. Code quality assessment
2. Potential bugs and edge cases
3. Performance bottlenecks
4. Security considerations
5. Recommended improvements with code examples
6. Test cases to add

"

    # 扩展到目标大小
    local target_chars=$((target_tokens * 4))
    local current_chars=${#base_prompt}
    
    # 添加更多上下文直到达到目标大小
    local filler_block="
Additional context for comprehensive analysis:
- The application processes approximately 100,000 requests per second during peak hours
- Data consistency is critical as financial transactions are involved
- The system must maintain 99.99% uptime SLA
- Integration with legacy systems requires careful handling of edge cases
- Performance metrics are monitored using Prometheus and Grafana
- The deployment uses Kubernetes with auto-scaling based on CPU and memory usage
- Database operations use connection pooling with a maximum of 100 connections
- Redis is used for caching with a TTL of 300 seconds for most frequently accessed data
- The API follows RESTful conventions with proper versioning in the URL path
- Authentication uses JWT tokens with refresh token rotation every 7 days
- Rate limiting is implemented at 1000 requests per minute per user
- All sensitive data is encrypted at rest using AES-256 encryption
- Logs are aggregated using ELK stack for centralized monitoring
- Error tracking uses Sentry for real-time alerts on production issues
- Code review process requires at least two approvals before merging
- Unit test coverage must be above 80% for all new code changes
- Integration tests run in a staging environment before production deployment
- Feature flags are used for gradual rollout of new functionality
- Database migrations are handled using Flyway with versioned scripts
- API documentation is auto-generated from OpenAPI specifications

"
    
    local prompt="$base_prompt"
    while [ ${#prompt} -lt $target_chars ]; do
        prompt+="$filler_block"
        # 添加一些随机性
        prompt+="Analysis checkpoint ${RANDOM}: Reviewing code section... "
    done
    
    # 截断到目标大小
    echo "${prompt:0:$target_chars}"
}

# 构建请求 JSON
build_request_json() {
    local tier=$1
    local variant_id=$2
    local output_file=$3
    local prompt_file="${DATA_DIR}/temp_prompt_$$.txt"
    
    # 生成唯一 prompt
    generate_unique_prompt "$tier" "$variant_id" > "$prompt_file"
    
    # System prompt
    local system_prompt="You are an expert software engineer with 15+ years of experience. Provide thorough, actionable code review feedback. Request context: variant=${variant_id}, timestamp=$(date +%s)"
    
    # 用 jq 构建 JSON
    jq -n \
        --arg model "$MODEL" \
        --arg system "$system_prompt" \
        --rawfile user "$prompt_file" \
        --argjson max_tokens "$MAX_TOKENS" \
        '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}], max_tokens: $max_tokens, temperature: 0.7}' \
        > "$output_file" 2>/dev/null
    
    rm -f "$prompt_file"
    
    [ -s "$output_file" ]
}

# 生成单个档位的所有变体
generate_tier_data() {
    local tier=$1
    local tier_name=$2
    local tier_dir="${DATA_DIR}/tier_${tier}"
    
    mkdir -p "$tier_dir"
    
    echo -e "${BLUE}生成 ${tier_name} tokens 档位数据 (${NUM_VARIANTS} 份)...${NC}"
    
    local success_count=0
    local fail_count=0
    
    for i in $(seq 1 $NUM_VARIANTS); do
        local output_file="${tier_dir}/request_${i}.json"
        
        if build_request_json "$tier" "$i" "$output_file"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
        
        # 进度显示
        if [ $((i % 20)) -eq 0 ]; then
            printf "\r  进度: %d/%d" "$i" "$NUM_VARIANTS"
        fi
    done
    
    echo ""
    
    if [ $success_count -gt 0 ]; then
        local sample_size=$(wc -c < "${tier_dir}/request_1.json" | tr -d '[:space:]')
        echo -e "  ${GREEN}✓ 成功: ${success_count}/${NUM_VARIANTS}, 单个文件约 ${sample_size} bytes${NC}"
    fi
    
    if [ $fail_count -gt 0 ]; then
        echo -e "  ${RED}✗ 失败: ${fail_count}${NC}"
    fi
    
    return 0
}

# 主函数
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         LLM 压测数据生成器                                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 检查依赖
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq 未安装${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}【配置】${NC}"
    echo "  模型:       ${MODEL}"
    echo "  max_tokens: ${MAX_TOKENS}"
    echo "  每档变体数: ${NUM_VARIANTS}"
    echo "  档位:       ${TIER_NAMES[*]}"
    echo "  输出目录:   ${DATA_DIR}"
    echo ""
    
    # 清理旧数据
    if [ -d "$DATA_DIR" ]; then
        echo -e "${YELLOW}清理旧数据...${NC}"
        rm -rf "$DATA_DIR"
    fi
    mkdir -p "$DATA_DIR"
    
    # 生成各档位数据
    local start_time=$(date +%s)
    
    for idx in "${!TOKEN_TIERS[@]}"; do
        generate_tier_data "${TOKEN_TIERS[$idx]}" "${TIER_NAMES[$idx]}"
    done
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    
    echo ""
    echo -e "${GREEN}数据生成完成！耗时: ${elapsed} 秒${NC}"
    echo ""
    
    # 统计
    echo -e "${BLUE}【生成结果】${NC}"
    local total_files=0
    local total_size=0
    
    for tier in "${TOKEN_TIERS[@]}"; do
        local tier_dir="${DATA_DIR}/tier_${tier}"
        if [ -d "$tier_dir" ]; then
            local count=$(ls -1 "${tier_dir}"/*.json 2>/dev/null | wc -l | tr -d '[:space:]')
            local size=$(du -sh "$tier_dir" 2>/dev/null | cut -f1)
            echo "  tier_${tier}/: ${count} 文件, ${size}"
            total_files=$((total_files + count))
        fi
    done
    
    total_size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)
    echo ""
    echo "  总计: ${total_files} 文件, ${total_size}"
    echo ""
    echo -e "数据目录: ${CYAN}${DATA_DIR}${NC}"
    echo ""
    echo "运行压测命令:"
    echo -e "  ${GREEN}./benchmark_multi_tier.sh${NC}"
}

# 帮助
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "生成 LLM 压测数据（每个档位多份不同请求，避免 KV Cache）"
    echo ""
    echo "Options:"
    echo "  -h, --help       显示帮助"
    echo "  -n, --num        每个档位生成的变体数量 (默认: 200)"
    echo "  -m, --model      模型名称 (默认: glm-5)"
    echo "  -t, --tokens     max_tokens (默认: 1000)"
    echo "  -o, --output     输出目录 (默认: /tmp/llm_benchmark_data)"
    echo ""
    echo "Examples:"
    echo "  $0                      # 默认配置"
    echo "  $0 -n 500              # 每档位生成 500 份"
    echo "  $0 -o ./test_data      # 指定输出目录"
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -n|--num) NUM_VARIANTS="$2"; shift 2 ;;
        -m|--model) MODEL="$2"; shift 2 ;;
        -t|--tokens) MAX_TOKENS="$2"; shift 2 ;;
        -o|--output) DATA_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

main
