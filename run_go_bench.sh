#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="${SCRIPT_DIR}/go_bench"
BIN="${BENCH_DIR}/go_bench"

# 加载统一配置
source "${SCRIPT_DIR}/kong.conf"

CONCURRENCY="${1:-2000}"
DURATION="${2:-1200}"
TIER=15000

mkdir -p "$BENCH_DIR"

cat > "${BENCH_DIR}/main.go" << 'GOEOF'
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	endpoint    string
	authToken   string
	model       string
	dataDir     string
	tier        int
	concurrency int
	duration    int
)

type Result struct {
	Status           string  `json:"status"`
	HTTPCode         int     `json:"http_code"`
	LatencySec       float64 `json:"latency_sec"`
	PromptTokens     int     `json:"prompt_tokens"`
	CompletionTokens int     `json:"completion_tokens"`
	TotalTokens      int     `json:"total_tokens"`
	Error            string  `json:"error,omitempty"`
	APIKeyIndex      string  `json:"api_key_index,omitempty"`
}

var (
	totalRequests   atomic.Int64
	successRequests atomic.Int64
	failedRequests  atomic.Int64
	rateLimited     atomic.Int64
	timeoutRequests atomic.Int64

	totalPromptTokens     atomic.Int64
	totalCompletionTokens atomic.Int64
	totalTokens           atomic.Int64
)

var requestFiles []string
var cachedBodies [][]byte // 预加载的请求体

func loadRequestFiles(dir string, mdl string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") {
			requestFiles = append(requestFiles, filepath.Join(dir, e.Name()))
		}
	}
	sort.Strings(requestFiles)

	// 预加载并注入 model，避免每次请求都读文件+序列化
	cachedBodies = make([][]byte, len(requestFiles))
	for i, f := range requestFiles {
		data, err := os.ReadFile(f)
		if err != nil {
			return fmt.Errorf("read %s: %w", f, err)
		}
		var body map[string]interface{}
		if err := json.Unmarshal(data, &body); err == nil {
			body["model"] = mdl
			data, _ = json.Marshal(body)
		}
		cachedBodies[i] = data
	}
	return nil
}

func getRequestBody(workerID, requestID int) []byte {
	n := len(cachedBodies)
	if n == 0 {
		return nil
	}
	idx := ((workerID - 1) + requestID) % n
	return cachedBodies[idx]
}

