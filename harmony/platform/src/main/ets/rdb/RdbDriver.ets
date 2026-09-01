export interface DurableProfileRow {
  schemaVersion: number;
  id: string;
  name: string;
  sourceKind: string;
  sourceDisplay: string;
  sourceSecretRef?: string;
  currentRevisionJson: string | null;
  failedCandidateJson: string | null;
  availability: string;
  lastErrorJson: string | null;
  createdAt: string;
  updatedAt: string;
  lastSuccessfulUpdateAt: string | null;
}

export interface DurableProxySelectionRow {
  profileId: string;
  groupName: string;
  selectedNodeName: string;
  revisionId: string;
  updatedAt: string;
}

export interface RdbTransaction {
  getProfileRow(id: string): Promise<DurableProfileRow | undefined>;
  listProxySelectionRows(profileId: string): Promise<DurableProxySelectionRow[]>;
  getProxySelectionRow(profileId: string, groupName: string): Promise<DurableProxySelectionRow | undefined>;
  upsertProxySelectionRow(row: DurableProxySelectionRow): Promise<void>;
  deleteProxySelection(profileId: string, groupName: string): Promise<void>;
  deleteProfileSelections(profileId: string): Promise<void>;
  setActiveId(activeId: string | undefined): Promise<void>;
  clearActiveIfMatching(id: string): Promise<void>;
  deleteProfile(id: string): Promise<void>;
}

export interface RdbDriver {
  initialize(version: number): Promise<void>;
  listProfileRows(): Promise<DurableProfileRow[]>;
  getProfileRow(id: string): Promise<DurableProfileRow | undefined>;
  upsertProfileRow(row: DurableProfileRow): Promise<void>;
  listProxySelectionRows(profileId: string): Promise<DurableProxySelectionRow[]>;
  getProxySelectionRow(profileId: string, groupName: string): Promise<DurableProxySelectionRow | undefined>;
  readActiveId(): Promise<string | undefined>;
  transaction<T>(block: (transaction: RdbTransaction) => Promise<T>): Promise<T>;
}
