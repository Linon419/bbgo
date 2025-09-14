# syntax=docker/dockerfile:1.7

ARG GO_VERSION=1.23
ARG NODE_VERSION=20

# ---------- Stage 1: Build UI ----------
FROM node:${NODE_VERSION}-alpine AS ui
WORKDIR /src
# 用 corepack 管理 yarn
RUN corepack enable && corepack prepare yarn@stable --activate
# 先拷依赖清单，利用缓存
COPY apps/frontend/package.json apps/frontend/yarn.lock ./apps/frontend/
WORKDIR /src/apps/frontend
RUN yarn install --frozen-lockfile
# 再拷源码并构建
COPY apps/frontend ./
RUN yarn build

# ---------- Stage 2: Build Go binary (embed UI) ----------
FROM golang:${GO_VERSION}-alpine3.20 AS builder
# sqlite3 需要 CGO
RUN apk add --no-cache git ca-certificates gcc musl-dev libc-dev pkgconfig make
WORKDIR /src
# 拷全仓库源码
COPY . .
# 用上一步生成的前端产物覆盖/补全到源码里（方便 embed）
COPY --from=ui /src/apps/frontend /src/apps/frontend

# （可选）预拉依赖，加速构建
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

ENV CGO_ENABLED=1
# 用 Makefile 构建；如果你的仓库没有 make 目标，可改成 go build
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make bbgo || go build -o ./bbgo ./cmd/bbgo

# 统一产物到 /out/bbgo
RUN mkdir -p /out && \
    if [ -x ./bbgo ]; then cp ./bbgo /out/bbgo; else cp ./cmd/bbgo/bbgo /out/bbgo; fi

# ---------- Stage 3: Runtime ----------
FROM alpine:3.20
# 运行期需要 CA 证书；sqlite3 的 CGO 依赖 musl（已内置于 alpine）
RUN apk add --no-cache ca-certificates tzdata
# 以非 root 用户运行
ENV USER=bbgo
RUN adduser -D -G wheel "$USER"
USER ${USER}
WORKDIR /home/${USER}

COPY --from=builder /out/bbgo /usr/local/bin/bbgo
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/bbgo"]
# 默认启用 Web UI；运行时可被覆盖
CMD ["run","--config","/config/bbgo.yaml","--enable-webserver","--debug"]
