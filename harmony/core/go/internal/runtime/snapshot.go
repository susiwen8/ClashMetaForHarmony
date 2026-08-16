package runtime

type RuntimeState string

const (
	RuntimeStopped  RuntimeState = "stopped"
	RuntimeStarting RuntimeState = "starting"
	RuntimeRunning  RuntimeState = "running"
	RuntimeStopping RuntimeState = "stopping"
	RuntimeError    RuntimeState = "error"
)

type TunState string

const (
	TunStateIdle     TunState = "idle"
	TunStateStarting TunState = "starting"
	TunStateReady    TunState = "ready"
	TunStateStopped  TunState = "stopped"
	TunStateError    TunState = "error"
)

type Snapshot struct {
	State            RuntimeState
	ActiveConfigPath string
	HTTPAddress      string
	SOCKSAddress     string
	LastError        string
}

type TunCounters struct {
	TXPackets uint64
	TXBytes   uint64
	RXPackets uint64
	RXBytes   uint64
}

type TunFailure struct {
	Code   string
	Detail string
}

type TunTrace struct {
	SessionID        string
	TraceID          string
	Ingress          string
	Protocol         string
	SourceAddress    string
	DestinationAddress string
	HashedTuple      string
	CorrelationHash  string
}

type TunSnapshot struct {
	State     TunState
	SessionID string
	Counters  TunCounters
	Failure   TunFailure
}

type StartOptions struct {
	ConfigPath         string
	HTTPListenAddress  string
	SOCKSListenAddress string
}

type TunStartOptions struct {
	SessionID        string
	TunFD            int
	Base             StartOptions
	PlatformAPILevel int
	ProcessProtected bool
}
