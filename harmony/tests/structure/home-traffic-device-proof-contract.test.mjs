import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const RUNNER_MODULE_PATH = new URL('../bin/run-home-traffic-device-proof.mjs', import.meta.url);
const RUNNER_SOURCE_PATH = fileURLToPath(RUNNER_MODULE_PATH);
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'home-traffic-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'home-traffic-device-proof.example.json');
const HOME_TRAFFIC_CARD_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'components', 'HomeTrafficCard.ets');
const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'home-traffic-device-proof.json');
const DEFAULT_PRODUCTION_HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const DEFAULT_PROBE_HAP_PATH = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const FIXTURE_SHA256 = crypto.createHash('sha256').update('home-traffic-signed-hap').digest('hex');
const ZERO_SHA256 = '0'.repeat(64);
const REQUIRED_TRAFFIC_KEYS = Object.freeze([
  'downloadRateObserved',
  'downloadTotalMonotonic',
  'homeDownloadSpeedSelectorCount',
  'homeDownloadTotalSelectorCount',
  'homeNotificationAgreement',
  'homeTrafficCardCount',
  'homeUploadSpeedSelectorCount',
  'homeUploadTotalSelectorCount',
  'notificationTrafficUpdateCount',
  'uploadRateObserved',
  'uploadTotalMonotonic'
]);

function createNode(id, text = '', children = []) {
  const attributes = { id };
  if (text.length > 0) {
    attributes.text = text;
  }
  return {
    attributes,
    bounds: { left: 0, top: 0, right: 320, bottom: 60 },
    children
  };
}

function createHomeTrafficLayout({
  uploadSpeed,
  uploadTotal,
  downloadSpeed,
  downloadTotal,
  status = 'available',
  duplicateUploadSpeed = false,
  includeCard = true
} = {}) {
  const trafficCardChildren = [
    createNode('home.traffic.status', status),
    createNode('home.traffic.upload.speed', uploadSpeed),
    createNode('home.traffic.upload.total', uploadTotal),
    createNode('home.traffic.download.speed', downloadSpeed),
    createNode('home.traffic.download.total', downloadTotal)
  ];
  if (duplicateUploadSpeed) {
    trafficCardChildren.push(createNode('home.traffic.upload.speed', uploadSpeed));
  }
  return {
    root: createNode('root', '', includeCard
      ? [createNode('home.traffic.card', '', trafficCardChildren)]
      : trafficCardChildren)
  };
}

function createPassProof(overrides = {}) {
  return {
    schemaVersion: '1.0.0',
    result: 'pass',
    packageSha256: FIXTURE_SHA256,
    traffic: {
      uploadRateObserved: true,
      downloadRateObserved: true,
      uploadTotalMonotonic: true,
      downloadTotalMonotonic: true,
      homeTrafficCardCount: 1,
      homeUploadSpeedSelectorCount: 1,
      homeUploadTotalSelectorCount: 1,
      homeDownloadSpeedSelectorCount: 1,
      homeDownloadTotalSelectorCount: 1,
      notificationTrafficUpdateCount: 2,
      homeNotificationAgreement: true
    },
    ...overrides
  };
}

function createIncompleteProof() {
  return {
    schemaVersion: '1.0.0',
    result: 'incomplete',
    packageSha256: ZERO_SHA256,
    traffic: {
      uploadRateObserved: false,
      downloadRateObserved: false,
      uploadTotalMonotonic: false,
      downloadTotalMonotonic: false,
      homeTrafficCardCount: 0,
      homeUploadSpeedSelectorCount: 0,
      homeUploadTotalSelectorCount: 0,
      homeDownloadSpeedSelectorCount: 0,
      homeDownloadTotalSelectorCount: 0,
      notificationTrafficUpdateCount: 0,
      homeNotificationAgreement: false
    }
  };
}

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

