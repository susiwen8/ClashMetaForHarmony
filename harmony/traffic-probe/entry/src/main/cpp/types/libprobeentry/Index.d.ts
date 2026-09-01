export type ProbeSocketKind = 'tcpEcho' | 'tcpHttp' | 'tcpSend' | 'tcpExchange' | 'udpEcho' | 'dnsUdpEcho';

export interface ProbeSocketRequest {
  kind: ProbeSocketKind;
  hostIpv4: string;
  port: number;
  payload: ArrayBuffer;
  timeoutMs: number;
}

export interface ProbeSocketResult {
  outcome: 'pass' | 'fail' | 'timeout';
  bytesSent: number;
  bytesReceived: number;
  durationMs: number;
  failureCode?: 'INVALID_ARGUMENT' | 'CONNECT_FAILED' | 'SEND_FAILED' | 'RECV_FAILED' | 'TIMEOUT' | 'PAYLOAD_MISMATCH';
}

export declare function probeSocket(request: ProbeSocketRequest): Promise<ProbeSocketResult>;
