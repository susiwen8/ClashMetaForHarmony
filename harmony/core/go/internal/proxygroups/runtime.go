package proxygroups

import "sync"

const (
	ErrCodeProxyRuntimeNotReady    ErrorCode = "PROXY_RUNTIME_NOT_READY"
	ErrCodeProxyGroupNotFound      ErrorCode = "PROXY_GROUP_NOT_FOUND"
	ErrCodeProxyGroupNotSelectable ErrorCode = "PROXY_GROUP_NOT_SELECTABLE"
	ErrCodeProxyMemberNotFound     ErrorCode = "PROXY_MEMBER_NOT_FOUND"
	ErrCodeProxySelectionFailed    ErrorCode = "PROXY_SELECTION_FAILED"
	ErrCodeProxyBridgeInvalid      ErrorCode = "PROXY_BRIDGE_INVALID"
)

type RuntimeNode struct {
	Name    string
	Type    string
	IsGroup bool
}

type RuntimeGroupReference struct {
	Name   string
	Type   string
	Hidden bool
}

type RuntimeGroupSnapshot struct {
	Name    string
	Type    string
	Hidden  bool
	Current string
	Members []RuntimeNode
}

type RuntimeGroup interface {
	Snapshot() (RuntimeGroupSnapshot, error)
	Set(name string) error
}

type RuntimeGroupReferenceProvider interface {
	Reference() (RuntimeGroupReference, error)
}

type RuntimeRegistry interface {
	ActiveGroups() ([]RuntimeGroup, error)
	Group(name string) (RuntimeGroup, error)
	CloseConnectionsForGroup(name string)
}

type Service struct {
	mu       sync.Mutex
	registry RuntimeRegistry
}

func NewService(registry RuntimeRegistry) *Service {
	return &Service{registry: registry}
}

