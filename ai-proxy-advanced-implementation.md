## **1. 需求背景**

单 API Key 在 400+ 并发时触发上游 429 限额，成功率 ~85%。通过多 Key 轮转均匀分配流量，突破单 Key 配额。

## **2. 文件结构**

```
kong/plugins/ai-proxy-advanced/
├── handler.lua  # 主逻辑 (priority 769)
└── schema.lua   # 配置 Schema

```

## **3. handler.lua 核心实现**

```lua
local ngx_shared = ngx.shared
local string_gmatch = string.gmatch
local string_gsub = string.gsub

local SHM_NAME = "kong_ai_proxy_advanced"
local COUNTER_KEY = "apikey_index"

-- Per-worker key cache
local cached_keys = nil
local cached_key_count = 0
local last_env_check = 0

local function ensure_keys_cached(conf)
  local now = ngx.now()
  if cached_keys and (now - last_env_check < 1.0) then return end
  -- re-read env/config, compare, update cache
end

local function get_next_key_index(key_count)
  local dict = ngx_shared[SHM_NAME]
  if not dict then return 0 end
  local newval, err = dict:incr(COUNTER_KEY, 1, 0)
  if err or not newval then return 0 end
  return newval % key_count
end

-- access: replace Authorization header
function AiProxyAdvancedPlugin:access(conf)
  -- conf fields > env vars
  -- cache keys, get index, set_header
end

-- header_filter: mark response with X-API-Key-Index
function AiProxyAdvancedPlugin:header_filter(conf)
  local key_index = kong.ctx.plugin.key_index
  if key_index ~= nil then
    ngx.header["X-API-Key-Index"] = tostring(key_index)
  end
end

```

## **4. 关键修改清单**

### **4.1 kong/constants.lua**

```lua
"ai-proxy-advanced",

```

### **4.2 kong/templates/nginx_kong.lua**

```lua
env RDS_PG_API_KEY_LIST;
env RDS_PG_API_KEY_STRATEGY;
lua_shared_dict kong_ai_proxy_advanced 128k;

```

### **4.3 Dockerfile**

```dockerfile
ENV KONG_PLUGINS="bundled,ai-proxy-advanced"
COPY kong/plugins/ai-proxy-advanced/handler.lua /usr/local/share/lua/5.1/kong/plugins/ai-proxy-advanced/handler.lua
COPY kong/plugins/ai-proxy-advanced/schema.lua /usr/local/share/lua/5.1/kong/plugins/ai-proxy-advanced/schema.lua

```

### **4.4 kong.yaml**

```yaml
plugins:
  - name: ai-proxy
  - name: ai-proxy-advanced

```

### **4.5 容器环境变量**

```yaml
environment:
  RDS_PG_API_KEY_LIST: "sk-key1,sk-key2"
  RDS_PG_API_KEY_STRATEGY: round-robin

```

## **5. 踩坑记录**

### **Bug 1: set_header 缺失**

**现象**: 插件加载但限流率无改善 **根因**: 构建 auth_value 后未调用 `kong.service.request.set_header()` **修复**: 补上 `set_header()`

### **Bug 2: Nginx 不传环境变量**

**现象**: `os.getenv()` 返回 nil **修复**: `nginx_kong.lua` 添加 `env RDS_PG_API_KEY_LIST; env RDS_PG_API_KEY_STRATEGY;`

### **Bug 3: 插件未挂载到路由**

**修复**: kong.yaml Service plugins 数组添加 `- name: ai-proxy-advanced`

### **Bug 4: key[0] 分配堆积**

**现象**: 第一个 key 分到大量请求 **根因**: `dict:set(0)` 重置时，高并发下多请求同时拿到 index 0 **修复**: `newval % key_count` 取模代替重置

### **Bug 5: 每请求** `os.getenv()` **+ 字符串解析**

**现象**: 高 QPS 下 CPU 开销大 **修复**: per-worker 缓存，1s 检查一次环境变量变化

### **Bug 6: 每请求 WARN 日志**

**现象**: 磁盘 I/O 阻塞 worker **修复**: 移除每请求日志，改为 `init_worker` 一次性启动日志

## **6. 排查命令**

```bash
docker exec kong-gateway env | grep RDS_PG_API_KEY
tail -f /usr/local/kong/logs/error.log | grep ai-proxy-advanced
```

