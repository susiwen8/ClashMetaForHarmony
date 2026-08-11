import { describe, expect, it } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { PlatformFactory, type PlatformGraph } from '@cmfa/platform';
import {
  createProfile,
  isSubscriptionSecretError,
  type Profile,
  type ProfileRevision
} from '@cmfa/shared';
import {
  appendEvidenceCheck,
  appendEvidenceFailure,
  appendEvidenceTrace,
  decodeUtf8,
  flushEvidence,
  getTestAbilityContext,
  readBytesFile,
  readUtf8File,
  removeIfPresent,
  sanitizeEvidenceText,
  setEvidenceStatus,
  stageRawfileToSandbox,
  writeUtf8File
} from '../testability/TestAbility';

const SUITE_NAME: string = 'Phase3PlatformAdapters';
const DATABASE_NAME: string = 'cmfa_profiles.db';
const REMOTE_URL: string = 'https://masked-user:masked-secret@example.com/subscription.yaml?token=super-secret-token';
const REMOTE_TOKEN_FRAGMENT: string = 'super-secret-token';
const EXTERNAL_PICKER_URI: string = ['file', '://', '/storage/', 'Us', 'ers', '/currentDevice/external/profile-phase3-valid.yaml'].join('');
const YAML_SENTINEL: string = 'MATCH,DIRECT';

