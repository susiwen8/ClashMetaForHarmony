package events

import "sync"

type Event struct {
	Kind    string
	Message string
}

type Sink interface {
	Publish(Event)
}

type Func func(Event)

func (fn Func) Publish(event Event) {
	fn(event)
}

type Buffer struct {
	mu     sync.Mutex
	events []Event
}

func (b *Buffer) Publish(event Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.events = append(b.events, event)
}

func (b *Buffer) Events() []Event {
	b.mu.Lock()
	defer b.mu.Unlock()
	cloned := make([]Event, len(b.events))
	copy(cloned, b.events)
	return cloned
}
