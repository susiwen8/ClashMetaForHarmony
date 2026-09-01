import { createProxySelectionRecord, type ProxySelectionRecord } from '@cmfa/shared';
import type { DurableProxySelectionRow } from './RdbDriver';

export type { DurableProxySelectionRow } from './RdbDriver';

const EXPECTED_KEYS: string[] = [
  'groupName',
  'profileId',
  'revisionId',
  'selectedNodeName',
  'updatedAt'
];

function requireString(value: Object | null | undefined, label: string): string {
  if (typeof value !== 'string') {
    throw new Error(`${label} must be a string.`);
  }
  return value;
}

function requireExactKeys(row: DurableProxySelectionRow): void {
  const keys: string[] = Object.keys(row as Object).sort();
  if (keys.length !== EXPECTED_KEYS.length) {
    throw new Error('Proxy selection row shape is invalid.');
  }
  for (let index = 0; index < EXPECTED_KEYS.length; index += 1) {
    if (keys[index] !== EXPECTED_KEYS[index]) {
      throw new Error('Proxy selection row shape is invalid.');
    }
  }
}

export function encodeProxySelectionRow(record: ProxySelectionRecord): DurableProxySelectionRow {
  const normalized: ProxySelectionRecord = createProxySelectionRecord(
    record.profileId,
    record.groupName,
    record.selectedNodeName,
    record.revisionId,
    record.updatedAt
  );
  return {
    profileId: normalized.profileId,
    groupName: normalized.groupName,
    selectedNodeName: normalized.selectedNodeName,
    revisionId: normalized.revisionId,
    updatedAt: normalized.updatedAt
  };
}

export function decodeProxySelectionRow(row: DurableProxySelectionRow): ProxySelectionRecord {
  requireExactKeys(row);
  return createProxySelectionRecord(
    requireString(row.profileId, 'Proxy selection row profileId'),
    requireString(row.groupName, 'Proxy selection row groupName'),
    requireString(row.selectedNodeName, 'Proxy selection row selectedNodeName'),
    requireString(row.revisionId, 'Proxy selection row revisionId'),
    requireString(row.updatedAt, 'Proxy selection row updatedAt')
  );
}
