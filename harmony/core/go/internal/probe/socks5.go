package probe

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
)

func establishSOCKS5Tunnel(ctx context.Context, conn net.Conn, targetAddress string) error {
	host, portText, err := net.SplitHostPort(targetAddress)
	if err != nil {
		return &Error{Code: "SOCKS5_TARGET_INVALID", Stage: "dial", Detail: sanitizeProbeDetail(err.Error())}
	}
	port, err := net.LookupPort("tcp", portText)
	if err != nil {
		return &Error{Code: "SOCKS5_TARGET_INVALID", Stage: "dial", Detail: sanitizeProbeDetail(err.Error())}
	}

	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return newOperationError(ctx, "dial", "SOCKS5_GREETING_WRITE_FAILED", err)
	}
	greetingReply := make([]byte, 2)
	if _, err := io.ReadFull(conn, greetingReply); err != nil {
		return newOperationError(ctx, "dial", "SOCKS5_GREETING_READ_FAILED", err)
	}
	if greetingReply[0] != 0x05 || greetingReply[1] != 0x00 {
		return &Error{Code: "SOCKS5_AUTH_UNSUPPORTED", Stage: "dial", Detail: fmt.Sprintf("unexpected SOCKS5 auth reply %v", greetingReply)}
	}

	request := []byte{0x05, 0x01, 0x00}
	if ip := net.ParseIP(host); ip != nil {
		if ipv4 := ip.To4(); ipv4 != nil {
			request = append(request, 0x01)
			request = append(request, ipv4...)
		} else {
			ipv6 := ip.To16()
			if ipv6 == nil {
				return &Error{Code: "SOCKS5_TARGET_INVALID", Stage: "dial", Detail: fmt.Sprintf("invalid target host %q", host)}
			}
			request = append(request, 0x04)
			request = append(request, ipv6...)
		}
	} else {
		if len(host) == 0 || len(host) > 255 {
			return &Error{Code: "SOCKS5_TARGET_INVALID", Stage: "dial", Detail: fmt.Sprintf("invalid target host %q", host)}
		}
		request = append(request, 0x03, byte(len(host)))
		request = append(request, host...)
	}
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, uint16(port))
	request = append(request, portBytes...)
	if _, err := conn.Write(request); err != nil {
		return newOperationError(ctx, "dial", "SOCKS5_CONNECT_WRITE_FAILED", err)
	}

	replyHeader := make([]byte, 4)
	if _, err := io.ReadFull(conn, replyHeader); err != nil {
		return newOperationError(ctx, "dial", "SOCKS5_CONNECT_READ_FAILED", err)
	}
	if replyHeader[0] != 0x05 {
		return &Error{Code: "SOCKS5_CONNECT_INVALID", Stage: "dial", Detail: fmt.Sprintf("unexpected SOCKS5 version %d", replyHeader[0])}
	}
	if replyHeader[1] != 0x00 {
		return &Error{Code: "SOCKS5_CONNECT_REJECTED", Stage: "dial", Detail: fmt.Sprintf("SOCKS5 connect reply %d", replyHeader[1])}
	}

	addressLength := 0
	switch replyHeader[3] {
	case 0x01:
		addressLength = net.IPv4len
	case 0x04:
		addressLength = net.IPv6len
	case 0x03:
		size := make([]byte, 1)
		if _, err := io.ReadFull(conn, size); err != nil {
			return newOperationError(ctx, "dial", "SOCKS5_CONNECT_READ_FAILED", err)
		}
		addressLength = int(size[0])
	default:
		return &Error{Code: "SOCKS5_CONNECT_INVALID", Stage: "dial", Detail: fmt.Sprintf("unexpected address type %d", replyHeader[3])}
	}

	discardLength := addressLength + 2
	if _, err := io.CopyN(io.Discard, conn, int64(discardLength)); err != nil {
		return newOperationError(ctx, "dial", "SOCKS5_CONNECT_READ_FAILED", err)
	}
	return nil
}
