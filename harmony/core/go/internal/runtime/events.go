package runtime

import "sync"

type RuntimeEvent struct {
	Kind         string
	State        RuntimeState
	Message      string
	HTTPAddress  string
	SOCKSAddress string
}

type EventSink interface {
	Publish(RuntimeEvent)
}

type EventFunc func(RuntimeEvent)

func (fn EventFunc) Publish(event RuntimeEvent) {
	fn(event)
}

type EventBuffer struct {
	mu     sync.Mutex
	events []RuntimeEvent
}

func (b *EventBuffer) Publish(event RuntimeEvent) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.events = append(b.events, event)
}

func (b *EventBuffer) Events() []RuntimeEvent {
	b.mu.Lock()
	defer b.mu.Unlock()
	cloned := make([]RuntimeEvent, len(b.events))
	copy(cloned, b.events)
	return cloned
}

type DiscardEvents struct{}

func (DiscardEvents) Publish(RuntimeEvent) {}

type LogLevel string

const (
	LogLevelDebug LogLevel = "debug"
	LogLevelInfo  LogLevel = "info"
	LogLevelWarn  LogLevel = "warn"
	LogLevelError LogLevel = "error"
)

type RuntimeLog struct {
	Level    LogLevel
	Category string
	Message  string
	Context  map[string]string
}

type LogSink interface {
	Publish(RuntimeLog)
}

type LogFunc func(RuntimeLog)

func (fn LogFunc) Publish(log RuntimeLog) {
	fn(log)
}

type LogBuffer struct {
	mu         sync.Mutex
	maxEntries int
	logs       []RuntimeLog
}

func NewLogBuffer(maxEntries int) *LogBuffer {
	if maxEntries <= 0 {
		maxEntries = 1
	}
	return &LogBuffer{maxEntries: maxEntries}
}

func (b *LogBuffer) Publish(log RuntimeLog) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.logs) == b.maxEntries {
		copy(b.logs, b.logs[1:])
		b.logs[len(b.logs)-1] = cloneRuntimeLog(log)
		return
	}
	b.logs = append(b.logs, cloneRuntimeLog(log))
}

func (b *LogBuffer) Logs() []RuntimeLog {
	b.mu.Lock()
	defer b.mu.Unlock()
	cloned := make([]RuntimeLog, len(b.logs))
	for i, log := range b.logs {
		cloned[i] = cloneRuntimeLog(log)
	}
	return cloned
}

func (b *LogBuffer) Take() (RuntimeLog, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.logs) == 0 {
		return RuntimeLog{}, false
	}
	next := cloneRuntimeLog(b.logs[0])
	b.logs = append([]RuntimeLog(nil), b.logs[1:]...)
	return next, true
}

type DiscardLogs struct{}

func (DiscardLogs) Publish(RuntimeLog) {}

func cloneRuntimeLog(log RuntimeLog) RuntimeLog {
	cloned := RuntimeLog{
		Level:    log.Level,
		Category: log.Category,
		Message:  log.Message,
	}
	if len(log.Context) > 0 {
		cloned.Context = make(map[string]string, len(log.Context))
		for key, value := range log.Context {
			cloned.Context[key] = value
		}
	}
	return cloned
}
