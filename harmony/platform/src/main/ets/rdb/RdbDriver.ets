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

export interface RdbTransaction {
  getProfileRow(id: string): Promise<DurableProfileRow | undefined>;
  setActiveId(activeId: string | undefined): Promise<void>;
  clearActiveIfMatching(id: string): Promise<void>;
  deleteProfile(id: string): Promise<void>;
}

export interface RdbDriver {
  initialize(version: number): Promise<void>;
  listProfileRows(): Promise<DurableProfileRow[]>;
  getProfileRow(id: string): Promise<DurableProfileRow | undefined>;
  upsertProfileRow(row: DurableProfileRow): Promise<void>;
  readActiveId(): Promise<string | undefined>;
  transaction<T>(block: (transaction: RdbTransaction) => Promise<T>): Promise<T>;
}
