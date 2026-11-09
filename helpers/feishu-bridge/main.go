package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	lark "github.com/larksuite/oapi-sdk-go/v3"
	larkcore "github.com/larksuite/oapi-sdk-go/v3/core"
	"github.com/larksuite/oapi-sdk-go/v3/event/dispatcher"
	"github.com/larksuite/oapi-sdk-go/v3/event/dispatcher/callback"
	larkim "github.com/larksuite/oapi-sdk-go/v3/service/im/v1"
	larkws "github.com/larksuite/oapi-sdk-go/v3/ws"
)

// feishu-bridge is a child of CodeIsland. It keeps one outbound Feishu long
// connection and speaks newline-delimited JSON on stdin/stdout. It never
// decides a Codex approval itself: a card click is forwarded, and only an
// explicit allow or deny value is forwarded. Chat text is not an approval.
func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags)
	bridge := newBridge()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 2*1024*1024)
	for scanner.Scan() {
		bridge.handleLine(scanner.Bytes())
	}
	bridge.stop()
}

type stderrLogger struct{}

func (stderrLogger) Debug(context.Context, ...interface{}) {}
func (stderrLogger) Info(context.Context, ...interface{})  {}
func (stderrLogger) Warn(context.Context, ...interface{})  {}
func (stderrLogger) Error(_ context.Context, args ...interface{}) {
	log.Println(args...)
}

type cardTrack struct {
	messageID     string
	inflightUntil time.Time
	done          bool
	decision      string
}

type bridge struct {
	mu       sync.Mutex
	emitMu   sync.Mutex
	appID    string
	secret   string
	openID   string
	armBind  bool
	api      *lark.Client
	cancel   context.CancelFunc
	done     chan struct{}
	cards    map[string]*cardTrack
}

func newBridge() *bridge {
	return &bridge{cards: map[string]*cardTrack{}}
}

func (b *bridge) handleLine(raw []byte) {
	var msg map[string]any
	if err := json.Unmarshal(raw, &msg); err != nil {
		b.emitLog("ignored a control line that was not JSON")
		return
	}
	op, _ := msg["op"].(string)
	switch op {
	case "configure":
		appID, _ := msg["app_id"].(string)
		secret, _ := msg["app_secret"].(string)
		openID, _ := msg["open_id"].(string)
		b.configure(strings.TrimSpace(appID), strings.TrimSpace(secret), strings.TrimSpace(openID))
	case "arm_bind":
		b.mu.Lock()
		b.armBind = true
		b.mu.Unlock()
		b.emitStatus("online", "等待飞书私聊。文字不会批准命令。")
	case "bind":
		openID, _ := msg["open_id"].(string)
		openID = strings.TrimSpace(openID)
		b.mu.Lock()
		b.openID = openID
		b.armBind = false
		b.mu.Unlock()
		if openID != "" {
			b.emitStatus("online", "已绑定，审批卡片会发到这个账号。")
		}
	case "unbind":
		b.mu.Lock()
		b.openID = ""
		b.armBind = false
		b.mu.Unlock()
		b.emitStatus("online", "已解除绑定。新的审批不会发到飞书。")
	case "card":
		b.sendCard(msg)
	case "resolved":
		id, _ := msg["request_id"].(string)
		decision, _ := msg["decision"].(string)
		b.markResolved(strings.TrimSpace(id), strings.TrimSpace(decision))
	default:
		b.emitLog("ignored unknown control op")
	}
}

func (b *bridge) configure(appID, secret, openID string) {
	if appID == "" || secret == "" {
		b.emitStatus("error", "缺少 App ID 或 App Secret。")
		return
	}
	b.mu.Lock()
	same := b.cancel != nil && b.appID == appID && b.secret == secret
	b.openID = openID
	b.mu.Unlock()
	if same {
		if openID != "" {
			b.emitStatus("online", "已绑定，审批卡片会发到这个账号。")
		} else {
			b.emitStatus("online", "长连接已在。还没有绑定飞书账号。")
		}
		return
	}
	b.restart(appID, secret)
}

