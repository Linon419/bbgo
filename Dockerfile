# syntax=docker/dockerfile:1.7

ARG GO_VERSION=1.23
ARG NODE_VERSION=20

# ---------- Stage 1: Build UI (workspace 根目录安装 + 容错回退) ----------
FROM node:${NODE_VERSION}-alpine AS ui
WORKDIR /src
# 用 corepack 管理 yarn 版本
RUN corepack enable && corepack prepare yarn@stable --activate

# 先拷“根目录”的依赖清单（适配 Yarn Berry/Classic），最大化缓存命中
COPY package.json yarn.lock .yarnrc.yml* ./
COPY .yarn/ .yarn/ 2>/dev/null || true
# 让 yarn 能解析 workspace 的子包
COPY apps/frontend/package.json apps/frontend/

# 容错安装：优先严格模式，失败就退回普通安装（避免 YN0028）
ENV YARN_ENABLE_IMMUTABLE_INSTALLS=false
RUN sh -lc 'if yarn -v | grep -qE "^[2-9]"; then yarn install --immutable || yarn install; else yarn install --frozen-lockfile || yarn install; fi'

# 再拷源码并构建前端
COPY . .
RUN yarn --cwd apps/frontend build

# ---------- Stage 2: Build Go binary (embed UI) ----------
FROM golang:${GO_VERSION}-alpine3.20 AS builder
# sqlite3 需要 CGO
RUN apk add --no-cache git ca-certificates gcc musl-dev libc-dev pkgconfig make
WORKDIR /src
COPY . .
# 用上一步生成的前端产物（确保 go:embed 能把静态资源打包进二进制）
COPY --from=ui /src/apps/frontend /src/apps/frontend

# 预拉依赖，加速构建
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

ENV CGO_ENABLED=1
# 构建（优先使用 Makefile；没有则回退 go build）
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make bbgo || go build -o ./bbgo ./cmd/bbgo

# 统一产物到 /out/bbgo
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