test('home traffic device proof schema/example and validator accept only the privacy-safe pass or canonical incomplete shapes', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const [schema, example] = await Promise.all([
    readUtf8(SCHEMA_PATH).then(JSON.parse),
    readUtf8(EXAMPLE_PATH).then(JSON.parse)
  ]);

  assert.equal(typeof runner.validateHomeTrafficProofDocument, 'function');
  assert.equal(typeof runner.writeValidatedHomeTrafficProof, 'function');

  const passValidation = await runner.validateHomeTrafficProofDocument(createPassProof(), schema);
  assert.equal(passValidation.valid, true);

  const incompleteValidation = await runner.validateHomeTrafficProofDocument(createIncompleteProof(), schema);
  assert.equal(incompleteValidation.valid, true);

  const exampleValidation = await runner.validateHomeTrafficProofDocument(example, schema);
  assert.equal(exampleValidation.valid, true);
  assert.equal(example.result, 'incomplete');
  assert.equal(example.packageSha256, ZERO_SHA256);

  const extraRootValidation = await runner.validateHomeTrafficProofDocument({
    ...createPassProof(),
    sessionId: 'secret-session'
  }, schema);
  assert.equal(extraRootValidation.valid, false);

  const extraTrafficValidation = await runner.validateHomeTrafficProofDocument({
    ...createPassProof(),
    traffic: {
      ...createPassProof().traffic,
      uploadRateText: '12 KB/s'
    }
  }, schema);
  assert.equal(extraTrafficValidation.valid, false);

  const relaxedPassValidation = await runner.validateHomeTrafficProofDocument(createPassProof({
    packageSha256: ZERO_SHA256,
    traffic: {
      ...createPassProof().traffic,
      notificationTrafficUpdateCount: 0,
      homeNotificationAgreement: false
    }
  }), schema);
  assert.equal(relaxedPassValidation.valid, false);
});

test('home traffic device proof analyzer reduces synthetic upload/download layouts to counts and booleans only', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const beforeLayout = createHomeTrafficLayout({
    uploadSpeed: '0 B/s',
    uploadTotal: '1 KB',
    downloadSpeed: '0 B/s',
    downloadTotal: '2 KB'
  });
  const uploadLayout = createHomeTrafficLayout({
    uploadSpeed: '8 KB/s',
    uploadTotal: '3 KB',
    downloadSpeed: '0 B/s',
    downloadTotal: '2 KB'
  });
  const downloadLayout = createHomeTrafficLayout({
    uploadSpeed: '0 B/s',
    uploadTotal: '3 KB',
    downloadSpeed: '14 KB/s',
    downloadTotal: '9 KB'
  });

  const analysis = runner.analyzeHomeTrafficLayouts(beforeLayout, uploadLayout, downloadLayout);

  assert.deepEqual(Object.keys(analysis).sort(), [...REQUIRED_TRAFFIC_KEYS].sort());
  assert.deepEqual(analysis, {
    uploadRateObserved: true,
    downloadRateObserved: true,
    uploadTotalMonotonic: true,
    downloadTotalMonotonic: true,
    homeTrafficCardCount: 1,
    homeUploadSpeedSelectorCount: 1,
    homeUploadTotalSelectorCount: 1,
    homeDownloadSpeedSelectorCount: 1,
    homeDownloadTotalSelectorCount: 1,
    notificationTrafficUpdateCount: 0,
    homeNotificationAgreement: false
  });
  assert.equal(JSON.stringify(analysis).includes('KB'), false);
  assert.equal(JSON.stringify(analysis).includes('/s'), false);
});

test('home traffic device proof analyzer rejects duplicate selectors, missing semantic ids, and malformed metric text', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const beforeLayout = createHomeTrafficLayout({
    uploadSpeed: '0 B/s',
    uploadTotal: '1 KB',
    downloadSpeed: '0 B/s',
    downloadTotal: '2 KB'
  });
  const uploadLayout = createHomeTrafficLayout({
    uploadSpeed: '8 KB/s',
    uploadTotal: '3 KB',
    downloadSpeed: '0 B/s',
    downloadTotal: '2 KB'
  });
  const malformedDownloadLayout = createHomeTrafficLayout({
    uploadSpeed: '0 B/s',
    uploadTotal: '3 KB',
    downloadSpeed: 'ready',
    downloadTotal: '9 KB'
  });

  assert.throws(
    () => runner.analyzeHomeTrafficLayouts(
      beforeLayout,
      createHomeTrafficLayout({
        uploadSpeed: '8 KB/s',
        uploadTotal: '3 KB',
        downloadSpeed: '0 B/s',
        downloadTotal: '2 KB',
        duplicateUploadSpeed: true
      }),
      createHomeTrafficLayout({
        uploadSpeed: '0 B/s',
        uploadTotal: '3 KB',
        downloadSpeed: '14 KB/s',
        downloadTotal: '9 KB'
      })
    ),
    /HOME_TRAFFIC_(?:SELECTOR_AMBIGUOUS|LAYOUT_INVALID)/u
  );

  assert.throws(
    () => runner.analyzeHomeTrafficLayouts(
      beforeLayout,
      uploadLayout,
      createHomeTrafficLayout({
        uploadSpeed: '0 B/s',
        uploadTotal: '3 KB',
        downloadSpeed: '14 KB/s',
        downloadTotal: '9 KB',
        includeCard: false
      })
    ),
    /HOME_TRAFFIC_(?:SELECTOR_MISSING|LAYOUT_INVALID)/u
  );

  assert.throws(
    () => runner.analyzeHomeTrafficLayouts(beforeLayout, uploadLayout, malformedDownloadLayout),
    /HOME_TRAFFIC_(?:METRIC_TEXT_INVALID|LAYOUT_INVALID)/u
  );
});

