# syntax=docker/dockerfile:1

# 构建阶段与运行阶段分离：最终镜像只含静态二进制与 CA 证书。
FROM golang:1.27-alpine@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS build
WORKDIR /src

COPY go.mod ./
COPY . .

RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/bkl-server ./cmd/server

FROM alpine:3.22@sha256:bfe7ceb9f09ec0566c48fb93356e45a47a00be5a1dd14fa5b909e7709c66b034

RUN apk add --no-cache ca-certificates \
    && addgroup -S -g 10001 bkl \
    && adduser -S -D -H -u 10001 -G bkl bkl

COPY --from=build /out/bkl-server /usr/local/bin/bkl-server

USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/bkl-server"]
