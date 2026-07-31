import fs from 'node:fs/promises';
import path from 'node:path';

import { discoverToolchain, resolveRepoRootFromImportMetaUrl } from './lib/toolchain.mjs';

const repoRoot = resolveRepoRootFromImportMetaUrl(import.meta.url);
const outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'toolchain-preflight.json');

async function main() {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });

  const report = await discoverToolchain({
    cwd: path.join(repoRoot, 'harmony')
  });

  await fs.writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');

  process.exitCode = report.result === 'pass' ? 0 : 2;
}

main().catch(async (error) => {
  const fallback = {
    schemaVersion: '1.0.0',
    result: 'incomplete',
    target: {
      platform: 'HarmonyOS',
      apiVersion: 20,
      sdkVersion: null,
      ndkFound: false
    },
    tools: {
      node: { found: true, version: process.version },
      java: { found: false, version: null },
      hvigor: { found: false, version: null },
      ohpm: { found: false, version: null },
      hdc: { found: false, version: null },
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

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(fallback, null, 2)}\n`, 'utf8');
  process.exitCode = 2;
});
