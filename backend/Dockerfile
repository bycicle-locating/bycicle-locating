# syntax=docker/dockerfile:1

# 构建阶段与运行阶段分离：最终镜像只含静态二进制与 CA 证书。
FROM golang:1.22-alpine AS build
WORKDIR /src

COPY go.mod ./
COPY . .

RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/bkl-server ./cmd/server

FROM alpine:3.22

RUN apk add --no-cache ca-certificates \
    && addgroup -S -g 10001 bkl \
    && adduser -S -D -H -u 10001 -G bkl bkl

COPY --from=build /out/bkl-server /usr/local/bin/bkl-server

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/bkl-server"]