func newSharedClient(maxConns int) *http.Client {
	return &http.Client{
		Timeout: 600 * time.Second,
		Transport: &http.Transport{
			DialContext: (&net.Dialer{
				Timeout:   30 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			MaxConnsPerHost:     maxConns,
			MaxIdleConns:        maxConns,
			MaxIdleConnsPerHost: maxConns,
			IdleConnTimeout:     90 * time.Second,
			DisableKeepAlives:   false,
			ForceAttemptHTTP2:   false,
		},
	}
}

type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}
type Choice struct {
	Message Message `json:"message"`
}
type APIResponse struct {
	Usage   Usage   `json:"usage"`
	Choices []Choice `json:"choices"`
	Error   *struct {
		Message string `json:"message"`
	} `json:"error"`
}

func sendRequest(client *http.Client, workerID, requestID int) Result {
	data := getRequestBody(workerID, requestID)
	if data == nil {
		return Result{Status: "failed", Error: "request body not found"}
	}

	start := time.Now()

	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(data))
	if err != nil {
		return Result{Status: "failed", LatencySec: time.Since(start).Seconds(), Error: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+authToken)

	resp, err := client.Do(req)
	latency := time.Since(start).Seconds()

	if err != nil {
		return Result{
			Status:     "timeout",
			LatencySec: latency,
			Error:      err.Error(),
		}
	}
	defer resp.Body.Close()

	bodyBytes, _ := io.ReadAll(resp.Body)

	var apiKeyIndex string
	if h := resp.Header.Get("X-API-Key-Index"); h != "" {
		apiKeyIndex = h
	}

	if resp.StatusCode == 200 {
		var apiResp APIResponse
		if err := json.Unmarshal(bodyBytes, &apiResp); err == nil {
			return Result{
				Status:           "success",
				HTTPCode:         200,
				LatencySec:       latency,
				PromptTokens:     apiResp.Usage.PromptTokens,
				CompletionTokens: apiResp.Usage.CompletionTokens,
				TotalTokens:      apiResp.Usage.TotalTokens,
				APIKeyIndex:      apiKeyIndex,
			}
		}
		return Result{
			Status:     "failed",
			HTTPCode:   200,
			LatencySec: latency,
			Error:      "parse response failed",
		}
	}

	errorMsg := ""
	var apiErr APIResponse
	if json.Unmarshal(bodyBytes, &apiErr) == nil && apiErr.Error != nil {
		errorMsg = apiErr.Error.Message
	}

	status := "failed"
	if resp.StatusCode == 429 {
		status = "rate_limited"
	}

	return Result{
		Status:      status,
		HTTPCode:    resp.StatusCode,
		LatencySec:  latency,
		Error:       errorMsg,
		APIKeyIndex: apiKeyIndex,
	}
}

// 延迟收集器
var (
	latencyMu   sync.Mutex
	latencyData []float64
)

// Round-Robin key 分布收集器
var (
	keyDistMu sync.Mutex
	keyDist   = make(map[string]int64)
)

func collectLatency(lat float64) {
	latencyMu.Lock()
	latencyData = append(latencyData, lat)
	latencyMu.Unlock()
}

func collectKeyIndex(idx string) {
	if idx == "" {
		idx = "unknown"
	}
	keyDistMu.Lock()
	keyDist[idx]++
	keyDistMu.Unlock()
}

func isDialError(errMsg string) bool {
	return strings.Contains(errMsg, "bad file descriptor") ||
		strings.Contains(errMsg, "too many open files") ||
		strings.Contains(errMsg, "connection reset") ||
		strings.Contains(errMsg, "connection refused")
}

func worker(id int, client *http.Client, stopCh <-chan struct{}, wg *sync.WaitGroup) {
	defer wg.Done()
	reqID := 0
	for {
		select {
		case <-stopCh:
			return
		default:
		}

		// 连接级错误自动重试，最多 10 次，不计入统计
		var result Result
		for retry := 0; retry < 10; retry++ {
			select {
			case <-stopCh:
				return
			default:
			}
			result = sendRequest(client, id, reqID)
			if result.Status != "timeout" || !isDialError(result.Error) {
				break
			}
			// 连接错误，指数退避重试: 200ms, 400ms, 800ms, 1.6s, 3.2s...
			backoff := time.Duration(200<<uint(retry)) * time.Millisecond
			if backoff > 5*time.Second {
				backoff = 5 * time.Second
			}
			time.Sleep(backoff)
		}

		totalRequests.Add(1)

		switch result.Status {
		case "success":
			successRequests.Add(1)
			totalPromptTokens.Add(int64(result.PromptTokens))
			totalCompletionTokens.Add(int64(result.CompletionTokens))
			totalTokens.Add(int64(result.TotalTokens))
			collectLatency(result.LatencySec)
			collectKeyIndex(result.APIKeyIndex)
			fmt.Printf("[W%d][R%d] ✓ HTTP %d | %.3fs | in=%d out=%d total=%d | key=%s\n",
				id, reqID, result.HTTPCode, result.LatencySec,
				result.PromptTokens, result.CompletionTokens, result.TotalTokens,
				result.APIKeyIndex)
		case "rate_limited":
			rateLimited.Add(1)
			collectLatency(result.LatencySec)
			fmt.Printf("[W%d][R%d] ⚠ HTTP 429 | %.3fs | %s\n", id, reqID, result.LatencySec, result.Error)
		case "timeout":
			timeoutRequests.Add(1)
			fmt.Printf("[W%d][R%d] ✗ Timeout | %.3fs | %s\n", id, reqID, result.LatencySec, result.Error)
		default:
			failedRequests.Add(1)
			fmt.Printf("[W%d][R%d] ✗ HTTP %d | %.3fs | %s\n",
				id, reqID, result.HTTPCode, result.LatencySec, result.Error)
		}

		reqID++
		if result.Status == "timeout" || result.Status == "failed" {
			time.Sleep(500 * time.Millisecond)
		} else {
			time.Sleep(100 * time.Millisecond)
		}
	}
}

func printSummary(durationSec int, latencies []float64) {
	total := totalRequests.Load()
	success := successRequests.Load()
	failed := failedRequests.Load()
	rl := rateLimited.Load()
	to := timeoutRequests.Load()
	prompt := totalPromptTokens.Load()
	completion := totalCompletionTokens.Load()
	tokens := totalTokens.Load()

	dur := float64(durationSec)
	qpm := float64(success) * 60 / dur
	tpm := float64(tokens) * 60 / dur
	inputTPM := float64(prompt) * 60 / dur
	outputTPM := float64(completion) * 60 / dur

	successRate := 0.0
	if total > 0 {
		successRate = float64(success) * 100 / float64(total)
	}

	sort.Float64s(latencies)
	avgLat := 0.0
	minLat := 0.0
	maxLat := 0.0
	p95Lat := 0.0
	if len(latencies) > 0 {
		sum := 0.0
		for _, l := range latencies {
			sum += l
		}
		avgLat = sum / float64(len(latencies))
		minLat = latencies[0]
		maxLat = latencies[len(latencies)-1]
		p95Idx := int(math.Ceil(float64(len(latencies))*0.95)) - 1
		if p95Idx < 0 {
			p95Idx = 0
		}
		if p95Idx >= len(latencies) {
			p95Idx = len(latencies) - 1
		}
		p95Lat = latencies[p95Idx]
	}

	fmt.Println()
	fmt.Println("============================================================================")
	fmt.Println("                    15K Token 压测 - 最终汇总报告 (Go)")
	fmt.Println("============================================================================")
	fmt.Println()
	fmt.Println("【测试配置】")
	fmt.Printf("  模型:         %s\n", model)
	fmt.Printf("  并发数:       %d\n", concurrency)
	fmt.Printf("  测试时长:     %d 秒 (%.1f 分钟)\n", durationSec, float64(durationSec)/60)
	fmt.Printf("  数据目录:     %s/tier_%d\n", dataDir, tier)
	fmt.Println()
	fmt.Println("【请求统计】")
	fmt.Printf("  总请求:   %d\n", total)
	fmt.Printf("  成功:     %d\n", success)
	fmt.Printf("  失败:     %d\n", failed)
	fmt.Printf("  限流:     %d\n", rl)
	fmt.Printf("  超时:     %d\n", to)
	fmt.Printf("  成功率:   %.2f%%\n", successRate)
	fmt.Println()
	fmt.Println("【延迟统计】")
	fmt.Printf("  平均延迟: %.3fs\n", avgLat)
	fmt.Printf("  最小延迟: %.3fs\n", minLat)
	fmt.Printf("  最大延迟: %.3fs\n", maxLat)
	fmt.Printf("  P95 延迟: %.3fs\n", p95Lat)
	fmt.Println()
	fmt.Println("【吞吐量】")
	fmt.Printf("  QPM (每分钟成功请求数):   %.4f\n", qpm)
	fmt.Printf("  TPM (每分钟 Token 总数):  %.2f\n", tpm)
	fmt.Printf("  输入 TPM (Prompt):       %.2f\n", inputTPM)
	fmt.Printf("  输出 TPM (Completion):   %.2f\n", outputTPM)
	fmt.Println()
	fmt.Println("【Token 消耗】")
	fmt.Printf("  Prompt Tokens:     %d\n", prompt)
	fmt.Printf("  Completion Tokens: %d\n", completion)
	fmt.Printf("  Total Tokens:      %d\n", tokens)
	fmt.Println()
	fmt.Println("============================================================================")

	summary := map[string]interface{}{
		"test_time": time.Now().Format(time.RFC3339),
		"test_type": "15K_go_bench",
		"config": map[string]interface{}{
			"model":       model,
			"concurrency": concurrency,
			"duration":    durationSec,
			"data_dir":    fmt.Sprintf("%s/tier_%d", dataDir, tier),
		},
		"requests": map[string]interface{}{
			"total":    total,
			"success":  success,
			"failed":   failed,
			"rate_limited": rl,
			"timeout":  to,
			"success_rate_percent": strconv.FormatFloat(successRate, 'f', 2, 64),
		},
		"tokens": map[string]interface{}{
			"prompt":     prompt,
			"completion": completion,
			"total":      tokens,
		},
		"latency": map[string]interface{}{
			"avg": strconv.FormatFloat(avgLat, 'f', 3, 64),
			"min": strconv.FormatFloat(minLat, 'f', 3, 64),
			"max": strconv.FormatFloat(maxLat, 'f', 3, 64),
			"p95": strconv.FormatFloat(p95Lat, 'f', 3, 64),
		},
		"throughput": map[string]interface{}{
			"qpm":        strconv.FormatFloat(qpm, 'f', 4, 64),
			"tpm_total":  strconv.FormatFloat(tpm, 'f', 2, 64),
			"tpm_input":  strconv.FormatFloat(inputTPM, 'f', 2, 64),
			"tpm_output": strconv.FormatFloat(outputTPM, 'f', 2, 64),
		},
	}

	jsonFile := fmt.Sprintf("/tmp/llm_benchmark_results_15k/go_bench_%s_summary.json",
		time.Now().Format("20060102_150405"))
	os.MkdirAll(filepath.Dir(jsonFile), 0755)
	if f, err := os.Create(jsonFile); err == nil {
		enc := json.NewEncoder(f)
		enc.SetIndent("", "    ")
		enc.Encode(summary)
		f.Close()
		fmt.Printf("\n详细数据已保存: %s\n", jsonFile)
	}
}

func printKeyDistribution() {
	keyDistMu.Lock()
	defer keyDistMu.Unlock()

	fmt.Println()
	fmt.Println("============================================================================")
	fmt.Println("                    Round-Robin 分布分析")
	fmt.Println("============================================================================")
	fmt.Println()

	if len(keyDist) == 0 {
		fmt.Println("  无数据可分析")
		return
	}

	var total int64
	for _, v := range keyDist {
		total += v
	}

	// 排序 key
	keys := make([]string, 0, len(keyDist))
	for k := range keyDist {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	fmt.Printf("  总成功请求数: %d\n\n", total)
	fmt.Printf("  %-15s %-15s %-15s\n", "Key Index", "请求数", "占比")
	fmt.Printf("  %-15s %-15s %-15s\n", "--------", "------", "----")

	var minCount, maxCount int64
	minCount = math.MaxInt64
	for _, k := range keys {
		c := keyDist[k]
		pct := float64(c) * 100 / float64(total)
		fmt.Printf("  %-15s %-15d %.2f%%\n", k, c, pct)
		if c < minCount {
			minCount = c
		}
		if c > maxCount {
			maxCount = c
		}
	}

	fmt.Println()
	if len(keys) <= 1 {
		fmt.Println("  ⚠️  警告: 只检测到一个 key index，round-robin 可能未生效")
	} else if minCount > 0 {
		ratio := float64(maxCount) / float64(minCount)
		fmt.Printf("  最大/最小比例: %.2f\n", ratio)
		if ratio < 1.5 {
			fmt.Println("  ✅ Round-robin 分布均匀 (比例 < 1.5)")
		} else if ratio < 3.0 {
			fmt.Println("  ⚠️  Round-robin 分布基本均匀 (比例 < 3.0)")
		} else {
			fmt.Println("  ❌ Round-robin 分布不均 (比例 >= 3.0)")
		}
	}
	fmt.Println()
	fmt.Println("============================================================================")
}

func main() {
	endpoint = os.Getenv("KONG_URL") + "/llm/v1/chat/completions"
	authToken = os.Getenv("AUTH_TOKEN")
	model = os.Getenv("MODEL")
	dataDir = os.Getenv("DATA_DIR")
	tier = 15000
	concurrency, _ = strconv.Atoi(os.Getenv("CONCURRENCY"))
	duration, _ = strconv.Atoi(os.Getenv("DURATION"))

	if model == "" {
		model = "glm-5"
	}
	if concurrency == 0 {
		concurrency = 2000
	}
	if duration == 0 {
		duration = 1200
	}
	if dataDir == "" {
		dataDir = "/tmp/llm_benchmark_data"
	}

	tierDir := fmt.Sprintf("%s/tier_%d", dataDir, tier)
	fmt.Printf("加载测试数据: %s\n", tierDir)
	if err := loadRequestFiles(tierDir, model); err != nil {
		fmt.Fprintf(os.Stderr, "加载测试数据失败: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("已加载 %d 个测试数据文件\n", len(requestFiles))
	fmt.Println()

	fmt.Println("============================================================")
	fmt.Println("  15K Token 专项压测 (Go 并发客户端)")
	fmt.Println("============================================================")
	fmt.Printf("  目标: %s\n", endpoint)
	fmt.Printf("  模型: %s\n", model)
	fmt.Printf("  并发: %d workers\n", concurrency)
	fmt.Printf("  时长: %d 秒 (%.1f 分钟)\n", duration, float64(duration)/60)
	fmt.Println("============================================================")
	fmt.Println()

	client := newSharedClient(concurrency + 100)

	stopCh := make(chan struct{})
	var wg sync.WaitGroup

	fmt.Println("启动 workers...")
	rampUp := 120 // 120秒爬坡，每秒启动10个worker，避免TCP连接风暴
	batchSize := concurrency / rampUp
	if batchSize < 1 {
		batchSize = 1
	}

	launched := 0
	for i := 1; i <= concurrency; i++ {
		wg.Add(1)
		go worker(i, client, stopCh, &wg)
		launched++
		if launched%batchSize == 0 && launched < concurrency {
			fmt.Printf("  已启动 %d/%d workers...\n", launched, concurrency)
			time.Sleep(time.Second)
		}
	}
	fmt.Printf("全部 %d 个 worker 已启动 (%ds 爬坡)\n", concurrency, rampUp)
	fmt.Println("────────────────────────────────────────────────────────────")
	fmt.Println()

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	startTime := time.Now()
	done := time.After(time.Duration(duration) * time.Second)

	for {
		select {
		case <-done:
			close(stopCh)
			wg.Wait()
			elapsed := int(time.Since(startTime).Seconds())
			fmt.Printf("\n────────────────────────────────────────────────────────────\n")
			fmt.Printf("压测完成！总耗时: %d 秒\n", elapsed)
			latencyMu.Lock()
			lats := make([]float64, len(latencyData))
			copy(lats, latencyData)
			latencyMu.Unlock()
			printSummary(elapsed, lats)
			printKeyDistribution()
			return
		case <-ticker.C:
			elapsed := int(time.Since(startTime).Seconds())
			fmt.Printf("\n[%d/%ds] 总请求:%d | 成功:%d | 失败:%d | 限流:%d | 超时:%d\n",
				elapsed, duration,
				totalRequests.Load(), successRequests.Load(),
				failedRequests.Load(), rateLimited.Load(), timeoutRequests.Load())
		}
	}
}
GOEOF

echo "编译 Go 压测客户端..."
cd "$BENCH_DIR"
go mod init go_bench 2>/dev/null || true
go mod tidy 2>/dev/null || true
go build -o "$BIN" main.go

echo "启动压测: ${CONCURRENCY} 并发, ${DURATION} 秒, 模型=${MODEL}"
echo ""

export KONG_URL AUTH_TOKEN MODEL DATA_DIR CONCURRENCY DURATION
exec "$BIN"
