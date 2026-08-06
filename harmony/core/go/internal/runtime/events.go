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