export default function Phase3PlatformAdaptersTestsuite(): void {
  describe(SUITE_NAME, () => {
    it('persists profiles, reconciles revisions, and keeps sandbox artifacts redacted', 0, async () => {
      appendEvidenceTrace(`${SUITE_NAME}.start`);
      let graph: PlatformGraph | undefined = undefined;
      let reopenedGraph: PlatformGraph | undefined = undefined;
      let cleanupVerified: boolean = false;
      const profileIds: string[] = [];
      const secretIds: string[] = [];
      try {
        const context = getTestAbilityContext();
        graph = await new PlatformFactory(context).create();
        appendEvidenceTrace(`${SUITE_NAME}.graphCreated`);

        const localProfileId: string = graph.idGenerator.nextId();
        const remoteProfileId: string = graph.idGenerator.nextId();
        profileIds.push(localProfileId, remoteProfileId);

        const localCurrentStage = await stageRawfileToSandbox('phase3-valid.yaml');
        const localFailedStage = await stageRawfileToSandbox('phase3-valid.yaml');
        const orphanStage = await stageRawfileToSandbox('phase3-valid.yaml');
        const remoteStage = await stageRawfileToSandbox('phase3-valid.yaml');

        const localCurrentRevision: ProfileRevision = await graph.contentStore.retain(localProfileId, localCurrentStage, 'CURRENT');
        const localFailedRevision: ProfileRevision = await graph.contentStore.retain(localProfileId, localFailedStage, 'FAILED_CANDIDATE');
        const orphanRevision: ProfileRevision = await graph.contentStore.retain(graph.idGenerator.nextId(), orphanStage, 'FAILED_CANDIDATE');
        const remoteCurrentRevision: ProfileRevision = await graph.contentStore.retain(remoteProfileId, remoteStage, 'CURRENT');

        const remoteSecretId: string = await graph.secretStore.encrypt(REMOTE_URL);
        secretIds.push(remoteSecretId);

        const timestamp: string = new Date().toISOString();
        const localProfile: Profile = createProfile({
          id: localProfileId,
          name: 'Task 14 Local',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: EXTERNAL_PICKER_URI,
          currentRevision: localCurrentRevision,
          failedCandidate: localFailedRevision,
          availability: 'VALID',
          lastError: null,
          createdAt: timestamp,
          updatedAt: timestamp,
          lastSuccessfulUpdateAt: timestamp
        });
        const remoteProfile: Profile = createProfile({
          id: remoteProfileId,
          name: 'Task 14 Remote',
          sourceKind: 'REMOTE_URL',
          sourceDisplay: REMOTE_URL,
          sourceSecretRef: remoteSecretId,
          currentRevision: remoteCurrentRevision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: timestamp,
          updatedAt: timestamp,
          lastSuccessfulUpdateAt: timestamp
        });

        await graph.repository.save(localProfile);
        await graph.repository.save(remoteProfile);
        await graph.repository.setActiveId(remoteProfileId);
        await graph.contentStore.reconcile([localCurrentRevision, localFailedRevision, remoteCurrentRevision]);
        ensure(await pathExists(graph.contentStore.resolveCorePath(localFailedRevision)), 'Referenced failed candidate must survive reconciliation.');
        ensure(!(await pathExists(graph.contentStore.resolveCorePath(orphanRevision))), 'Synthetic orphan revision must be removed by reconciliation.');

        await graph.close();
        await graph.close();
        appendEvidenceTrace(`${SUITE_NAME}.graphReopen`);

        reopenedGraph = await new PlatformFactory(context).create();
        const reopenedProfiles: Profile[] = await reopenedGraph.repository.list();
        expect(reopenedProfiles.length).assertEqual(2);
        expect(await reopenedGraph.repository.getActiveId()).assertEqual(remoteProfileId);

        const reopenedLocalProfile: Profile | undefined = await reopenedGraph.repository.get(localProfileId);
        const reopenedRemoteProfile: Profile | undefined = await reopenedGraph.repository.get(remoteProfileId);
        ensure(reopenedLocalProfile !== undefined, 'Reopened local profile must exist.');
        ensure(reopenedRemoteProfile !== undefined, 'Reopened remote profile must exist.');
        ensure(reopenedLocalProfile!.failedCandidate !== null, 'Reopened local profile must keep the failed candidate while referenced.');

        const updatedLocalProfile: Profile = createProfile({
          id: reopenedLocalProfile!.id,
          name: reopenedLocalProfile!.name,
          sourceKind: reopenedLocalProfile!.sourceKind,
          sourceDisplay: reopenedLocalProfile!.sourceDisplay,
          currentRevision: reopenedLocalProfile!.currentRevision,
          failedCandidate: null,
          availability: reopenedLocalProfile!.availability,
          lastError: reopenedLocalProfile!.lastError,
          createdAt: reopenedLocalProfile!.createdAt,
          updatedAt: new Date().toISOString(),
          lastSuccessfulUpdateAt: reopenedLocalProfile!.lastSuccessfulUpdateAt
        });
        await reopenedGraph.repository.save(updatedLocalProfile);
        await reopenedGraph.contentStore.reconcile([
          updatedLocalProfile.currentRevision as ProfileRevision,
          reopenedRemoteProfile!.currentRevision as ProfileRevision
        ]);
        ensure(!(await pathExists(graphOr(reopenedGraph).contentStore.resolveCorePath(localFailedRevision))), 'Failed candidate must be removed once it is no longer referenced.');

        const decryptedRemoteUrl: string = await reopenedGraph.secretStore.decrypt(remoteSecretId);
        expect(decryptedRemoteUrl).assertEqual(REMOTE_URL);

        const databasePath: string = await findSandboxFileByName(context.databaseDir, DATABASE_NAME);
        const databaseText: string = sanitizeEvidenceText(decodeUtf8(await readBytesFile(databasePath)));
        ensure(!databaseText.includes(REMOTE_URL), 'RDB bytes must not contain the remote URL plaintext.');
        ensure(!databaseText.includes(REMOTE_TOKEN_FRAGMENT), 'RDB bytes must not contain the remote token plaintext.');
        ensure(!databaseText.includes(EXTERNAL_PICKER_URI), 'RDB bytes must not contain the external picker URI.');
        ensure(!databaseText.includes(YAML_SENTINEL), 'RDB bytes must not contain the YAML body.');

        const secretEnvelopePath: string = `${context.filesDir}/profile-secrets/${remoteSecretId}.json`;
        const envelopeText: string = sanitizeEvidenceText(await readUtf8File(secretEnvelopePath));
        ensure(!envelopeText.includes(REMOTE_URL), 'Secret envelope bytes must not contain the remote URL plaintext.');
        ensure(!envelopeText.includes(REMOTE_TOKEN_FRAGMENT), 'Secret envelope bytes must not contain the remote token plaintext.');
        ensure(!envelopeText.includes(EXTERNAL_PICKER_URI), 'Secret envelope bytes must not contain the external picker URI.');
        ensure(!envelopeText.includes(YAML_SENTINEL), 'Secret envelope bytes must not contain the YAML body.');

        const unsupportedSecretId: string = await reopenedGraph.secretStore.encrypt(REMOTE_URL);
        const corruptSecretId: string = await reopenedGraph.secretStore.encrypt(REMOTE_URL);
        const missingSecretId: string = await reopenedGraph.secretStore.encrypt(REMOTE_URL);
        secretIds.push(unsupportedSecretId, corruptSecretId, missingSecretId);

        const unsupportedPath: string = `${context.filesDir}/profile-secrets/${unsupportedSecretId}.json`;
        const unsupportedEnvelope: Record<string, Object> = JSON.parse(await readUtf8File(unsupportedPath)) as Record<string, Object>;
        unsupportedEnvelope.version = 2;
        await writeUtf8File(unsupportedPath, JSON.stringify(unsupportedEnvelope));
        await expectSecretFailure(
          async () => {
            await reopenedGraph!.secretStore.decrypt(unsupportedSecretId);
          },
          'SOURCE_SECRET_VERSION_UNSUPPORTED'
        );

        const corruptPath: string = `${context.filesDir}/profile-secrets/${corruptSecretId}.json`;
        const corruptEnvelope: Record<string, Object> = JSON.parse(await readUtf8File(corruptPath)) as Record<string, Object>;
        corruptEnvelope.ciphertext = '###';
        await writeUtf8File(corruptPath, JSON.stringify(corruptEnvelope));
        await expectSecretFailure(
          async () => {
            await reopenedGraph!.secretStore.decrypt(corruptSecretId);
          },
          'SOURCE_DECRYPT_FAILED'
        );

        const missingPath: string = `${context.filesDir}/profile-secrets/${missingSecretId}.json`;
        await removeIfPresent(missingPath);
        await expectSecretFailure(
          async () => {
            await reopenedGraph!.secretStore.decrypt(missingSecretId);
          },
          'SOURCE_SECRET_MISSING'
        );

        await reopenedGraph.secretStore.remove(remoteSecretId);
        await reopenedGraph.secretStore.remove(remoteSecretId);
        await expectSecretFailure(
          async () => {
            await reopenedGraph!.secretStore.decrypt(remoteSecretId);
          },
          'SOURCE_SECRET_MISSING'
        );

        appendEvidenceCheck(`${SUITE_NAME}: persistence/reconcile/redaction pass`);
      } catch (error) {
        setEvidenceStatus('FAIL');
        appendEvidenceFailure(SUITE_NAME, `${error}`);
        throw toError(error);
      } finally {
        const finalGraph: PlatformGraph | undefined = reopenedGraph ?? graph;
        try {
          if (finalGraph !== undefined) {
            for (let index: number = 0; index < profileIds.length; index += 1) {
              const profileId: string = profileIds[index];
              await finalGraph.repository.deleteAndClearActive(profileId).catch(() => {
              });
              await finalGraph.contentStore.removeProfile(profileId).catch(() => {
              });
            }
            for (let index: number = 0; index < secretIds.length; index += 1) {
              await finalGraph.secretStore.remove(secretIds[index]).catch(() => {
              });
            }
            await finalGraph.close();
            await finalGraph.close();
          }

          const cleanupGraph: PlatformGraph = await new PlatformFactory(getTestAbilityContext()).create();
          const remainingProfiles: Profile[] = await cleanupGraph.repository.list();
          expect(remainingProfiles.length).assertEqual(0);
          expect(await cleanupGraph.repository.getActiveId()).assertEqual(undefined);
          await cleanupGraph.close();
          cleanupVerified = true;
        } catch (cleanupError) {
          setEvidenceStatus('FAIL');
          appendEvidenceFailure(SUITE_NAME, `cleanup: ${cleanupError}`);
          throw toError(cleanupError);
        } finally {
          if (cleanupVerified) {
            appendEvidenceTrace(`${SUITE_NAME}.cleanupVerified`);
          }
          await flushEvidence();
        }
      }
    });
  });
}

