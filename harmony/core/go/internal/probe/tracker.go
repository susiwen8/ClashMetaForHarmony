package probe

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"

	mihomoconstant "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const trackerPollInterval = 25 * time.Millisecond

func AwaitRealTracker(ctx context.Context, observation FlowObservation) (TrackerRecord, error) {
	matcher, err := newTrackerObservation(observation.ClientLocalAddress, observation.TargetAddress, "")
	if err != nil {
		return TrackerRecord{}, err
	}

	inboundType, err := inboundTypeForProtocol(observation.Protocol)
	if err != nil {
		return TrackerRecord{}, err
	}
	matcher.inboundType = inboundType

	ticker := time.NewTicker(trackerPollInterval)
	defer ticker.Stop()

	for {
		record, ok := findMatchingTracker(matcher)
		if ok {
			return record, nil
		}

		select {
		case <-ctx.Done():
			if ctxErr := contextErrorForStage(ctx, "tracker", ctx.Err()); ctxErr != nil {
				if ctxErr.Code == "TRACKER_TIMEOUT" {
					ctxErr.Detail = fmt.Sprintf("timed out waiting for tracker src=%s dst=%s inbound=%s",
						matcher.sourceAddress, matcher.targetAddress, matcher.inboundType)
				}
				return TrackerRecord{}, ctxErr
			}
			return TrackerRecord{}, &Error{
				Code:   "TRACKER_TIMEOUT",
				Stage:  "tracker",
				Detail: fmt.Sprintf("timed out waiting for tracker src=%s dst=%s inbound=%s", matcher.sourceAddress, matcher.targetAddress, matcher.inboundType),
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

type trackerObservation struct {
	sourceAddress string
	targetAddress string
	inboundType   string
}

func newTrackerObservation(sourceAddress string, targetAddress string, inboundType string) (trackerObservation, error) {
	normalizedSource, err := normalizeTrackerAddress(sourceAddress)
	if err != nil {
		return trackerObservation{}, &Error{Code: "CLIENT_ADDRESS_INVALID", Stage: "tracker", Detail: sanitizeProbeDetail(err.Error())}
	}
	return trackerObservation{
		sourceAddress: normalizedSource,
		targetAddress: targetAddress,
		inboundType:   inboundType,
	}, nil
}

func (observation trackerObservation) matches(sourceAddress string, targetAddress string, inboundType string) bool {
	normalizedSource, err := normalizeTrackerAddress(sourceAddress)
	if err != nil {
		return false
	}
	return normalizedSource == observation.sourceAddress &&
		targetAddress == observation.targetAddress &&
		inboundType == observation.inboundType
}

func findMatchingTracker(observation trackerObservation) (TrackerRecord, bool) {
	var record TrackerRecord
	found := false
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		info := tracker.Info()
		if info == nil || info.Metadata == nil {
			return true
		}

		metadata := info.Metadata
		if !observation.matches(metadata.SourceAddress(), metadata.RemoteAddress(), metadata.Type.String()) {
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

func normalizeTrackerAddress(address string) (string, error) {
	if addrPort, err := netip.ParseAddrPort(address); err == nil {
		return addrPort.String(), nil
	}

	host, portText, err := splitTrackerAddress(address)
	if err != nil {
		return "", err
	}
	portValue, err := strconv.ParseUint(portText, 10, 16)
	if err != nil {
		return "", err
	}
	addr, err := netip.ParseAddr(strings.Trim(host, "[]"))
	if err != nil {
		return "", err
	}
	return netip.AddrPortFrom(addr, uint16(portValue)).String(), nil
}

func splitTrackerAddress(address string) (string, string, error) {
	host, port, err := net.SplitHostPort(address)
	if err == nil {
		return host, port, nil
	}
	return "", "", err
}
