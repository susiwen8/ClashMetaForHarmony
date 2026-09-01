package proxygroups

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
)

const ErrCodeDelayJobNotFound ErrorCode = "DELAY_JOB_NOT_FOUND"

type DelayProbe func(context.Context) (uint16, error)

type DelayRuntimeNode struct {
	Name    string
	Type    string
	IsGroup bool
	Source  *DelayURLSource
	Probe   DelayProbe
}

type DelayRuntimeRegistry interface {
	DelayNodes(groupName string) ([]DelayRuntimeNode, error)
}

type DelayJobIDSource func() (string, error)

type DelayJobManagerOption func(*DelayJobManager)

type DelayJobManager struct {
	registry DelayRuntimeRegistry
	newJobID DelayJobIDSource

	lifecycleMu sync.Mutex
	mu          sync.Mutex
	current     *delayJob
}

type delayJob struct {
	ctx       QueryContext
	groupName string
	jobID     string

	cancel context.CancelFunc
	done   chan struct{}

	mu    sync.Mutex
	state DelayJobState
	nodes []DelayNodeResult
	final bool
}

type delayTask struct {
	index int
	probe DelayProbe
}

func NewDelayJobManager(registry DelayRuntimeRegistry, opts ...DelayJobManagerOption) *DelayJobManager {
	manager := &DelayJobManager{
		registry: registry,
		newJobID: defaultDelayJobIDSource,
	}
	for _, opt := range opts {
		if opt != nil {
			opt(manager)
		}
	}
	if manager.newJobID == nil {
		manager.newJobID = defaultDelayJobIDSource
	}
	return manager
}

func WithDelayJobIDSource(source DelayJobIDSource) DelayJobManagerOption {
	return func(manager *DelayJobManager) {
		manager.newJobID = source
	}
}

func (m *DelayJobManager) Start(ctx QueryContext, groupName string) (DelayTestSnapshot, error) {
	if err := ctx.Validate(); err != nil {
		return DelayTestSnapshot{}, err
	}
	if err := validateName(groupName); err != nil {
		return DelayTestSnapshot{}, err
	}
	m.lifecycleMu.Lock()
	defer m.lifecycleMu.Unlock()

	if err := m.cancelActiveAndDrainLocked(); err != nil {
		return DelayTestSnapshot{}, err
	}
	if m.registry == nil {
		return DelayTestSnapshot{}, newModelError(ErrCodeProxyRuntimeNotReady)
	}

	nodes, err := m.registry.DelayNodes(groupName)
	if err != nil {
		return DelayTestSnapshot{}, err
	}
	jobID, err := m.newJobID()
	if err != nil {
		return DelayTestSnapshot{}, err
	}
	if !delayJobIDPattern.MatchString(jobID) {
		return DelayTestSnapshot{}, newModelError(ErrCodeInvalidDelaySnapshot)
	}
	if m.currentHasJobID(jobID) {
		return DelayTestSnapshot{}, newModelError(ErrCodeInvalidDelaySnapshot)
	}

	results, tasks := buildDelayJobNodes(nodes)
	initialState := DelayJobStateRunning
	if len(tasks) == 0 {
		initialState = DelayJobStateCompleted
	}

	snapshot, err := NewDelayTestSnapshot(ctx, jobID, initialState, groupName, results)
	if err != nil {
		return DelayTestSnapshot{}, err
	}

	job := &delayJob{
		ctx:       ctx,
		groupName: groupName,
		jobID:     jobID,
		done:      make(chan struct{}),
		state:     snapshot.State,
		nodes:     cloneDelayNodeResults(snapshot.Nodes),
		final:     snapshot.State != DelayJobStateRunning,
	}
	if job.final {
		close(job.done)
	} else {
		rootCtx, cancel := context.WithCancel(context.Background())
		job.cancel = cancel
		m.setCurrent(job)
		go runDelayJob(rootCtx, job, tasks)
		return snapshot, nil
	}

	m.setCurrent(job)
	return snapshot, nil
}

func (m *DelayJobManager) Read(jobID string) (DelayTestSnapshot, error) {
	job, err := m.currentJob(jobID)
	if err != nil {
		return DelayTestSnapshot{}, err
	}
	return job.snapshot()
}

func (m *DelayJobManager) Cancel(jobID string) (DelayTestSnapshot, error) {
	m.lifecycleMu.Lock()
	defer m.lifecycleMu.Unlock()

	job, err := m.currentJob(jobID)
	if err != nil {
		return DelayTestSnapshot{}, err
	}
	return job.cancelAndWait()
}

func (m *DelayJobManager) CancelActiveAndDrain() error {
	m.lifecycleMu.Lock()
	defer m.lifecycleMu.Unlock()

	return m.cancelActiveAndDrainLocked()
}

func (m *DelayJobManager) InvalidateActiveIfNot(ctx QueryContext, groupName string) error {
	m.lifecycleMu.Lock()
	defer m.lifecycleMu.Unlock()

	job := m.runningJobLocked()
	if job == nil {
		return nil
	}
	if job.matches(ctx, groupName) {
		return nil
	}
	_, err := job.cancelAndWait()
	return err
}

