# HarmonyOS QR Import, Export, and Backup Design

## Goal

Add system QR import, exact YAML export, and portable full backup/restore without copying unusable HUKS envelopes or leaking credentials through logs/state.

## QR import

Use `@kit.ScanKit.scanBarcode.startScanForResult` with QR-only, single-result, album-enabled options. The system owns camera UI, so the app does not add CAMERA permission or a custom camera surface.

Only `http://` and `https://` results enter the existing URL import parser. HTTPS continues directly; HTTP requires the existing per-operation consent. Raw scan content never enters public state, logs, errors, proof files, or semantic IDs. Cancellation is a normal no-op result.

## Exact YAML export

Export only the selected profile’s current validated revision through DocumentViewPicker. Before copying, verify sandbox ownership, size, and SHA-256 against revision metadata. Stream exact bytes with rollback on partial target failure.

The UI explicitly warns that a YAML file may contain node/provider credentials. The exporter never decrypts the subscription source URL and derives a safe `.yaml` filename from the profile name.

## Portable backup

Full backups use a versioned encrypted envelope rather than copying SQLite/HUKS files. The user supplies a passphrase at export and import.

- PBKDF2-HMAC-SHA256, random 16-byte salt, 210,000 iterations.
- AES-256-GCM, random 12-byte nonce, authenticated fixed header.
- Passphrase/key/plaintext are never stored or logged and are discarded after use.
- Envelope contains schema version, KDF parameters, nonce, ciphertext, and tag only.

The encrypted plaintext manifest contains allowlisted profile metadata, active-profile mapping, proxy selections, current/failed YAML bytes with size+SHA-256, and decrypted remote source URLs. It excludes HUKS aliases/envelopes, RDB/WAL files, logs, geodata, caches, VPN/RPC identities, and notification state.

On restore, decrypt in memory, validate exact keys/count/size/digests, stage every YAML, run core validation, and only then merge. IDs are regenerated on conflict; proxy selections and active mapping follow the new IDs. Remote URLs are immediately re-encrypted into fresh device-local HUKS envelopes. Restore is additive; replace-all is out of scope.

Limits: 128 profiles, 16 MiB per YAML entry, and 64 MiB aggregate decoded YAML+metadata. Export fails closed before creating a destination if the aggregate would exceed 64 MiB; it never emits a partial backup. The decrypted manifest has no unknown fields or filesystem paths.

Restore is a two-phase additive transaction. Phase 1 decrypts and validates the complete manifest, stages and validates every YAML, and creates provisional device-local HUKS secret refs while tracking every new file/ref in memory. Phase 2 performs one RDB transaction that inserts all regenerated profiles, proxy selections, and optional active mapping. On any failure before RDB commit, all staged/retained revisions and every provisional secret ref are deleted. After commit, startup reconciliation removes any unreferenced residue left by a crash. A transaction journal records the new profile IDs and provisional refs so interruption between file/HUKS work and RDB commit is recoverable. No restore result may report success with only a subset committed.

## Components and UI

- Shared transfer models/ports and backup use case.
- Platform ScanKit adapter, YAML exporter, CryptoFramework backup codec, and Document picker adapter.
- Import sheet adds Scan QR.
- Profile detail adds Export YAML.
- Profiles page adds Export backup and Restore backup, with passphrase dialogs and pending/result states.

## Testing and acceptance

- QR tests: QR-only options, album, cancellation, invalid scheme, HTTP consent, raw-value privacy, duplicate tap.
- YAML tests: exact bytes, missing revision, hash/size mismatch, short IO, picker cancellation, rollback, safe filename, zero secret-store reads.
- Backup codec known-answer and tamper tests: wrong passphrase, header/KDF bounds, GCM tag, oversize, no plaintext fragments in output.
- Restore tests: full round trip, HUKS rewrap, ID conflict, active/selections mapping, aggregate-limit rejection, validation failure with zero durable mutation, RDB commit failure cleanup, and startup reconciliation after each transaction-journal stage.
- Physical test: camera QR import, file export, backup, uninstall/reinstall test build, restore, and subscription refresh using rewrapped URLs.
