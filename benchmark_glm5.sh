#!/bin/bash

#######################################
# Coding Agent 极限压测脚本
# 模拟 30K tokens 输入 / 3K tokens 输出
#######################################

# 加载统一配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/kong.conf"

ENDPOINT="${KONG_URL}/llm/v1/chat/completions"

# 压测参数
CONCURRENCY="${CONCURRENCY:-3}"
DURATION="${DURATION:-120}"
MAX_TOKENS="${MAX_TOKENS:-3000}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 临时目录
RESULT_DIR="/tmp/glm5_benchmark_$$"
mkdir -p "$RESULT_DIR"

cleanup() { rm -rf "$RESULT_DIR"; }
trap cleanup EXIT

# =============================================
# 构建请求体 JSON 文件（启动时预生成，避免运行时 shell 问题）
# =============================================
build_request_files() {
    echo -e "${YELLOW}正在构建请求体...${NC}"

    # --- 写 system prompt 到文件 ---
    cat > "${RESULT_DIR}/system_prompt.txt" << 'SYSTEM_EOF'
You are an expert software engineer and coding assistant. You must follow these rules strictly when writing or reviewing code:

## Code Quality Standards
1. Write clean, maintainable, production-ready code
2. Follow SOLID principles: Single Responsibility, Open-Closed, Liskov Substitution, Interface Segregation, Dependency Inversion
3. Use meaningful variable and function names following language conventions
4. Add proper error handling with specific exception types
5. Write comprehensive JSDoc or docstring comments for public APIs
6. Prefer composition over inheritance
7. Keep functions under 20 lines, classes under 200 lines
8. Use early returns to reduce nesting depth

## Architecture Patterns
1. Follow Clean Architecture and Hexagonal Architecture principles
2. Separate business logic from infrastructure concerns
3. Use dependency injection for testability
4. Implement repository pattern for data access layer
5. Use factory pattern for complex object creation
6. Apply strategy pattern for interchangeable algorithms
7. Use observer pattern for event-driven communication
8. Implement CQRS for complex read/write separation

## TypeScript and JavaScript Conventions
1. Use TypeScript strict mode with no-any rule
2. Prefer interfaces over type aliases for object shapes
3. Use enum for finite sets of constants
4. Prefer async/await over raw promises and callbacks
5. Use optional chaining and nullish coalescing operators
6. Avoid type assertions, use type guards instead
7. Use readonly for immutable properties
8. Prefer const over let, never use var
9. Use barrel exports for clean module organization
10. Implement proper generic types for reusable utilities

## React and Frontend Conventions
1. Use functional components with hooks exclusively
2. Implement proper error boundaries for graceful error handling
3. Memoize expensive computations with useMemo and useCallback
4. Use custom hooks to extract reusable stateful logic
5. Follow container and presentational component pattern
6. Implement proper loading states and skeleton screens
7. Use React.lazy and Suspense for code splitting
8. Follow WCAG 2.1 accessibility guidelines strictly
9. Use CSS Modules or styled-components for scoped styling
10. Implement optimistic UI updates for better user experience

## Python Conventions
1. Follow PEP 8 style guide strictly
2. Use type hints for all function parameters and return types
3. Use dataclasses or Pydantic models for data structures
4. Prefer list comprehensions over map and filter
5. Use context managers for resource management
6. Implement dunder methods for custom classes
7. Use abc.ABC for abstract base classes
8. Follow the Zen of Python principles
9. Use pathlib for file path operations
10. Implement proper logging instead of print statements

## Go Conventions
1. Follow effective Go guidelines
2. Use interfaces for abstraction, keep them small (1-3 methods)
3. Handle errors explicitly, never panic in library code
4. Use goroutines and channels for concurrency
5. Prefer table-driven tests with subtests
6. Use context.Context for cancellation and timeouts
7. Follow standard project layout with cmd, internal, and pkg directories
8. Use structured logging with slog
9. Implement graceful shutdown for all servers
10. Use go generate for code generation

## Database Best Practices
1. Use parameterized queries to prevent SQL injection
2. Implement proper indexing strategy based on query patterns
3. Use database migrations for all schema changes
4. Implement connection pooling with proper limits
5. Use transactions for atomic operations
6. Implement optimistic locking for concurrent access
7. Use read replicas for read-heavy workloads
8. Implement proper backup and recovery procedures

## API Design Principles
1. Follow RESTful conventions with proper HTTP methods and status codes
2. Version APIs using URL path prefix
3. Use consistent error response format with error codes
4. Implement cursor-based pagination for list endpoints
5. Use proper authentication with JWT or OAuth2
6. Rate limit all public endpoints
7. Document with OpenAPI and Swagger specification
8. Implement request validation and sanitization
9. Use HATEOAS for discoverability
10. Implement proper CORS configuration

## Testing Requirements
1. Write unit tests with at least 80 percent code coverage
2. Use AAA pattern: Arrange, Act, Assert
3. Mock external dependencies properly
4. Write integration tests for critical user paths
5. Use test fixtures and factories for test data
6. Test edge cases and error scenarios thoroughly
7. Use property-based testing for complex logic
8. Implement end-to-end tests for critical workflows
9. Use snapshot testing for UI components
10. Maintain test independence and isolation

## Security Best Practices
1. Validate and sanitize all user inputs
2. Use HTTPS for all communications
3. Implement proper CORS configuration
4. Use environment variables for secrets and credentials
5. Implement rate limiting and request throttling
6. Use Content Security Policy headers
7. Implement audit logging for sensitive operations
8. Use prepared statements for database queries
9. Implement proper session management
10. Follow OWASP Top 10 guidelines

## Performance Optimization
1. Implement caching strategy with Redis or Memcached
2. Use lazy loading for expensive resources
3. Optimize database queries to avoid N+1 problems
4. Use pagination for large datasets
5. Implement request batching where appropriate
6. Use streaming for large file operations
7. Profile and optimize hot code paths
8. Use CDN for static assets
9. Implement database query result caching
10. Use connection pooling for external services

## DevOps and CI/CD
1. Use Docker multi-stage builds for smaller images
2. Implement health check endpoints
3. Use structured logging in JSON format
4. Implement graceful shutdown handling
5. Use feature flags for gradual rollouts
6. Monitor with metrics using Prometheus and Grafana
7. Implement distributed tracing with OpenTelemetry
8. Use semantic versioning for releases
9. Implement blue-green or canary deployments
10. Automate security scanning in CI pipeline
SYSTEM_EOF

    # --- 写 3 个 user prompt 到文件 ---
    cat > "${RESULT_DIR}/user_prompt_0.txt" << 'USER0_EOF'
I need you to design and implement a complete authentication and authorization microservice using TypeScript with the following requirements:

1. User Registration with email verification flow
2. Login with JWT access token and refresh token rotation
3. Role-based access control (RBAC) with permissions
4. OAuth2 integration for Google and GitHub SSO
5. Password reset flow with secure token generation
6. Account lockout after failed login attempts
7. Multi-factor authentication (TOTP)
8. Session management with Redis
9. Audit logging for all authentication events
10. Rate limiting per user and per IP

The service should use:
- Express.js with TypeScript
- PostgreSQL with Prisma ORM
- Redis for session and cache
- Zod for validation
- Jest for testing

Please provide the complete implementation including:
- Project structure with all files
- Database schema and migrations
- All API endpoints with full implementation
- Middleware for auth, rate limiting, and error handling
- Unit tests for all use cases
- Integration tests for critical flows
- Docker configuration for development and production
- Environment configuration management
- API documentation with OpenAPI spec

Here is the current partial implementation that needs to be completed and improved. The code has several issues including missing error handling, no input validation, hardcoded values, and missing tests:

The user model currently looks like this and needs proper relations and indexes:
Table users with columns: id as uuid primary key, email as varchar 255 unique not null, password_hash as varchar 255 not null, name as varchar 255 not null, role as varchar 50 default user, is_verified as boolean default false, is_locked as boolean default false, failed_login_attempts as integer default 0, last_login_at as timestamp, mfa_secret as varchar 255, mfa_enabled as boolean default false, created_at as timestamp default now, updated_at as timestamp default now, deleted_at as timestamp nullable.

Table refresh_tokens with columns: id as uuid primary key, user_id as uuid references users id, token_hash as varchar 255 not null, expires_at as timestamp not null, created_at as timestamp default now, revoked_at as timestamp nullable.

Table audit_logs with columns: id as uuid primary key, user_id as uuid references users id, action as varchar 100 not null, ip_address as varchar 45, user_agent as text, metadata as jsonb, created_at as timestamp default now.

Table roles with columns: id as uuid primary key, name as varchar 100 unique not null, description as text, created_at as timestamp default now.

Table permissions with columns: id as uuid primary key, name as varchar 100 unique not null, description as text, resource as varchar 100 not null, action as varchar 50 not null.

Table role_permissions with columns: role_id as uuid references roles id, permission_id as uuid references permissions id, primary key on role_id and permission_id.

The authentication service needs these endpoints:
POST /api/v1/auth/register - Register new user with email and password
POST /api/v1/auth/login - Login with email and password, return JWT tokens
POST /api/v1/auth/refresh - Refresh access token using refresh token
POST /api/v1/auth/logout - Logout and revoke refresh token
POST /api/v1/auth/forgot-password - Send password reset email
POST /api/v1/auth/reset-password - Reset password with token
POST /api/v1/auth/verify-email - Verify email with token
POST /api/v1/auth/mfa/setup - Setup MFA, return QR code
POST /api/v1/auth/mfa/verify - Verify MFA token
POST /api/v1/auth/mfa/disable - Disable MFA
GET /api/v1/auth/me - Get current user profile
PUT /api/v1/auth/me - Update current user profile
GET /api/v1/auth/sessions - List active sessions
DELETE /api/v1/auth/sessions/:id - Revoke specific session
GET /api/v1/admin/users - List all users with pagination and filters
GET /api/v1/admin/users/:id - Get user details
PUT /api/v1/admin/users/:id - Update user role and permissions
DELETE /api/v1/admin/users/:id - Soft delete user
GET /api/v1/admin/audit-logs - Query audit logs with filters

Each endpoint needs proper request validation, error handling, authorization checks, and audit logging. The service should follow Clean Architecture with proper separation of concerns. Implement the domain layer with entities and value objects, application layer with use cases, infrastructure layer with repositories, and presentation layer with controllers and middleware.

Additionally, implement the following cross-cutting concerns:
- Request ID tracking across all logs
- Correlation ID propagation for distributed tracing
- Health check endpoint with database and Redis connectivity checks
- Graceful shutdown with connection draining
- Request and response logging middleware
- Error serialization with proper status codes and error codes
- Swagger UI for API documentation
- Database connection pool management
- Redis connection pool with sentinel support
- Email service abstraction with SMTP and SendGrid implementations

Please provide production-ready code with comprehensive error handling, proper TypeScript types, thorough input validation, and complete test coverage. Include all necessary configuration files, Docker setup, and deployment instructions.
USER0_EOF

    cat > "${RESULT_DIR}/user_prompt_1.txt" << 'USER1_EOF'
Review and completely refactor the following React dashboard application. The current code has severe performance issues, memory leaks, accessibility violations, and poor state management. Provide the complete refactored implementation with all files.

Current issues to fix:
1. No memoization causing unnecessary re-renders on every state change
2. WebSocket connection never cleaned up properly causing memory leaks
3. Polling interval without cleanup causing memory leaks
4. Data fetching on every search term change without debouncing
5. Expensive array computations not memoized
6. No error boundary for graceful error handling
7. No loading skeletons for better perceived performance
8. Zero accessibility - no ARIA labels, no keyboard navigation, no semantic HTML
9. No virtual scrolling for potentially large lists
10. Poor TypeScript usage with any types everywhere

The application is a user management dashboard with these features:
- User list with search, filter by role, and sort capabilities
- Paginated user listing with server-side pagination
- User detail panel showing projects and tasks
- Real-time notifications via WebSocket
- Statistics dashboard showing totals
- Project management with tags and members
- Task tracking with priorities and due dates

The refactored application should include:
- Proper React component architecture with container and presentational components
- Custom hooks for data fetching with SWR or React Query
- Debounced search with proper cleanup
- Memoized computations and callbacks
- Error boundaries with fallback UI
- Loading skeletons using react-loading-skeleton
- Full WCAG 2.1 Level AA accessibility compliance
- Virtual scrolling using react-window for large lists
- Proper TypeScript interfaces and types throughout
- Zustand or Jotai for lightweight state management
- WebSocket manager with auto-reconnection
- Proper cleanup of all side effects
- Unit tests using React Testing Library
- Storybook stories for visual testing

Here is the current problematic code that needs complete refactoring:

The main dashboard component renders a search input, role filter dropdown, sort dropdown, statistics cards showing total users and active projects and pending tasks and unread notifications, a user list with avatars and names and emails and roles, a selected user detail panel with projects and tasks, and pagination controls.

The component uses useState for users array, projects array, notifications array, selected user, search term, filter, sort by, page number, loading state, and error state. It uses useRef for WebSocket connection and polling interval.

The first useEffect creates a WebSocket connection to receive real-time notifications and user updates but never closes the connection on cleanup. The second useEffect sets up a polling interval to fetch unread notifications every 5 seconds but never clears the interval. The third useEffect fetches users and projects whenever search term, page, sort, or filter changes but has no debouncing. The filtered users computation runs filter and sort on every render without memoization. The statistics object is computed on every render.

The JSX has no semantic HTML elements, no ARIA attributes, no keyboard event handlers, images without alt attributes, click handlers on div elements instead of buttons, no focus management for the modal-like detail panel, and no screen reader announcements for dynamic content updates.

Please provide the complete refactored solution with the following file structure:
- src/types/index.ts - All TypeScript interfaces
- src/hooks/useDebounce.ts - Debounce hook
- src/hooks/useUsers.ts - User data fetching hook with React Query
- src/hooks/useProjects.ts - Project data fetching hook
- src/hooks/useNotifications.ts - Notification hook with WebSocket
- src/hooks/useWebSocket.ts - Generic WebSocket hook with reconnection
- src/store/dashboardStore.ts - Zustand store
- src/components/ErrorBoundary.tsx - Error boundary component
- src/components/LoadingSkeleton.tsx - Loading skeleton components
- src/components/SearchBar.tsx - Accessible search with debouncing
- src/components/FilterControls.tsx - Filter and sort controls
- src/components/StatisticsCards.tsx - Memoized statistics display
- src/components/UserList.tsx - Virtualized user list
- src/components/UserCard.tsx - Individual user card
- src/components/UserDetail.tsx - User detail panel as accessible dialog
- src/components/Pagination.tsx - Accessible pagination
- src/components/NotificationBadge.tsx - Notification indicator
- src/pages/Dashboard.tsx - Main dashboard page
- src/utils/api.ts - API client with error handling
- src/tests/Dashboard.test.tsx - Component tests

Each component must have proper TypeScript types, memoization where beneficial, accessibility attributes, keyboard navigation support, and proper cleanup of side effects. Include all necessary imports and exports.
USER1_EOF

    cat > "${RESULT_DIR}/user_prompt_2.txt" << 'USER2_EOF'
Design and implement a complete real-time collaborative document editing microservice in Go. The system must handle concurrent edits from multiple users with proper conflict resolution.

Requirements:
1. Operational Transformation (OT) for concurrent edit conflict resolution
2. WebSocket connections for real-time synchronization between clients
3. Document versioning with full edit history
4. User presence tracking showing cursor positions and selections
5. Per-user undo and redo stacks
6. Auto-save with debouncing to prevent excessive writes
7. Offline support with operation queuing and sync on reconnect
8. Multi-instance support via Redis pub/sub

Tech stack: Go 1.21 plus, PostgreSQL, Redis, gorilla/websocket

Provide the complete implementation including all of the following:

Package main with the application entry point, configuration loading, and graceful shutdown.

Package config with environment-based configuration for database URL, Redis URL, server port, JWT secret, and various timeouts.

Package domain with the core domain types:
- Document struct with ID, Title, Content, Version, OwnerID, CreatedAt, UpdatedAt fields
- Operation struct with Type (insert/delete/retain), Position, Content, Length, UserID, DocumentID, Version, Timestamp fields
- UserPresence struct with UserID, Username, Color, CursorPosition, SelectionStart, SelectionEnd, LastSeen, DocumentID fields
- UndoStack struct per user per document tracking operations for undo and redo
- TransformResult struct for OT transformation output

Package ot implementing the Operational Transformation algorithm:
- Transform function that takes two concurrent operations and returns transformed versions
- Compose function that combines consecutive operations
- Apply function that applies an operation to document content
- TransformIndex function for cursor position transformation
- Handle all edge cases: overlapping deletes, insert at same position, delete range containing insert

Package repository with PostgreSQL implementations:
- DocumentRepository with Create, GetByID, Update, Delete, List, GetVersion methods
- OperationRepository with Save, GetByDocumentAndVersion, GetHistory methods
- Use pgxpool for connection pooling
- Implement proper transaction support

Package cache with Redis implementations:
- DocumentCache for caching document content and metadata
- PresenceCache for tracking user presence with TTL
- OperationBuffer for buffering operations before persistence
- PubSub for cross-instance operation broadcasting

Package websocket with the real-time communication layer:
- Hub managing all document rooms
- Room per document managing connected clients
- Client representing a single WebSocket connection
- Message types: operation, presence, sync, ack, error
- Proper connection lifecycle: connect, authenticate, join document, send/receive, disconnect
- Heartbeat and ping/pong for connection health
- Auto-reconnection support with exponential backoff

Package service with the business logic:
- DocumentService handling document CRUD and version management
- CollaborationService handling real-time editing coordination
- Apply incoming operations with OT transformation against concurrent operations
- Broadcast transformed operations to all other clients in the room
- Manage operation ordering and version consistency
- Handle offline client reconnection by sending missed operations
- Implement auto-save with configurable debounce interval

Package handler with HTTP and WebSocket handlers:
- REST endpoints for document CRUD
- WebSocket upgrade endpoint for real-time collaboration
- Middleware for authentication, logging, rate limiting, and recovery
- Proper error responses with status codes

Package middleware:
- JWT authentication middleware
- Request logging middleware with structured output
- Rate limiting middleware per client
- Recovery middleware for panic handling
- CORS middleware
- Request ID middleware for tracing

The OT algorithm must correctly handle these scenarios:
- Two users inserting at the same position
- One user inserting while another deletes overlapping range
- Multiple sequential operations from same user
- Operations arriving out of order
- Large batch of operations during offline period
- Concurrent undo operations from different users

Include comprehensive tests:
- Unit tests for OT transform function with table-driven tests covering all operation type combinations
- Unit tests for operation apply function
- Unit tests for document service business logic
- Integration tests for WebSocket collaboration flow
- Benchmark tests for OT performance with large documents
- Test helpers and fixtures

Include deployment configuration:
- Dockerfile with multi-stage build
- Docker Compose for local development with PostgreSQL and Redis
- Database migration SQL files
- Makefile with build, test, lint, and run targets
- GitHub Actions CI/CD workflow

Provide complete, compilable Go code for every file with proper error handling, structured logging using slog, context propagation, and graceful shutdown. The code must pass go vet, golint, and have at least 80 percent test coverage.
USER2_EOF

    # --- 用 jq 构建 3 个 JSON 请求体 ---
    local build_ok=0
    for i in 0 1 2; do
        local sys_file="${RESULT_DIR}/system_prompt.txt"
        local usr_file="${RESULT_DIR}/user_prompt_${i}.txt"
        local out_file="${RESULT_DIR}/request_${i}.json"

        jq -n \
            --arg model "$MODEL" \
            --rawfile system "$sys_file" \
            --rawfile user "$usr_file" \
            --argjson max_tokens "$MAX_TOKENS" \
            '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}], max_tokens: $max_tokens, temperature: 0.7}' \
            > "$out_file" 2>/dev/null

        if [ -s "$out_file" ]; then
            local size=$(wc -c < "$out_file" | tr -d '[:space:]')
            echo -e "  请求体 #${i}: ${GREEN}${size} bytes${NC}"
            ((build_ok++))
        else
            echo -e "  请求体 #${i}: ${RED}构建失败${NC}"
        fi
    done

    if [ "$build_ok" -eq 0 ]; then
        echo -e "${RED}所有请求体构建失败，请检查 jq 是否安装${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ 成功构建 ${build_ok} 个请求体${NC}"
    return 0
}