func (m *DelayJobManager) currentJob(jobID string) (*delayJob, error) {
	if !delayJobIDPattern.MatchString(jobID) {
		return nil, newModelError(ErrCodeDelayJobNotFound)
	}

	m.mu.Lock()
	job := m.current
	m.mu.Unlock()

	if job == nil || job.jobID != jobID {
		return nil, newModelError(ErrCodeDelayJobNotFound)
	}
	return job, nil
}

func (m *DelayJobManager) runningJobLocked() *delayJob {
	m.mu.Lock()
	job := m.current
	m.mu.Unlock()

	if job == nil || !job.isRunning() {
		return nil
	}
	return job
}

func (m *DelayJobManager) cancelActiveAndDrainLocked() error {
	job := m.runningJobLocked()
	if job == nil {
		return nil
	}
	_, err := job.cancelAndWait()
	return err
}

func (m *DelayJobManager) currentHasJobID(jobID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.current != nil && m.current.jobID == jobID
}

func (m *DelayJobManager) setCurrent(job *delayJob) {
	m.mu.Lock()
	m.current = job
	m.mu.Unlock()
}

func runDelayJob(rootCtx context.Context, job *delayJob, tasks []delayTask) {
	queue := make(chan delayTask, len(tasks))
	for _, task := range tasks {
		queue <- task
	}
	close(queue)

	var workers sync.WaitGroup
	for i := 0; i < DelayWorkerCount; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for task := range queue {
				if rootCtx.Err() != nil {
					job.publishNode(task.index, DelayNodeStateCancelled, nil)
					continue
				}
				if !job.markTesting(task.index) {
					continue
				}

				probeCtx, cancel := context.WithTimeout(rootCtx, DelayNodeTimeout)
				delay, err := task.probe(probeCtx)
				cancel()
				state, delayValue := classifyDelayProbeResult(delay, err)
				job.publishNode(task.index, state, delayValue)
			}
		}()
	}

	workers.Wait()
	job.finish(rootCtx.Err() != nil)
}

func buildDelayJobNodes(nodes []DelayRuntimeNode) ([]DelayNodeResult, []delayTask) {
	results := make([]DelayNodeResult, 0, len(nodes))
	tasks := make([]delayTask, 0, len(nodes))
	for index, node := range nodes {
		result := DelayNodeResult{
			Index: index,
			Name:  node.Name,
			Type:  node.Type,
		}
		if node.IsGroup || node.Probe == nil {
			result.State = DelayNodeStateUnsupported
			results = append(results, result)
			continue
		}

		result.State = DelayNodeStateWaiting
		result.Source = cloneDelayURLSourcePtr(node.Source)
		results = append(results, result)
		tasks = append(tasks, delayTask{index: index, probe: node.Probe})
	}
	return results, tasks
}

func defaultDelayJobIDSource() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

func classifyDelayProbeResult(delay uint16, err error) (DelayNodeState, *uint16) {
	if err == nil {
		if delay == 0 {
			return DelayNodeStateFailed, nil
		}
		value := delay
		return DelayNodeStateAvailable, &value
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return DelayNodeStateTimeout, nil
	}
	if errors.Is(err, context.Canceled) {
		return DelayNodeStateCancelled, nil
	}
	return DelayNodeStateFailed, nil
}

func (j *delayJob) matches(ctx QueryContext, groupName string) bool {
	if j == nil {
		return false
	}
	if j.groupName != groupName {
		return false
	}
	if j.ctx.ProfileHash != ctx.ProfileHash || j.ctx.RevisionHash != ctx.RevisionHash || j.ctx.Generation != ctx.Generation {
		return false
	}
	switch {
	case j.ctx.SessionHash == nil || ctx.SessionHash == nil:
		return j.ctx.SessionHash == nil && ctx.SessionHash == nil
	default:
		return *j.ctx.SessionHash == *ctx.SessionHash
	}
}

func (j *delayJob) isRunning() bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	return !j.final && j.state == DelayJobStateRunning
}

func (j *delayJob) markTesting(index int) bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.final || j.nodes[index].State != DelayNodeStateWaiting {
		return false
	}
	j.nodes[index].State = DelayNodeStateTesting
	j.nodes[index].DelayMs = nil
	return true
}

func (j *delayJob) publishNode(index int, state DelayNodeState, delay *uint16) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.final {
		return
	}
	if !isLiveDelayNodeState(j.nodes[index].State) {
		return
	}
	j.nodes[index].State = state
	j.nodes[index].DelayMs = cloneUint16Ptr(delay)
}

func (j *delayJob) finish(cancelled bool) {
	j.mu.Lock()
	if j.final {
		j.mu.Unlock()
		return
	}
	if cancelled {
		j.state = DelayJobStateCancelled
	} else {
		j.state = deriveDelayJobState(j.nodes)
	}
	j.final = true
	j.mu.Unlock()
	close(j.done)
}

func (j *delayJob) cancelAndWait() (DelayTestSnapshot, error) {
	if j == nil {
		return DelayTestSnapshot{}, newModelError(ErrCodeDelayJobNotFound)
	}

	j.mu.Lock()
	cancel := j.cancel
	done := j.done
	j.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	<-done
	return j.snapshot()
}

func (j *delayJob) snapshot() (DelayTestSnapshot, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	return NewDelayTestSnapshot(j.ctx, j.jobID, j.state, j.groupName, j.nodes)
}

func deriveDelayJobState(nodes []DelayNodeResult) DelayJobState {
	return DelayJobStateCompleted
}
