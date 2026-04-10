## **1. 需求背景**

当前 Kong 网关通过环境变量中的单个 API Key 访问阿里云百炼平台。压测表明：

- 单 API Key 的 TPM 限额约 100 万 (glm-5)
- 400+ 并发时触发配额超限 (429)，成功率降至 ~85%
- 需要支持多 API Key 轮转，将流量均匀分配到多个 Key，突破单 Key 配额

## **2. 插件概述**


| **属性**   | **值**                                     |
| -------- | ----------------------------------------- |
| **插件名称** | `ai-proxy-advanced`                       |
| **优先级**  | 769 (在 ai-proxy 770 之前执行)                 |
| **运行阶段** | `access` + `header_filter`                |
| **依赖**   | 环境变量 `RDS_PG_API_KEY_LIST` 或 kong.yaml 配置 |


## **3. 配置方式**

### **3.1 环境变量 (fallback)**


| **环境变量**                  | **必填** | **说明**                   |
| ------------------------- | ------ | ------------------------ |
| `RDS_PG_API_KEY_LIST`     | ✅      | 逗号分隔的 API Key 列表         |
| `RDS_PG_API_KEY_STRATEGY` | ✅      | 轮转策略，当前仅支持 `round-robin` |


### **3.2 kong.yaml 配置 (优先，覆盖环境变量)**

```yaml
plugins:
  - name: ai-proxy-advanced
    config:
      rds_pg_api_key_list: "sk-key1,sk-key2,sk-key3"
      rds_pg_api_key_strategy: "round-robin"

```

## **4. 架构设计**

```
Client Request
    ↓
[ai-proxy-advanced] (769)
    ├── access: 替换 Authorization header
    ├── kong.ctx.plugin.key_index 存储索引
    ↓
[ai-proxy] (770)
    ├── 使用替换后的 key 转发
    ↓
Upstream (百炼)
    ↓
[ai-proxy-advanced] (header_filter)
    ├── 设置 X-API-Key-Index 响应头
    ↓
Client Response

```

## **5. 轮转机制**

```
全局共享计数器 (ngx.shared.dict:incr)
    ↓
Worker 1: 请求 1 → key[1%N] → 请求 4 → key[4%N]
Worker 2: 请求 2 → key[2%N] → 请求 5 → key[5%N]
Worker 3: 请求 3 → key[3%N] → 请求 6 → key[6%N]

```

`ngx.shared.dict:incr()` 原子递增 + 取模，保证多 Worker 均匀分配。

## **6. 关键配置**

### **6.1 Nginx 模板 (**`kong/templates/nginx_kong.lua`**)**

```lua
env RDS_PG_API_KEY_LIST;
env RDS_PG_API_KEY_STRATEGY;
lua_shared_dict kong_ai_proxy_advanced 128k;

```

### **6.2 插件注册 (**`kong/constants.lua`**)**

```lua
"ai-proxy-advanced",

```

### **6.3 Dockerfile**

```dockerfile
ENV KONG_PLUGINS="bundled,ai-proxy-advanced"

COPY kong/plugins/ai-proxy-advanced/handler.lua /usr/local/share/lua/5.1/kong/plugins/ai-proxy-advanced/handler.lua
COPY kong/plugins/ai-proxy-advanced/schema.lua /usr/local/share/lua/5.1/kong/plugins/ai-proxy-advanced/schema.lua

```

### **6.4 docker-compose 环境变量**

```yaml
environment:
  RDS_PG_API_KEY_LIST: "sk-key1,sk-key2,sk-key3"
  RDS_PG_API_KEY_STRATEGY: round-robin

```

## **7. 性能分析**


| **操作**                 | **耗时**       |
| ---------------------- | ------------ |
| `os.getenv()` (cached) | ~0 (1s 检查一次) |
| `dict:incr()` + `%`    | <0.01ms      |
| `set_header()`         | <0.01ms      |
| **总开销**                | **<0.02ms**  |


## **8. 排查命令**

```bash
docker exec kong-gateway env | grep RDS_PG_API_KEY
tail -f /usr/local/kong/logs/error.log | grep ai-proxy-advanced
```