function graphOr(graph: PlatformGraph): PlatformGraph {
  return graph;
}

async function expectSecretFailure(operation: () => Promise<void>, expectedCode: string): Promise<void> {
  try {
    await operation();
    throw new Error(`Expected ${expectedCode} but the secret operation succeeded.`);
  } catch (error) {
    ensure(isSubscriptionSecretError(error as Object), 'Secret failures must stay typed.');
    const record = error as Record<string, string>;
    expect(record.code).assertEqual(expectedCode);
    const detail: string = sanitizeEvidenceText(record.detail ?? record.message ?? `${error}`);
    ensure(!detail.includes(REMOTE_URL), 'Secret failure detail must redact the remote URL.');
    ensure(!detail.includes(REMOTE_TOKEN_FRAGMENT), 'Secret failure detail must redact the remote token.');
  }
}

async function findSandboxFileByName(rootPath: string, fileName: string): Promise<string> {
  const entries: string[] = await fileIo.listFile(rootPath);
  for (let index: number = 0; index < entries.length; index += 1) {
    const entryPath: string = `${rootPath}/${entries[index]}`;
    if (entries[index] === fileName) {
      return entryPath;
    }
    const stat = await fileIo.stat(entryPath);
    if (stat.isDirectory()) {
      const nested: string | undefined = await findSandboxFileByNameOrUndefined(entryPath, fileName);
      if (nested !== undefined) {
        return nested;
      }
    }
  }
  throw new Error(`Sandbox file ${fileName} was not found.`);
}

async function findSandboxFileByNameOrUndefined(rootPath: string, fileName: string): Promise<string | undefined> {
  const entries: string[] = await fileIo.listFile(rootPath);
  for (let index: number = 0; index < entries.length; index += 1) {
    const entryPath: string = `${rootPath}/${entries[index]}`;
    if (entries[index] === fileName) {
      return entryPath;
    }
    const stat = await fileIo.stat(entryPath);
    if (stat.isDirectory()) {
      const nested: string | undefined = await findSandboxFileByNameOrUndefined(entryPath, fileName);
      if (nested !== undefined) {
        return nested;
      }
    }
  }
  return undefined;
}

async function pathExists(filePath: string): Promise<boolean> {
  try {
    return await fileIo.access(filePath);
  } catch (_) {
    return false;
  }
}

function ensure(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

function toError(error: Object | undefined): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(`${error}`);
}
