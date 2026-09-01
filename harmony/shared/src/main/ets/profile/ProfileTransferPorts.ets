import type {
  PortableBackupEnvelope,
  ProfileTransferQrScanResult,
  ProfileTransferYamlExportResult
} from './ProfileTransferModels';

export interface QrScannerPort {
  scan(): Promise<ProfileTransferQrScanResult>;
}

export interface ProfileYamlExporterPort {
  exportProfile(profileId: string): Promise<ProfileTransferYamlExportResult>;
}

export interface PortableBackupCodecPort {
  encrypt(plaintext: Uint8Array, passphrase: string): Promise<PortableBackupEnvelope>;
  decrypt(envelope: PortableBackupEnvelope, passphrase: string): Promise<Uint8Array>;
}

export interface ProfileBackupDocumentDescriptor {
  uri: string;
  displayName: string;
}

export interface ProfileBackupDocumentPort {
  pickExport(suggestedFileName: string): Promise<ProfileBackupDocumentDescriptor | null>;
  pickImport(): Promise<ProfileBackupDocumentDescriptor | null>;
  write(document: ProfileBackupDocumentDescriptor, bytes: Uint8Array): Promise<void>;
  read(document: ProfileBackupDocumentDescriptor): Promise<Uint8Array>;
}
