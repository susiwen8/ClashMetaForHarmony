package probe

import (
	"context"
	"fmt"
	"time"

	mihomoconstant "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const trackerPollInterval = 25 * time.Millisecond

func AwaitRealTracker(ctx context.Context, observation FlowObservation) (TrackerRecord, error) {
	sourcePort, err := sourcePortFromAddress(observation.ClientLocalAddress)
	if err != nil {
		return TrackerRecord{}, err
	}

	inboundType, err := inboundTypeForProtocol(observation.Protocol)
	if err != nil {
		return TrackerRecord{}, err
	}

	ticker := time.NewTicker(trackerPollInterval)
	defer ticker.Stop()

	for {
		record, ok := findMatchingTracker(sourcePort, observation.TargetAddress, inboundType)
		if ok {
			return record, nil
		}

		select {
		case <-ctx.Done():
			return TrackerRecord{}, &Error{
				Code:   "TRACKER_TIMEOUT",
				Stage:  "tracker",
				Detail: fmt.Sprintf("timed out waiting for tracker srcPort=%d dst=%s inbound=%s", sourcePort, observation.TargetAddress, inboundType),
			}
		case <-ticker.C:
		}
	}
}

func inboundTypeForProtocol(protocol Protocol) (string, error) {
	switch protocol {
	case ProtocolHTTPConnect:
		return mihomoconstant.HTTPS.String(), nil
	case ProtocolSOCKS5:
		return mihomoconstant.SOCKS5.String(), nil
	default:
		return "", &Error{Code: "PROTOCOL_UNSUPPORTED", Stage: "tracker", Detail: fmt.Sprintf("unsupported protocol %q", protocol)}
	}
}

func findMatchingTracker(sourcePort uint16, targetAddress string, inboundType string) (TrackerRecord, bool) {
	var record TrackerRecord
	found := false
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		info := tracker.Info()
		if info == nil || info.Metadata == nil {
			return true
		}

		metadata := info.Metadata
		if metadata.SrcPort != sourcePort {
			return true
		}
		if metadata.Type.String() != inboundType {
			return true
		}
		if metadata.RemoteAddress() != targetAddress {
			return true
		}

		record = TrackerRecord{
			ConnectionID:       tracker.ID(),
			SourceAddress:      metadata.SourceAddress(),
			DestinationAddress: metadata.RemoteAddress(),
			InboundType:        metadata.Type.String(),
			OpenedAt:           info.Start.UTC(),
		}
		found = true
		return false
	})
	return record, found
}
