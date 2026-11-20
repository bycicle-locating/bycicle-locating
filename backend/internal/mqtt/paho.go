package mqtt

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"sync"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
)

// BrokerConfig 配置一个 MQTT 3.1.1 客户端。
type BrokerConfig struct {
	URL      string
	Username string
	Password string
	CAFile   string
	ClientID string
}

// PahoBus 使用持久会话和 QoS 1。先注册处理器，再连接 Broker。
type PahoBus struct {
	ctx    context.Context
	cancel context.CancelFunc
	log    *slog.Logger
	client paho.Client

	mu          sync.Mutex
	started     bool
	filters     map[string]byte
	subscribeMu sync.Mutex
	first       sync.Once
	ready       chan error
	close       sync.Once
}

func NewPahoBus(ctx context.Context, cfg BrokerConfig, log *slog.Logger) (*PahoBus, error) {
	endpoint, err := url.Parse(cfg.URL)
	if err != nil || endpoint.User != nil || endpoint.Hostname() == "" || endpoint.Port() == "" {
		return nil, fmt.Errorf("mqtt: Broker 地址无效")
	}
	if log == nil {
		log = slog.Default()
	}
	opts := paho.NewClientOptions().
		AddBroker(cfg.URL).
		SetClientID(cfg.ClientID).
		SetUsername(cfg.Username).
		SetPassword(cfg.Password).
		SetProtocolVersion(4).
		SetCleanSession(false).
		SetOrderMatters(true).
		SetAutoAckDisabled(true).
		SetAutoReconnect(true).
		SetConnectTimeout(5 * time.Second).
		SetMaxReconnectInterval(30 * time.Second).
		SetWriteTimeout(5 * time.Second)
	switch endpoint.Scheme {
	case "mqtts":
		tlsConfig := &tls.Config{ServerName: endpoint.Hostname(), MinVersion: tls.VersionTLS12}
		if cfg.CAFile != "" {
			ca, err := os.ReadFile(cfg.CAFile)
			if err != nil {
				return nil, fmt.Errorf("mqtt: 读取 CA: %w", err)
			}
			tlsConfig.RootCAs = x509.NewCertPool()
			if !tlsConfig.RootCAs.AppendCertsFromPEM(ca) {
				return nil, fmt.Errorf("mqtt: CA 文件没有可用的 PEM 证书")
			}
		}
		opts.SetTLSConfig(tlsConfig)
	case "tcp":
	default:
		return nil, fmt.Errorf("mqtt: Broker 协议不受支持")
	}

	ctx, cancel := context.WithCancel(ctx)
	bus := &PahoBus{
		ctx: ctx, cancel: cancel, log: log,
		filters: make(map[string]byte), ready: make(chan error, 1),
	}
	opts.SetOnConnectHandler(bus.onConnect)
	opts.SetConnectionLostHandler(func(_ paho.Client, err error) {
		if ctx.Err() == nil {
			log.Warn("MQTT 连接断开，等待重连", "err", err)
		}
	})
	opts.SetDefaultPublishHandler(func(_ paho.Client, msg paho.Message) {
		msg.Ack()
	})
	bus.client = paho.NewClient(opts)
	return bus, nil
}

// Subscribe 在连接前注册过滤器，让恢复会话时的积压报文也有处理器。
func (b *PahoBus) Subscribe(ctx context.Context, filter string, handler Handler) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.started || b.ctx.Err() != nil {
		return fmt.Errorf("mqtt: 必须在连接前注册订阅")
	}
	b.filters[filter] = 1
	b.client.AddRoute(filter, b.deliver(handler))
	return nil
}

// Connect 等到 Broker 接受订阅后才返回。
func (b *PahoBus) Connect(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	b.mu.Lock()
	if b.started || b.ctx.Err() != nil {
		b.mu.Unlock()
		return fmt.Errorf("mqtt: 客户端已经启动或关闭")
	}
	b.started = true
	token := b.client.Connect()
	b.mu.Unlock()
	if err := await(ctx, token); err != nil {
		return fmt.Errorf("mqtt: 连接 Broker: %w", err)
	}
	select {
	case err := <-b.ready:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (b *PahoBus) onConnect(client paho.Client) {
	b.subscribeMu.Lock()
	defer b.subscribeMu.Unlock()
	for b.ctx.Err() == nil && client.IsConnectionOpen() {
		ctx, cancel := context.WithTimeout(b.ctx, 5*time.Second)
		err := b.subscribeAll(ctx, client)
		cancel()
		b.first.Do(func() { b.ready <- err })
		if err == nil {
			b.log.Info("MQTT 已连接并订阅", "filters", len(b.filters))
			return
		}
		b.log.Warn("MQTT 订阅失败，等待重试", "err", err)
		select {
		case <-b.ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

func (b *PahoBus) subscribeAll(ctx context.Context, client paho.Client) error {
	if len(b.filters) == 0 {
		return nil
	}
	token := client.SubscribeMultiple(b.filters, nil)
	if err := await(ctx, token); err != nil {
		return fmt.Errorf("mqtt: 请求订阅: %w", err)
	}
	result := token.(*paho.SubscribeToken).Result()
	for filter := range b.filters {
		if result[filter] != 1 {
			return fmt.Errorf("mqtt: Broker 未授予 QoS 1 订阅 %q", filter)
		}
	}
	return nil
}

func (b *PahoBus) deliver(handler Handler) paho.MessageHandler {
	return func(_ paho.Client, msg paho.Message) {
		message := Message{Topic: msg.Topic(), Payload: msg.Payload(), QoS: msg.Qos(), Retain: msg.Retained()}
		for b.ctx.Err() == nil {
			ctx, cancel := context.WithTimeout(b.ctx, 5*time.Second)
			err := handler(ctx, message)
			cancel()
			if err == nil {
				msg.Ack()
				return
			}
			// 保留未确认报文，数据库恢复后继续按接收顺序处理。
			b.log.Warn("MQTT 报文处理失败，稍后重试", "topic", message.Topic, "err", err)
			select {
			case <-b.ctx.Done():
				return
			case <-time.After(time.Second):
			}
		}
	}
}

func (b *PahoBus) Publish(ctx context.Context, topic string, payload []byte, qos byte, retain bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if !b.client.IsConnectionOpen() {
		return fmt.Errorf("mqtt: Broker 未连接")
	}
	return await(ctx, b.client.Publish(topic, qos, retain, payload))
}

func (b *PahoBus) Close() error {
	b.close.Do(func() {
		b.cancel()
		b.mu.Lock()
		defer b.mu.Unlock()
		b.client.Disconnect(250)
	})
	return nil
}

func await(ctx context.Context, token paho.Token) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-token.Done():
		return token.Error()
	}
}

var _ Bus = (*PahoBus)(nil)