test('home traffic device proof writer enforces strict pass predicates and repo-safe output paths while falling back to canonical incomplete', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const schema = JSON.parse(await readUtf8(SCHEMA_PATH));
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'home-traffic-proof-'));
  const outputPath = path.join(tempRoot, 'home-traffic-device-proof.json');
  const outsideRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'home-traffic-proof-outside-'));
  const outsideOutputPath = path.join(outsideRoot, 'outside.json');

  await fs.writeFile(outsideOutputPath, 'outside-sentinel\n', 'utf8');

  const persisted = await runner.writeValidatedHomeTrafficProof(createPassProof({
    packageSha256: ZERO_SHA256,
    traffic: {
      ...createPassProof().traffic,
      notificationTrafficUpdateCount: 0,
      homeNotificationAgreement: false
    }
  }), {
    schema,
    outputPath,
    repoRoot: REPO_ROOT
  });

  assert.deepEqual(persisted, createIncompleteProof());
  assert.deepEqual(JSON.parse(await fs.readFile(outputPath, 'utf8')), createIncompleteProof());
  assert.equal((await runner.validateHomeTrafficProofDocument(persisted, schema)).valid, true);

  await assert.rejects(
    async () => await runner.writeValidatedHomeTrafficProof(createIncompleteProof(), {
      schema,
      outputPath: outsideOutputPath,
      repoRoot: REPO_ROOT
    }),
    (error) => error?.code === 'PATH_OUTSIDE_REPO'
  );
  assert.equal(await fs.readFile(outsideOutputPath, 'utf8'), 'outside-sentinel\n');
});

test('home traffic device proof runner source keeps repo-safe probe semantics, required selectors, and avoids raw sensitive persistence fields', async () => {
  const [runnerSource, homeTrafficCardSource] = await Promise.all([
    readUtf8(RUNNER_SOURCE_PATH),
    readUtf8(HOME_TRAFFIC_CARD_PATH)
  ]);

  assert.match(runnerSource, /com\.cmfa\.phase4\.trafficprobe/u);
  assert.match(runnerSource, /com\.github\.kr328\.clash\.harmony/u);
  assert.match(runnerSource, /--out/u);
  assert.match(runnerSource, /--serial/u);
  assert.match(runnerSource, /--production-hap/u);
  assert.match(runnerSource, /--probe-hap/u);
  assert.match(runnerSource, /ensureRepoScopedOutputFile/u);
  assert.match(runnerSource, /force-stop/u);
  assert.match(runnerSource, /notificationTrafficUpdateCount/u);
  assert.match(runnerSource, /homeNotificationAgreement/u);

  for (const semanticId of [
    'home.traffic.card',
    'home.traffic.upload.speed',
    'home.traffic.upload.total',
    'home.traffic.download.speed',
    'home.traffic.download.total',
    'home.traffic.status'
  ]) {
    assert.match(homeTrafficCardSource, new RegExp(`\\.id\\('${semanticId.replaceAll('.', '\\.')}'\\)`, 'u'));
    assert.match(runnerSource, new RegExp(semanticId.replaceAll('.', '\\.'), 'u'));
  }

  assert.doesNotMatch(runnerSource, /https?:\/\//u);
  assert.doesNotMatch(runnerSource, /(?:sessionId|profileId|nodeId|subscriptionSecret|deviceSerial|payload|filesystemPath)/u);
});

test('home traffic device proof CLI parsing keeps repository-local defaults for production/probe haps and output artifacts', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  assert.equal(typeof runner.parseCliArguments, 'function');

  const defaults = runner.parseCliArguments([]);
  assert.equal(defaults.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(defaults.productionHapPath, DEFAULT_PRODUCTION_HAP_PATH);
  assert.equal(defaults.probeHapPath, DEFAULT_PROBE_HAP_PATH);
  assert.equal(defaults.serial, null);

  const parsed = runner.parseCliArguments([
    '--serial', 'SERIAL123',
    '--production-hap', DEFAULT_PRODUCTION_HAP_PATH,
    '--probe-hap', DEFAULT_PROBE_HAP_PATH,
    '--out', DEFAULT_OUTPUT_PATH
  ]);
  assert.equal(parsed.serial, 'SERIAL123');
  assert.equal(parsed.productionHapPath, DEFAULT_PRODUCTION_HAP_PATH);
  assert.equal(parsed.probeHapPath, DEFAULT_PROBE_HAP_PATH);
  assert.equal(parsed.outputPath, DEFAULT_OUTPUT_PATH);
});