# =============================================
# 发送请求
# =============================================
send_request() {
    local worker_id=$1
    local request_id=$2
    local req_idx=$((RANDOM % 3))
    local req_file="${RESULT_DIR}/request_${req_idx}.json"

    # 兜底：请求文件不存在
    if [ ! -s "$req_file" ]; then
        echo "failed,0,0,0,0,0" >> "${RESULT_DIR}/worker_${worker_id}.csv"
        return
    fi

    local response=$(curl -s -w "\n%{http_code}\n%{time_total}" \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -d @"$req_file" \
        --connect-timeout 30 \
        --max-time 600 2>/dev/null)

    # 空响应保护
    if [ -z "$response" ]; then
        echo "failed,0,0,0,0,0" >> "${RESULT_DIR}/worker_${worker_id}.csv"
        return
    fi

    local time_total=$(echo "$response" | tail -n1)
    local http_code=$(echo "$response" | tail -n2 | head -n1)
    local body=$(echo "$response" | sed '$d' | sed '$d')

    [[ ! "$http_code" =~ ^[0-9]+$ ]] && http_code=0
    [[ -z "$time_total" ]] && time_total=0

    local prompt_tokens=0
    local completion_tokens=0
    local total_tokens=0

    if [ "$http_code" = "200" ]; then
        prompt_tokens=$(echo "$body" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
        completion_tokens=$(echo "$body" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
        total_tokens=$(echo "$body" | jq -r '.usage.total_tokens // 0' 2>/dev/null)
        [[ ! "$prompt_tokens" =~ ^[0-9]+$ ]] && prompt_tokens=0
        [[ ! "$completion_tokens" =~ ^[0-9]+$ ]] && completion_tokens=0
        [[ ! "$total_tokens" =~ ^[0-9]+$ ]] && total_tokens=0
    fi

    local status="success"
    if [ "$http_code" = "429" ]; then
        status="rate_limited"
    elif [ "$http_code" != "200" ]; then
        status="failed"
    fi

    echo "${status},${http_code},${time_total},${prompt_tokens},${completion_tokens},${total_tokens}" >> "${RESULT_DIR}/worker_${worker_id}.csv"
}

# 工作进程
worker() {
    local worker_id=$1
    local request_count=0
    while [ $(date +%s) -lt $END_TIME ]; do
        send_request $worker_id $request_count
        ((request_count++))
    done
}

# =============================================
# 输出与统计
# =============================================
print_title() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      Coding Agent 极限压测 (30K in / 3K out)             ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
}

print_config() {
    echo ""
    echo -e "${BLUE}【压测配置】${NC}"
    echo "  目标地址:    ${ENDPOINT}"
    echo "  测试模型:    ${MODEL}"
    echo "  并发数:      ${CONCURRENCY}"
    echo "  持续时间:    ${DURATION} 秒"
    echo "  max_tokens:  ${MAX_TOKENS} (输出上限)"
    echo ""
}

calculate_results() {
    echo -e "${YELLOW}正在统计结果...${NC}"

    cat ${RESULT_DIR}/worker_*.csv > ${RESULT_DIR}/all_results.csv 2>/dev/null

    if [ ! -f "${RESULT_DIR}/all_results.csv" ] || [ ! -s "${RESULT_DIR}/all_results.csv" ]; then
        echo -e "${RED}没有收集到任何结果数据${NC}"
        return 1
    fi

    TOTAL_REQUESTS=$(wc -l < "${RESULT_DIR}/all_results.csv" | tr -d '[:space:]')
    TOTAL_REQUESTS=${TOTAL_REQUESTS:-0}
    if [ "$TOTAL_REQUESTS" -eq 0 ] 2>/dev/null; then
        echo -e "${RED}没有收集到任何结果数据${NC}"
        return 1
    fi

    SUCCESS_REQUESTS=$(grep -c "^success," "${RESULT_DIR}/all_results.csv" 2>/dev/null || echo 0)
    SUCCESS_REQUESTS=$(echo "$SUCCESS_REQUESTS" | tr -d '[:space:]')
    RATE_LIMITED=$(grep -c "^rate_limited," "${RESULT_DIR}/all_results.csv" 2>/dev/null || echo 0)
    RATE_LIMITED=$(echo "$RATE_LIMITED" | tr -d '[:space:]')
    FAILED_REQUESTS=$((TOTAL_REQUESTS - SUCCESS_REQUESTS))

    TOTAL_PROMPT_TOKENS=$(awk -F',' '{sum+=$4} END {print int(sum)}' "${RESULT_DIR}/all_results.csv")
    TOTAL_COMPLETION_TOKENS=$(awk -F',' '{sum+=$5} END {print int(sum)}' "${RESULT_DIR}/all_results.csv")
    TOTAL_TOKENS=$(awk -F',' '{sum+=$6} END {print int(sum)}' "${RESULT_DIR}/all_results.csv")

    TOTAL_LATENCY=$(awk -F',' '{sum+=$3} END {printf "%.3f", sum}' "${RESULT_DIR}/all_results.csv")
    AVG_LATENCY=$(echo "scale=3; $TOTAL_LATENCY / $TOTAL_REQUESTS" | bc 2>/dev/null || echo "0")
    MIN_LATENCY=$(awk -F',' 'NR==1{min=$3} $3+0<min+0{min=$3} END {printf "%.3f", min}' "${RESULT_DIR}/all_results.csv")
    MAX_LATENCY=$(awk -F',' '$3+0>max+0{max=$3} END {printf "%.3f", max}' "${RESULT_DIR}/all_results.csv")
    P50_LATENCY=$(awk -F',' '{print $3}' "${RESULT_DIR}/all_results.csv" | sort -n | awk -v t="$TOTAL_REQUESTS" 'NR==int(t*0.50){printf "%.3f",$0}')
    P95_LATENCY=$(awk -F',' '{print $3}' "${RESULT_DIR}/all_results.csv" | sort -n | awk -v t="$TOTAL_REQUESTS" 'NR==int(t*0.95){printf "%.3f",$0}')
    P99_LATENCY=$(awk -F',' '{print $3}' "${RESULT_DIR}/all_results.csv" | sort -n | awk -v t="$TOTAL_REQUESTS" 'NR==int(t*0.99){printf "%.3f",$0}')

    if [ "$SUCCESS_REQUESTS" -gt 0 ] 2>/dev/null; then
        AVG_PROMPT_TOKENS=$(echo "scale=0; $TOTAL_PROMPT_TOKENS / $SUCCESS_REQUESTS" | bc 2>/dev/null || echo "0")
        AVG_COMPLETION_TOKENS=$(echo "scale=0; $TOTAL_COMPLETION_TOKENS / $SUCCESS_REQUESTS" | bc 2>/dev/null || echo "0")
    else
        AVG_PROMPT_TOKENS=0
        AVG_COMPLETION_TOKENS=0
    fi

    return 0
}

print_results() {
    local actual_duration=$((END_TIME - START_TIME))
    [ "$actual_duration" -eq 0 ] && actual_duration=1

    local qpm=$(echo "scale=2; $TOTAL_REQUESTS * 60 / $actual_duration" | bc 2>/dev/null || echo "0")
    local success_qpm=$(echo "scale=2; $SUCCESS_REQUESTS * 60 / $actual_duration" | bc 2>/dev/null || echo "0")
    local tpm_total=$(echo "scale=0; $TOTAL_TOKENS * 60 / $actual_duration" | bc 2>/dev/null || echo "0")
    local tpm_prompt=$(echo "scale=0; $TOTAL_PROMPT_TOKENS * 60 / $actual_duration" | bc 2>/dev/null || echo "0")
    local tpm_completion=$(echo "scale=0; $TOTAL_COMPLETION_TOKENS * 60 / $actual_duration" | bc 2>/dev/null || echo "0")
    local success_rate=$(echo "scale=2; $SUCCESS_REQUESTS * 100 / $TOTAL_REQUESTS" | bc 2>/dev/null || echo "0")
    local throughput=$(echo "scale=2; $TOTAL_TOKENS / $actual_duration" | bc 2>/dev/null || echo "0")

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            Coding Agent 压测结果报告                      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${BLUE}【基本信息】${NC}"
    echo "  测试模型:     ${MODEL}"
    echo "  实际持续时间: ${actual_duration} 秒"
    echo "  并发数:       ${CONCURRENCY}"
    echo "  输出上限:     ${MAX_TOKENS} tokens/请求"
    echo ""

    echo -e "${BLUE}【请求统计】${NC}"
    echo "  总请求数:     ${TOTAL_REQUESTS}"
    echo -e "  成功请求:     ${GREEN}${SUCCESS_REQUESTS}${NC}"
    echo -e "  失败请求:     ${RED}${FAILED_REQUESTS}${NC}"
    echo -e "  限流请求:     ${YELLOW}${RATE_LIMITED}${NC}"
    echo -e "  成功率:       ${success_rate}%"
    echo ""

    echo -e "${BLUE}【⭐ 核心指标】${NC}"
    echo -e "  ${GREEN}QPM (每分钟请求数):      ${qpm}${NC}"
    echo -e "  ${GREEN}QPM (成功):              ${success_qpm}${NC}"
    echo -e "  ${GREEN}TPM (每分钟总 Token):    ${tpm_total}${NC}"
    echo -e "  ${GREEN}TPM (Prompt):            ${tpm_prompt}${NC}"
    echo -e "  ${GREEN}TPM (Completion):        ${tpm_completion}${NC}"
    echo -e "  ${GREEN}吞吐量 (tokens/s):       ${throughput}${NC}"
    echo ""

    echo -e "${BLUE}【Token 统计】${NC}"
    echo "  总 Prompt Tokens:     ${TOTAL_PROMPT_TOKENS}"
    echo "  总 Completion Tokens: ${TOTAL_COMPLETION_TOKENS}"
    echo "  总 Tokens:            ${TOTAL_TOKENS}"
    echo "  平均 Prompt/请求:     ${AVG_PROMPT_TOKENS}"
    echo "  平均 Completion/请求: ${AVG_COMPLETION_TOKENS}"
    echo ""

    echo -e "${BLUE}【延迟统计】${NC}"
    echo "  最小延迟: ${MIN_LATENCY:-N/A} 秒"
    echo "  平均延迟: ${AVG_LATENCY} 秒"
    echo "  P50 延迟: ${P50_LATENCY:-N/A} 秒"
    echo "  P95 延迟: ${P95_LATENCY:-N/A} 秒"
    echo "  P99 延迟: ${P99_LATENCY:-N/A} 秒"
    echo "  最大延迟: ${MAX_LATENCY:-N/A} 秒"
    echo ""

    if [ "$RATE_LIMITED" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  触发限流 ${RATE_LIMITED} 次 (HTTP 429)，已达到 QPM/TPM 上限${NC}"
    fi
    if [ "$FAILED_REQUESTS" -gt 0 ]; then
        echo -e "${RED}⚠️  ${FAILED_REQUESTS} 次失败请求${NC}"
        echo -e "${RED}   失败状态码分布:${NC}"
        grep -v "^success," "${RESULT_DIR}/all_results.csv" | awk -F',' '{print $2}' | sort | uniq -c | sort -rn | while read count code; do
            echo -e "${RED}     HTTP ${code}: ${count} 次${NC}"
        done
    fi
    if [ "$RATE_LIMITED" -eq 0 ] && [ "$FAILED_REQUESTS" -eq 0 ]; then
        echo -e "${GREEN}✓ 所有请求成功，未触发限流，可尝试增加并发数${NC}"
    fi

    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
}

# =============================================
# 帮助与参数
# =============================================
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Coding Agent 场景极限压测 (30K 输入 / 3K 输出)"
    echo ""
    echo "Options:"
    echo "  -h, --help         显示帮助信息"
    echo "  -c, --concurrency  并发数 (默认: 3)"
    echo "  -d, --duration     测试持续时间/秒 (默认: 120)"
    echo "  -t, --tokens       每次请求的 max_tokens (默认: 3000)"
    echo "  -m, --model        测试的模型 (默认: glm-5)"
    echo ""
    echo "Examples:"
    echo "  $0                           # 默认: glm-5, 3并发, 120秒"
    echo "  $0 -c 5 -d 180              # 5并发，180秒"
    echo "  $0 -m qwen-coder-plus -c 3  # 测试其他模型"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -c|--concurrency) CONCURRENCY="$2"; shift 2 ;;
        -d|--duration) DURATION="$2"; shift 2 ;;
        -t|--tokens) MAX_TOKENS="$2"; shift 2 ;;
        -m|--model) MODEL="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# =============================================