func (b *bridge) restart(appID, secret string) {
	b.mu.Lock()
	cancel := b.cancel
	done := b.done
	b.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if done != nil {
		select {
		case <-done:
		case <-time.After(8 * time.Second):
			b.emitLog("previous long connection did not stop within 8s")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan struct{})
	b.mu.Lock()
	b.cancel = cancel
	b.done = finished
	b.appID = appID
	b.secret = secret
	b.api = lark.NewClient(appID, secret,
		lark.WithLogLevel(larkcore.LogLevelError),
		lark.WithLogger(stderrLogger{}),
	)
	b.mu.Unlock()
	go func() {
		defer close(finished)
		b.serve(ctx, appID, secret)
	}()
}

func (b *bridge) stop() {
	b.mu.Lock()
	cancel := b.cancel
	b.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (b *bridge) serve(ctx context.Context, appID, secret string) {
	b.emitStatus("connecting", "正在连接飞书长连接。")
	handler := dispatcher.NewEventDispatcher("", "").
		OnP2MessageReceiveV1(b.onMessage).
		OnP2CardActionTrigger(b.onCard)
	cli := larkws.NewClient(appID, secret,
		larkws.WithEventHandler(handler),
		larkws.WithLogLevel(larkcore.LogLevelError),
		larkws.WithLogger(stderrLogger{}),
		larkws.WithAutoReconnect(true),
		larkws.WithOnReady(func() {
			b.mu.Lock()
			paired := b.openID != ""
			b.mu.Unlock()
			if paired {
				b.emitStatus("online", "长连接已就绪，审批会发到已绑定的飞书。")
			} else {
				b.emitStatus("online", "长连接已就绪。给机器人发一条私聊后再在 Mac 上绑定。")
			}
		}),
		larkws.WithOnDisconnected(func() {
			b.emitStatus("offline", "长连接断开了，正在重连。断开期间不会自动允许。")
		}),
		larkws.WithOnReconnecting(func() {
			b.emitStatus("connecting", "正在重连飞书。")
		}),
		larkws.WithOnReconnected(func() {
			b.emitStatus("online", "飞书长连接已恢复。")
		}),
	)
	err := cli.Start(ctx)
	if ctx.Err() != nil {
		return
	}
	if err != nil {
		b.emitStatus("error", "长连接结束："+err.Error())
	}
}

func (b *bridge) onMessage(_ context.Context, event *larkim.P2MessageReceiveV1) error {
	if event == nil || event.Event == nil || event.Event.Message == nil || event.Event.Sender == nil {
		return nil
	}
	message := event.Event.Message
	sender := event.Event.Sender
	if message.ChatType == nil || *message.ChatType != "p2p" {
		return nil
	}
	if sender.SenderType != nil && *sender.SenderType == "app" {
		return nil
	}
	openID := ""
	if sender.SenderId != nil && sender.SenderId.OpenId != nil {
		openID = strings.TrimSpace(*sender.SenderId.OpenId)
	}
	if openID == "" || message.MessageId == nil {
		return nil
	}
	b.mu.Lock()
	paired := b.openID
	arm := b.armBind
	b.mu.Unlock()
	switch {
	case paired != "" && openID == paired:
		b.reply(*message.MessageId, "审批只能点卡片上的「允许一次」或「拒绝」。文字回复不会执行命令。")
	case paired != "" && openID != paired:
		b.reply(*message.MessageId, "这个机器人只给已绑定的飞书账号发审批。")
	case arm:
		b.emit(map[string]any{"op": "pair_candidate", "open_id": openID})
		b.reply(*message.MessageId, "已收到。请回到 Mac 的 CodeIsland 设置里点「绑定这个账号」。文字不会批准命令。")
	default:
		b.reply(*message.MessageId, "请先在 Mac 的 CodeIsland 设置里点「开始绑定」，再给机器人发消息。")
	}
	return nil
}

func (b *bridge) onCard(_ context.Context, event *callback.CardActionTriggerEvent) (*callback.CardActionTriggerResponse, error) {
	if event == nil || event.Event == nil || event.Event.Operator == nil || event.Event.Action == nil {
		return toast("error", "这张卡片没有有效的操作。"), nil
	}
	openID := strings.TrimSpace(event.Event.Operator.OpenID)
	requestID, decision, ok := parseDecision(event.Event.Action.Value)
	if !ok {
		return toast("error", "只有卡片上的允许一次或拒绝才有效。"), nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.openID == "" || openID != b.openID {
		return toast("error", "这个飞书账号不能审批这台 Mac。"), nil
	}
	track := b.cards[requestID]
	if track == nil || track.done {
		return toast("error", "这条审批已经结束。"), nil
	}
	if time.Now().Before(track.inflightUntil) {
		return toast("info", "正在让 Mac 处理，请不要重复点。"), nil
	}
	track.inflightUntil = time.Now().Add(20 * time.Second)
	b.emitLocked(map[string]any{
		"op":         "card_action",
		"request_id": requestID,
		"decision":   decision,
		"open_id":    openID,
	})
	return &callback.CardActionTriggerResponse{
		Toast: toastBody("info", "已送到 Mac，等待这台电脑执行。"),
		Card: &callback.Card{
			Type: "raw",
			Data: cardDocument(cardText("处理中", "已点「"+decisionLabel(decision)+"」。正在等 Mac 确认。"), "orange", false, "", ""),
		},
	}, nil
}

func (b *bridge) sendCard(msg map[string]any) {
	requestID, _ := msg["request_id"].(string)
	requestID = strings.TrimSpace(requestID)
	if requestID == "" {
		return
	}
	b.mu.Lock()
	openID := b.openID
	api := b.api
	if _, exists := b.cards[requestID]; exists {
		b.mu.Unlock()
		return
	}
	b.cards[requestID] = &cardTrack{}
	b.mu.Unlock()
	if openID == "" || api == nil {
		b.emitLog("card not sent; Feishu account is not bound or the connection is down")
		return
	}
	body := cardTextFrom(msg)
	content, err := json.Marshal(cardDocument(body, "orange", true, requestID, ""))
	if err != nil {
		b.emitLog("could not build the card")
		return
	}
	req := larkim.NewCreateMessageReqBuilder().
		ReceiveIdType(larkim.CreateMessageV1ReceiveIDTypeOpenId).
		Body(larkim.NewCreateMessageReqBodyBuilder().
			ReceiveId(openID).
			MsgType(larkim.MsgTypeInteractive).
			Content(string(content)).
			Uuid(requestID).
			Build()).
		Build()
	resp, err := api.Im.Message.Create(context.Background(), req)
	if err != nil || resp == nil || !resp.Success() || resp.Data == nil || resp.Data.MessageId == nil {
		detail := "send failed"
		if err != nil {
			detail = err.Error()
		} else if resp != nil {
			detail = fmt.Sprintf("code %d", resp.Code)
		}
		b.emitLog("card send failed: " + detail)
		return
	}
	b.mu.Lock()
	if track := b.cards[requestID]; track != nil {
		track.messageID = *resp.Data.MessageId
	}
	b.mu.Unlock()
}

func (b *bridge) markResolved(requestID, decision string) {
	if requestID == "" {
		return
	}
	if decision != "allow" && decision != "deny" && decision != "gone" {
		decision = "gone"
	}
	b.mu.Lock()
	track := b.cards[requestID]
	if track == nil {
		b.mu.Unlock()
		return
	}
	track.done = true
	track.decision = decision
	track.inflightUntil = time.Time{}
	messageID := track.messageID
	api := b.api
	b.mu.Unlock()
	if messageID == "" || api == nil {
		return
	}
	title, template := resolvedCopy(decision)
	content, err := json.Marshal(cardDocument(title, template, false, "", ""))
	if err != nil {
		return
	}
	req := larkim.NewPatchMessageReqBuilder().
		MessageId(messageID).
		Body(larkim.NewPatchMessageReqBodyBuilder().Content(string(content)).Build()).
		Build()
	resp, err := api.Im.Message.Patch(context.Background(), req)
	if err != nil || resp == nil || !resp.Success() {
		b.emitLog("card update failed")
	}
}

func (b *bridge) reply(messageID, text string) {
	b.mu.Lock()
	api := b.api
	b.mu.Unlock()
	if api == nil || messageID == "" {
		return
	}
	content, _ := json.Marshal(map[string]string{"text": text})
	req := larkim.NewReplyMessageReqBuilder().
		MessageId(messageID).
		Body(larkim.NewReplyMessageReqBodyBuilder().
			MsgType(larkim.MsgTypeText).
			Content(string(content)).
			Build()).
		Build()
	_, _ = api.Im.Message.Reply(context.Background(), req)
}

func (b *bridge) emitStatus(state, detail string) {
	b.emit(map[string]any{"op": "status", "state": state, "detail": detail})
}

func (b *bridge) emitLog(message string) {
	b.emit(map[string]any{"op": "log", "message": message})
}

func (b *bridge) emit(payload map[string]any) {
	b.mu.Lock()
	b.emitLocked(payload)
	b.mu.Unlock()
}

func (b *bridge) emitLocked(payload map[string]any) {
	b.emitMu.Lock()
	defer b.emitMu.Unlock()
	encoded, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_, _ = os.Stdout.Write(append(encoded, '\n'))
}

func parseDecision(value map[string]any) (string, string, bool) {
	if value == nil {
		return "", "", false
	}
	id, _ := value["request_id"].(string)
	decision, _ := value["decision"].(string)
	id = strings.TrimSpace(id)
	decision = strings.TrimSpace(decision)
	if id == "" || (decision != "allow" && decision != "deny") {
		return "", "", false
	}
	return id, decision, true
}

func decisionLabel(decision string) string {
	if decision == "allow" {
		return "允许一次"
	}
	return "拒绝"
}

func resolvedCopy(decision string) (string, string) {
	switch decision {
	case "allow":
		return "已允许这一次。没有记住为始终允许。", "green"
	case "deny":
		return "已拒绝。命令不会执行。", "red"
	default:
		return "这条审批已经结束，没有从飞书执行。", "grey"
	}
}

func cardTextFrom(msg map[string]any) string {
	source, _ := msg["source"].(string)
	tool, _ := msg["tool"].(string)
	cwd, _ := msg["cwd"].(string)
	command, _ := msg["command"].(string)
	session, _ := msg["session"].(string)
	var lines []string
	if source != "" {
		lines = append(lines, "来源："+source)
	}
	if tool != "" {
		lines = append(lines, "工具："+tool)
	}
	if cwd != "" {
		lines = append(lines, "目录："+cwd)
	}
	if session != "" {
		lines = append(lines, "会话："+session)
	}
	lines = append(lines, "", clip(command, 1800))
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func cardText(title, body string) string {
	return title + "\n" + body
}

func cardDocument(body, template string, withButtons bool, requestID, _ string) map[string]any {
	elements := []any{
		map[string]any{
			"tag":  "div",
			"text": map[string]any{"tag": "plain_text", "content": clip(body, 1800)},
		},
	}
	if withButtons {
		elements = append(elements, map[string]any{
			"tag": "action",
			"actions": []any{
				button("允许一次", "primary", requestID, "allow"),
				button("拒绝", "danger", requestID, "deny"),
			},
		})
	}
	return map[string]any{
		"config": map[string]any{"wide_screen_mode": true},
		"header": map[string]any{
			"template": template,
			"title":    map[string]any{"tag": "plain_text", "content": "CodeIsland 审批"},
		},
		"elements": elements,
	}
}

func button(label, kind, requestID, decision string) map[string]any {
	return map[string]any{
		"tag":  "button",
		"type": kind,
		"text": map[string]any{"tag": "plain_text", "content": label},
		"value": map[string]string{
			"request_id": requestID,
			"decision":   decision,
		},
	}
}

func toast(kind, content string) *callback.CardActionTriggerResponse {
	return &callback.CardActionTriggerResponse{Toast: toastBody(kind, content)}
}

func toastBody(kind, content string) *callback.Toast {
	return &callback.Toast{Type: kind, Content: content}
}

func clip(value string, limit int) string {
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit-1]) + "…"
}

