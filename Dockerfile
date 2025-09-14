# syntax=docker/dockerfile:1.7

ARG GO_VERSION=1.23
ARG NODE_VERSION=20

# ---------- Stage 1: Build UI (auto-detect workspace, with fallback) ----------
FROM node:${NODE_VERSION}-alpine AS ui
WORKDIR /src

# Yarn via corepack
RUN corepack enable && corepack prepare yarn@stable --activate

# 先放入最少的清单文件以命中缓存；不强依赖 yarn.lock/.yarnrc.yml
# 若仓库根有 package.json（workspace 场景），下面命令会利用它；否则仅用 apps/frontend 的 package.json
COPY package.json ./ 2>/dev/null || true
COPY apps/frontend/package.json apps/frontend/

# 安装依赖（自动判断是否 workspace）：
# - 若根目录含 workspaces：在根目录安装（严格 -> 宽松回退）
# - 否则：进入 apps/frontend 安装（严格 -> 宽松回退）
ENV YARN_ENABLE_IMMUTABLE_INSTALLS=false
RUN sh -lc '\
  if [ -f package.json ] && node -e "try{process.exit(require(\"./package.json\").workspaces?0:1)}catch(e){process.exit(1)}"; then \
    echo "[UI] Detected workspaces at repo root"; \
    yarn install --immutable || yarn install; \
  else \
    echo "[UI] No workspaces at repo root; installing only apps/frontend"; \
    cd apps/frontend && (yarn install --frozen-lockfile || yarn install); \
  fi'

# 拷贝全部源码并构建前端
COPY . .
RUN yarn --cwd apps/frontend build

# ---------- Stage 2: Build Go binary (embed UI) ----------
FROM golang:${GO_VERSION}-alpine3.20 AS builder
RUN apk add --no-cache git ca-certificates gcc musl-dev libc-dev pkgconfig make
WORKDIR /src

# 拷贝全部源码 + UI 产物（确保 go:embed 能打包静态资源）
COPY . .
COPY --from=ui /src/apps/frontend /src/apps/frontend

# 预热依赖缓存并构建
ENV CGO_ENABLED=1
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make bbgo || go build -o ./bbgo ./cmd/bbgo

# 统一产物
RUN mkdir -p /out && \
    if [ -x ./bbgo ]; then cp ./bbgo /out/bbgo; else cp ./cmd/bbgo/bbgo /out/bbgo; fi

# ---------- Stage 3: Runtime ----------
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
ENV USER=bbgo
RUN adduser -D -G wheel "$USER"
USER ${USER}
WORKDIR /home/${USER}

COPY --from=builder /out/bbgo /usr/local/bin/bbgo
EXPOSE 8080
ENV GIN_MODE=release

ENTRYPOINT ["/usr/local/bin/bbgo"]
# 默认启用 Web UI；运行时可覆盖
CMD ["run","--config","/config/bbgo.yaml","--enable-webserver","--debug"]
