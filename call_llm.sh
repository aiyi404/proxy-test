#!/bin/bash

#######################################
# 一次性调用大模型服务脚本
# 通过 Kong 网关调用 LLM Chat Completions API
#######################################

# 加载统一配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/kong.conf"

ENDPOINT="${KONG_URL}/llm/v1/chat/completions"

# 用户输入 (可通过命令行参数或环境变量传入)
USER_MESSAGE="${1:-你好，请介绍一下你自己。}"

# 是否流式输出
STREAM="${STREAM:-false}"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo "Usage: $0 [OPTIONS] [MESSAGE]"
    echo ""
    echo "一次性调用大模型服务"
    echo ""
    echo "Arguments:"
    echo "  MESSAGE              要发送的消息内容 (默认: '你好，请介绍一下你自己。')"
    echo ""
    echo "Options:"
    echo "  -h, --help           显示帮助"
    echo "  -m, --model MODEL    模型名称 (默认: glm-5)"
    echo "  -t, --max-tokens N   最大输出 token 数 (默认: 1000)"
    echo "  -T, --temperature N  温度参数 (默认: 0.7)"
    echo "  -s, --stream         启用流式输出"
    echo "  -f, --file FILE      从文件读取消息内容"
    echo "  -S, --system MSG     设置 system 消息"
    echo "  -r, --raw            只输出原始 JSON 响应"
    echo "  -v, --verbose        显示详细信息 (请求体、Token 用量等)"
    echo ""
    echo "Environment Variables:"
    echo "  KONG_HOST            Kong 网关地址 (默认: 8.158.0.107)"
    echo "  KONG_PORT            Kong 网关端口 (默认: 80)"
    echo "  AUTH_TOKEN           认证 Token"
    echo "  MODEL                模型名称"
    echo "  MAX_TOKENS           最大输出 token 数"
    echo "  TEMPERATURE          温度参数"
    echo ""
    echo "Examples:"
    echo "  $0 '什么是机器学习？'"
    echo "  $0 -m qwen-coder-plus '写一个快速排序'"
    echo "  $0 -s '逐步解释量子计算'"
    echo "  $0 -S '你是一个专业的翻译助手' '请将以下内容翻译成英文：你好世界'"
    echo "  $0 -f prompt.txt"
    echo "  $0 -v -t 2000 '详细解释 Transformer 架构'"
    echo "  echo '你好' | $0 -f -"
}

# 默认值
SYSTEM_MESSAGE=""
RAW_MODE=false
VERBOSE=false
INPUT_FILE=""

# 解析参数
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -m|--model) MODEL="$2"; shift 2 ;;
        -t|--max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        -T|--temperature) TEMPERATURE="$2"; shift 2 ;;
        -s|--stream) STREAM="true"; shift ;;
        -f|--file) INPUT_FILE="$2"; shift 2 ;;
        -S|--system) SYSTEM_MESSAGE="$2"; shift 2 ;;
        -r|--raw) RAW_MODE=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -*) echo "Unknown option: $1"; show_help; exit 1 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

# 获取用户消息
if [ -n "$INPUT_FILE" ]; then
    if [ "$INPUT_FILE" = "-" ]; then
        USER_MESSAGE=$(cat)
    elif [ -f "$INPUT_FILE" ]; then
        USER_MESSAGE=$(cat "$INPUT_FILE")
    else
        echo -e "${RED}文件不存在: ${INPUT_FILE}${NC}"
        exit 1
    fi
