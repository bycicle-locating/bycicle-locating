package protocol

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// 下行指令名，见 protocol.md §7。
const (
	CmdLocate    = "locate"
	CmdBind      = "bind"
	CmdUnbind    = "unbind"
	CmdSetConfig = "set_config"
	CmdReboot    = "reboot"
	// CmdWriteClaim 让设备把新的声明码写入 NFC 标签（M3，见 protocol.md §7.3）。
	CmdWriteClaim = "write_claim"
)

// Command 是云端下发给设备的指令。
type Command struct {
	CmdID    string
	Name     string
	Params   map[string]any
	IssuedAt time.Time
}

type commandWire struct {
	V        int            `json:"v"`
	CmdID    string         `json:"cmdId"`
	Cmd      string         `json:"cmd"`
	Params   map[string]any `json:"params,omitempty"`
	IssuedAt time.Time      `json:"issuedAt"`
}

// EncodeCommand 序列化下行指令。指令不走 Decode 的信封校验（方向相反、字段不同），
// 但仍固定在 v1 版本上，设备侧据此拒绝不认识的版本。
func EncodeCommand(c Command) ([]byte, error) {
	if c.CmdID == "" {
		return nil, fmt.Errorf("%w: 缺少 cmdId", ErrInvalidPayload)
	}
	switch c.Name {
	case CmdLocate, CmdBind, CmdUnbind, CmdSetConfig, CmdReboot, CmdWriteClaim:
	default:
		return nil, fmt.Errorf("%w: 未知指令 %q", ErrInvalidPayload, c.Name)
	}
	issued := c.IssuedAt
	if issued.IsZero() {
		issued = time.Now()
	}
	payload, err := json.Marshal(commandWire{
		V:        Version,
		CmdID:    c.CmdID,
		Cmd:      c.Name,
		Params:   c.Params,
		IssuedAt: issued.UTC(),
	})
	if err != nil {
		return nil, fmt.Errorf("protocol: 编码指令失败: %w", err)
	}
	if len(payload) > MaxPayloadBytes {
		return nil, fmt.Errorf("%w: 指令 %d 字节", ErrTooLarge, len(payload))
	}
	return payload, nil
}

// 主题构造与解析。主题格式集中在这里，避免各处手拼字符串导致拼写不一致。

const topicPrefix = "v1/device/"

// TopicTelemetry / TopicEvent / TopicStatus 是设备上行主题。
func TopicTelemetry(deviceID string) string { return topicPrefix + deviceID + "/telemetry" }
func TopicEvent(deviceID string) string     { return topicPrefix + deviceID + "/event" }
func TopicStatus(deviceID string) string    { return topicPrefix + deviceID + "/status" }

// TopicCmd / TopicCmdAck 是下行指令与其确认的主题。
func TopicCmd(deviceID string) string    { return topicPrefix + deviceID + "/cmd" }
func TopicCmdAck(deviceID string) string { return topicPrefix + deviceID + "/cmd/ack" }

// ErrBadTopic 表示主题不符合 v1 约定。
var ErrBadTopic = fmt.Errorf("protocol: 主题非法")

// ParseTopic 从上行主题中解出设备 ID 与报文类型。
//
// 只接受 telemetry / event / status / cmd/ack 四种，其它（含 v2 前缀）
// 一律返回 ErrBadTopic，由调用方丢弃并计数。
func ParseTopic(topic string) (deviceID string, kind Type, err error) {
	if !strings.HasPrefix(topic, topicPrefix) {
		return "", "", ErrBadTopic
	}
	rest := strings.TrimPrefix(topic, topicPrefix)
	idx := strings.IndexByte(rest, '/')
	if idx <= 0 {
		return "", "", ErrBadTopic
	}
	deviceID = rest[:idx]
	if !validDeviceID(deviceID) {
		return "", "", fmt.Errorf("%w: 设备 ID %q", ErrBadTopic, deviceID)
	}

	switch rest[idx+1:] {
	case "telemetry":
		return deviceID, TypeTelemetry, nil
	case "event":
		return deviceID, TypeEvent, nil
	case "status":
		return deviceID, TypeStatus, nil
	case "cmd/ack":
		return deviceID, TypeCmdAck, nil
	default:
		return "", "", fmt.Errorf("%w: %s", ErrBadTopic, topic)
	}
}