# 主函数
# =============================================
main() {
    print_title
    print_config

    # 检查依赖
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq 未安装，压测需要 jq 构建请求体${NC}"
        echo "  macOS: brew install jq"
        echo "  Ubuntu: apt install jq"
        exit 1
    fi
    if ! command -v bc &> /dev/null; then
        echo -e "${RED}Error: bc 未安装${NC}"
        exit 1
    fi

    # 构建请求体
    if ! build_request_files; then
        exit 1
    fi
    echo ""

    # 测试连接
    echo -e "${YELLOW}测试连接...${NC}"
    if ! curl -s --connect-timeout 5 "${KONG_URL}" > /dev/null 2>&1; then
        echo -e "${RED}无法连接到 Kong 网关: ${KONG_URL}${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 连接成功${NC}"

    # 先发一个探测请求
    echo -e "${YELLOW}发送探测请求...${NC}"
    local probe_file="${RESULT_DIR}/request_0.json"
    local probe_start=$(date +%s)
    local probe_resp=$(curl -s -o /dev/null -w "%{http_code},%{time_total}" \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -d @"$probe_file" \
        --connect-timeout 30 \
        --max-time 600 2>/dev/null)
    local probe_code=$(echo "$probe_resp" | cut -d',' -f1)
    local probe_time=$(echo "$probe_resp" | cut -d',' -f2)
    local probe_end=$(date +%s)

    echo -e "  探测结果: HTTP ${probe_code}, 耗时 ${probe_time}s"
    if [ "$probe_code" != "200" ]; then
        echo -e "${RED}⚠️  探测请求失败 (HTTP ${probe_code})，是否继续压测? (y/N)${NC}"
        read -t 10 -r confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "已取消"
            exit 1
        fi
    else
        echo -e "${GREEN}✓ 探测成功${NC}"
    fi
    echo ""

    # 开始压测
    echo -e "${YELLOW}开始 Coding Agent 场景压测，持续 ${DURATION} 秒，并发 ${CONCURRENCY}...${NC}"
    echo -e "${YELLOW}(每个请求 ~30K 输入，响应较慢请耐心等待)${NC}"
    echo ""

    START_TIME=$(date +%s)
    END_TIME=$((START_TIME + DURATION))

    # 错峰启动，避免惊群效应
    local ramp_up_sec=10
    local batch_size=$(( CONCURRENCY / ramp_up_sec ))
    [ "$batch_size" -lt 1 ] && batch_size=1
    local launched=0
    for i in $(seq 1 $CONCURRENCY); do
        worker $i &
        launched=$((launched + 1))
        if [ $((launched % batch_size)) -eq 0 ] && [ $launched -lt $CONCURRENCY ]; then
            sleep 1
        fi
    done
    log "全部 ${CONCURRENCY} 个 worker 已启动 (${ramp_up_sec}s 爬坡)"

    # 显示进度
    while [ $(date +%s) -lt $END_TIME ]; do
        local elapsed=$(($(date +%s) - START_TIME))
        local remaining=$((DURATION - elapsed))
        local current_count=0
        if ls ${RESULT_DIR}/worker_*.csv 1>/dev/null 2>&1; then
            current_count=$(cat ${RESULT_DIR}/worker_*.csv 2>/dev/null | wc -l | tr -d '[:space:]')
        fi
        printf "\r  进度: %d/%d 秒 | 已完成请求: %s" "$elapsed" "$DURATION" "$current_count"
        sleep 2
    done
    echo ""
    echo ""

    echo -e "${YELLOW}等待所有请求完成...${NC}"
    wait

    END_TIME=$(date +%s)

    if calculate_results; then
        print_results
    fi
}

main