elif [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
    USER_MESSAGE="${POSITIONAL_ARGS[*]}"
fi

# 检查依赖
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq 未安装，请先安装 jq${NC}"
    echo "  brew install jq  (macOS)"
    echo "  apt install jq   (Ubuntu)"
    exit 1
fi

# 构建 messages 数组
MESSAGES="[]"
if [ -n "$SYSTEM_MESSAGE" ]; then
    MESSAGES=$(jq -n --arg msg "$SYSTEM_MESSAGE" '[{"role": "system", "content": $msg}]')
fi
MESSAGES=$(echo "$MESSAGES" | jq --arg msg "$USER_MESSAGE" '. + [{"role": "user", "content": $msg}]')

# 构建请求体
REQUEST_BODY=$(jq -n \
    --arg model "$MODEL" \
    --argjson max_tokens "$MAX_TOKENS" \
    --argjson temperature "$TEMPERATURE" \
    --argjson stream "$STREAM" \
    --argjson messages "$MESSAGES" \
    '{
        "model": $model,
        "messages": $messages,
        "max_tokens": $max_tokens,
        "temperature": $temperature,
        "stream": $stream
    }')

# 显示请求信息
if [ "$RAW_MODE" != true ]; then
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  LLM 服务调用${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}端点:${NC}  ${ENDPOINT}"
    echo -e "${YELLOW}模型:${NC}  ${MODEL}"
    echo -e "${YELLOW}流式:${NC}  ${STREAM}"
    echo ""

    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}请求体:${NC}"
        echo "$REQUEST_BODY" | jq .
        echo ""
    fi

    echo -e "${YELLOW}用户消息:${NC}"
    echo "$USER_MESSAGE"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}请求中...${NC}"
    echo ""
fi

# 发送请求
START_TIME=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')

if [ "$STREAM" = "true" ]; then
    # 流式输出模式
    if [ "$RAW_MODE" = true ]; then
        curl -s -N \
            -X POST "${ENDPOINT}" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${AUTH_TOKEN}" \
            -d "$REQUEST_BODY" \
            --connect-timeout 30 \
            --max-time 600
    else
        echo -e "${GREEN}回复:${NC}"
        curl -s -N \
            -X POST "${ENDPOINT}" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${AUTH_TOKEN}" \
            -d "$REQUEST_BODY" \
            --connect-timeout 30 \
            --max-time 600 | while IFS= read -r line; do
            # 解析 SSE 格式
            if [[ "$line" == data:* ]]; then
                data="${line#data: }"
                if [ "$data" = "[DONE]" ]; then
                    echo ""
                    continue
                fi
                # 提取 content delta
                content=$(echo "$data" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
                if [ -n "$content" ]; then
                    printf "%s" "$content"
                fi
            fi
        done
        echo ""
    fi
else
    # 非流式模式
    RESP_FILE=$(mktemp)
    HTTP_CODE=$(curl -s -w "%{http_code}" \
        -o "$RESP_FILE" \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -d "$REQUEST_BODY" \
        --connect-timeout 30 \
        --max-time 600)

    END_TIME=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
    LATENCY=$(echo "scale=3; ($END_TIME - $START_TIME) / 1000" | bc 2>/dev/null || echo "N/A")

    RESPONSE=$(cat "$RESP_FILE")
    rm -f "$RESP_FILE"

    if [ "$RAW_MODE" = true ]; then
        echo "$RESPONSE"
        exit 0
    fi

    if [ "$HTTP_CODE" = "200" ]; then
        # 提取回复内容
        CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "无回复内容"' 2>/dev/null)
        FINISH_REASON=$(echo "$RESPONSE" | jq -r '.choices[0].finish_reason // "unknown"' 2>/dev/null)

        # 提取 Token 用量
        PROMPT_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens // "N/A"' 2>/dev/null)
        COMPLETION_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // "N/A"' 2>/dev/null)
        TOTAL_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.total_tokens // "N/A"' 2>/dev/null)

        echo -e "${GREEN}回复:${NC}"
        echo "$CONTENT"
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}状态:${NC}      HTTP ${HTTP_CODE} ✓"
        echo -e "${YELLOW}耗时:${NC}      ${LATENCY}s"
        echo -e "${YELLOW}结束原因:${NC}  ${FINISH_REASON}"
        echo -e "${YELLOW}Token 用量:${NC}"
        echo -e "  Prompt:     ${PROMPT_TOKENS}"
        echo -e "  Completion: ${COMPLETION_TOKENS}"
        echo -e "  Total:      ${TOTAL_TOKENS}"

        if [ "$VERBOSE" = true ]; then
            echo ""
            echo -e "${YELLOW}完整响应:${NC}"
            echo "$RESPONSE" | jq .
        fi
    else
        echo -e "${RED}请求失败! HTTP ${HTTP_CODE}${NC}"
        echo ""
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // .message // .error // "Unknown error"' 2>/dev/null)
        echo -e "${RED}错误信息:${NC} ${ERROR_MSG}"

        if [ "$VERBOSE" = true ]; then
            echo ""
            echo -e "${YELLOW}完整响应:${NC}"
            echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
        fi
        exit 1
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi
