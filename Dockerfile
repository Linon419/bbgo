# syntax=docker/dockerfile:1.7

ARG GO_VERSION=1.23
ARG NODE_VERSION=20

# ---------- Stage 1: Build UI (auto-detect workspace, with fallback) ----------
FROM node:${NODE_VERSION}-alpine AS ui
WORKDIR /src

# Yarn via corepack
RUN corepack enable && corepack prepare yarn@stable --activate

# 先放入最少的清单文件以命中缓存；不强依赖 yarn.lock/.yarnrc.yml
# 只复制 apps/frontend 的 package.json，因为仓库根目录没有 package.json
COPY apps/frontend/package.json apps/frontend/

# 安装依赖：由于没有根目录的 package.json，直接在 apps/frontend 安装
ENV YARN_ENABLE_IMMUTABLE_INSTALLS=false
RUN echo "[UI] Installing dependencies in apps/frontend" && \
    cd apps/frontend && (yarn install --frozen-lockfile || yarn install)

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
