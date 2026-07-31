import fs from 'node:fs/promises';
import path from 'node:path';

import { discoverToolchain, normalizeNodeVersion, resolveRepoRootFromImportMetaUrl } from './lib/toolchain.mjs';

const repoRoot = resolveRepoRootFromImportMetaUrl(import.meta.url);
const outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'toolchain-preflight.json');

function createFallbackReport(error) {
  return {
    schemaVersion: '1.0.0',
    result: 'incomplete',
    target: {
      name: 'HarmonyOS 6/API 20/arm64',
      targetSdkVersion: '6.1.0(23)',
      targetApiVersion: 23,
      compatibleSdkVersion: '6.0.0(20)',
      compatibleApiVersion: 20,
      runtimeOS: 'HarmonyOS',
      architecture: 'arm64'
    },
    installed: {
      devecoVersion: null,
      sdkVersion: null,
      sdkApiVersion: null,
      ndkVersion: null,
      ndkApiVersion: null,
      hvigorVersion: null,
      ohpmVersion: null,
      hdcVersion: null
    },
    tools: {
      node: { found: true, version: normalizeNodeVersion(process.version) },
      java: { found: false, version: null },
      hvigor: { found: false, version: null },
      ohpm: { found: false, version: null },
      hdc: { found: false, version: null },
      arktsDeclarations: { found: false, count: 0, sample: null },
      ohosClang: { found: false, version: null },
      llvmReadelf: { found: false, version: null }
    },
    failures: [
      {
        code: 'TOOLCHAIN_PRECHECK_ERROR',
        detail: error?.code ?? error?.name ?? 'unknown'
      }
    ]
  };
}

async function writeReport(report) {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
}

async function main() {
  const report = await discoverToolchain({
    cwd: path.join(repoRoot, 'harmony')
  });

  await writeReport(report);
  process.exitCode = report.result === 'pass' ? 0 : 2;
}

main().catch(async (error) => {
  await writeReport(createFallbackReport(error));
  process.exitCode = 2;
});