func (s *Service) ListGroups(ctx QueryContext, selectableOnly bool) ([]byte, error) {
	if err := ctx.Validate(); err != nil {
		return nil, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	groups, err := s.runtimeRegistry().ActiveGroups()
	if err != nil {
		return nil, err
	}

	refs := make([]GroupRef, 0, len(groups))
	seen := make(map[string]struct{}, len(groups))
	for _, group := range groups {
		reference, err := resolveRuntimeGroupReference(group)
		if err != nil {
			return nil, err
		}
		if reference.Hidden {
			continue
		}
		if selectableOnly && reference.Type != "Selector" {
			continue
		}
		if err := validateBridgeGroupRef(reference.Name, reference.Type); err != nil {
			return nil, err
		}
		if _, ok := seen[reference.Name]; ok {
			return nil, newModelError(ErrCodeProxyBridgeInvalid)
		}
		seen[reference.Name] = struct{}{}
		refs = append(refs, GroupRef{Name: reference.Name, Type: reference.Type})
	}

	envelope, err := NewGroupListEnvelope(ctx, refs)
	if err != nil {
		return nil, err
	}
	return envelope.MarshalJSONBytes()
}

func resolveRuntimeGroupReference(group RuntimeGroup) (RuntimeGroupReference, error) {
	if provider, ok := group.(RuntimeGroupReferenceProvider); ok {
		return provider.Reference()
	}
	snapshot, err := group.Snapshot()
	if err != nil {
		return RuntimeGroupReference{}, err
	}
	return RuntimeGroupReference{
		Name:   snapshot.Name,
		Type:   snapshot.Type,
		Hidden: snapshot.Hidden,
	}, nil
}

func (s *Service) QueryGroup(ctx QueryContext, groupName string) ([]byte, error) {
	if err := ctx.Validate(); err != nil {
		return nil, err
	}
	if err := validateName(groupName); err != nil {
		return nil, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	group, err := s.runtimeRegistry().Group(groupName)
	if err != nil {
		return nil, err
	}

	snapshot, err := buildGroupSnapshot(group)
	if err != nil {
		return nil, err
	}

	envelope, err := NewGroupSnapshotEnvelope(ctx, snapshot)
	if err != nil {
		return nil, err
	}
	return envelope.MarshalJSONBytes()
}

func (s *Service) Select(ctx QueryContext, groupName, memberName string) ([]byte, error) {
	if err := ctx.Validate(); err != nil {
		return nil, err
	}
	if err := validateName(groupName); err != nil {
		return nil, err
	}
	if err := validateName(memberName); err != nil {
		return nil, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	registry := s.runtimeRegistry()
	group, err := registry.Group(groupName)
	if err != nil {
		return nil, err
	}

	before, err := buildGroupSnapshot(group)
	if err != nil {
		return nil, err
	}
	if before.Type != "Selector" {
		return nil, newModelError(ErrCodeProxyGroupNotSelectable)
	}
	if !containsMember(before.Nodes, memberName) {
		return nil, newModelError(ErrCodeProxyMemberNotFound)
	}

	if err := group.Set(memberName); err != nil {
		return nil, newModelError(ErrCodeProxySelectionFailed)
	}

	after, err := buildGroupSnapshot(group)
	if err != nil {
		return nil, err
	}
	if after.SelectedName != memberName {
		return nil, newModelError(ErrCodeProxySelectionFailed)
	}

	registry.CloseConnectionsForGroup(groupName)

	envelope, err := NewSelectionAppliedEnvelope(ctx, after, before.SelectedName)
	if err != nil {
		return nil, err
	}
	return envelope.MarshalJSONBytes()
}

func (s *Service) runtimeRegistry() RuntimeRegistry {
	if s.registry != nil {
		return s.registry
	}
	return newMihomoRegistry()
}

func buildGroupSnapshot(group RuntimeGroup) (GroupSnapshot, error) {
	runtimeSnapshot, err := group.Snapshot()
	if err != nil {
		return GroupSnapshot{}, err
	}

	if err := validateBridgeGroupRef(runtimeSnapshot.Name, runtimeSnapshot.Type); err != nil {
		return GroupSnapshot{}, err
	}
	if len(runtimeSnapshot.Members) > MaxMemberCount {
		return GroupSnapshot{}, newModelError(ErrCodeMemberCountExceeded)
	}

	nodes := make([]NodeSummary, 0, len(runtimeSnapshot.Members))
	seen := make(map[string]struct{}, len(runtimeSnapshot.Members))
	selectedCount := 0
	if len(runtimeSnapshot.Members) > 0 && runtimeSnapshot.Current == "" {
		return GroupSnapshot{}, newModelError(ErrCodeProxyBridgeInvalid)
	}

	for _, member := range runtimeSnapshot.Members {
		if err := validateBridgeGroupRef(member.Name, member.Type); err != nil {
			return GroupSnapshot{}, err
		}
		if _, ok := seen[member.Name]; ok {
			return GroupSnapshot{}, newModelError(ErrCodeProxyBridgeInvalid)
		}
		seen[member.Name] = struct{}{}

		selected := runtimeSnapshot.Current == member.Name
		if selected {
			selectedCount++
		}

		nodes = append(nodes, NodeSummary{
			Name:     member.Name,
			Type:     member.Type,
			IsGroup:  member.IsGroup,
			Selected: selected,
		})
	}

	if runtimeSnapshot.Current != "" && selectedCount != 1 {
		return GroupSnapshot{}, newModelError(ErrCodeProxyBridgeInvalid)
	}

	groupSnapshot := GroupSnapshot{
		Name:         runtimeSnapshot.Name,
		Type:         runtimeSnapshot.Type,
		SelectedName: runtimeSnapshot.Current,
		Nodes:        nodes,
	}
	if err := groupSnapshot.Validate(); err != nil {
		return GroupSnapshot{}, newModelError(ErrCodeProxyBridgeInvalid)
	}
	return groupSnapshot, nil
}

func validateBridgeGroupRef(name, typeName string) error {
	if err := validateName(name); err != nil {
		return newModelError(ErrCodeProxyBridgeInvalid)
	}
	if !isAllowedType(typeName) {
		return newModelError(ErrCodeProxyBridgeInvalid)
	}
	return nil
}

func containsMember(nodes []NodeSummary, memberName string) bool {
	for _, node := range nodes {
		if node.Name == memberName {
			return true
		}
	}
	return false
}

func cloneRuntimeGroupSnapshot(snapshot RuntimeGroupSnapshot) RuntimeGroupSnapshot {
	if snapshot.Members == nil {
		return snapshot
	}
	snapshot.Members = append([]RuntimeNode(nil), snapshot.Members...)
	return snapshot
}
