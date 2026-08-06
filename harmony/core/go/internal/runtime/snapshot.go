package runtime

type RuntimeState string

const (
	RuntimeStopped  RuntimeState = "stopped"
	RuntimeStarting RuntimeState = "starting"
	RuntimeRunning  RuntimeState = "running"
	RuntimeStopping RuntimeState = "stopping"
	RuntimeError    RuntimeState = "error"
)

type Snapshot struct {
	State            RuntimeState
	ActiveConfigPath string
	HTTPAddress      string
	SOCKSAddress     string
	LastError        string
}

type StartOptions struct {
	ConfigPath         string
	HTTPListenAddress  string
	SOCKSListenAddress string
}
