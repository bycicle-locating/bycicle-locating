// Package mqtt 定义消息总线的 seam。
//
// 生产实现用 eclipse/paho.mqtt.golang，接口刻意不暴露 paho 的任何类型，
// 这样 ingest/api 的测试不需要 broker，将来换 broker 客户端也不用改调用方。
package mqtt

import (
	"context"
	"log/slog"
)

// Message 是一条收到的消息，字段与 paho 的 Message 解耦。
type Message struct {
	Topic   string
	Payload []byte
	QoS     byte
	Retain  bool
}

// Handler 处理一条消息。返回错误表示需要重试；永久无效的报文应丢弃并返回 nil。
type Handler func(ctx context.Context, m Message) error

// Bus 是发布/订阅接口。实现必须：
//   - Publish 在 ctx 取消时尽快返回；
//   - Subscribe 的 handler 串行调用（QoS1 顺序语义），不要在 handler 里阻塞过久；
//   - Close 可重复调用。
type Bus interface {
	Publish(ctx context.Context, topic string, payload []byte, qos byte, retain bool) error
	Subscribe(ctx context.Context, filter string, h Handler) error
	Close() error
}

// LogBus 只把动作写进日志，用于未配置 Broker 的本地 HTTP 开发。
type LogBus struct {
	log *slog.Logger
}

// NewLogBus 创建一个仅记录日志的总线。
func NewLogBus(l *slog.Logger) *LogBus {
	if l == nil {
		l = slog.Default()
	}
	return &LogBus{log: l}
}

// Publish 记录一次发送。
func (b *LogBus) Publish(_ context.Context, topic string, payload []byte, qos byte, retain bool) error {
	b.log.Info("mqtt.publish(未连通)", "topic", topic, "bytes", len(payload), "qos", qos, "retain", retain)
	return nil
}

// Subscribe 记录一次订阅；这里不触发任何回调。
func (b *LogBus) Subscribe(_ context.Context, filter string, _ Handler) error {
	b.log.Debug("MQTT 已停用，跳过订阅", "filter", filter)
	return nil
}

// Close 什么也不做。
func (b *LogBus) Close() error { return nil }

// 编译期确认实现满足接口。
var _ Bus = (*LogBus)(nil)
