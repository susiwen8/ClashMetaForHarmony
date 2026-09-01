import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main');

async function readUtf8(filePath) { return await fs.readFile(filePath, 'utf8'); }

test('profile transfer QR import uses the system scanner without camera permission or raw public state', async () => {
  const [manifest, core, appComposition, index, viewModel, sheet] = await Promise.all([
    readUtf8(path.join(ENTRY_ROOT, 'module.json5')),
    readUtf8(path.join(ENTRY_ROOT, 'ets', 'bootstrap', 'CoreComposition.ets')),
    readUtf8(path.join(ENTRY_ROOT, 'ets', 'bootstrap', 'ApplicationComposition.ets')),
    readUtf8(path.join(ENTRY_ROOT, 'ets', 'pages', 'Index.ets')),
    readUtf8(path.join(ENTRY_ROOT, 'ets', 'presentation', 'ImportProfileViewModel.ets')),
    readUtf8(path.join(ENTRY_ROOT, 'ets', 'pages', 'ImportProfileSheet.ets'))
  ]);

  assert.doesNotMatch(manifest, /ohos\.permission\.CAMERA/u);
  assert.match(core, /createHarmonyQrScanner\(this\.context\)/u);
  assert.match(appComposition, /qrScanner\?: QrScannerPort/u);
  assert.match(index, /new ImportProfileViewModel\(application, qrScanner\)/u);
  assert.match(viewModel, /status === 'SCANNING'/u);
  assert.match(viewModel, /sanitizeProfileTransferQrUrl\(scanResult\.value\)/u);
  assert.doesNotMatch(viewModel, /urlDraft\s*=\s*scanResult\.value/u);
  assert.match(sheet, /\.id\('import\.qr'\)/u);
  assert.match(sheet, /requestScanQr\(\)/u);
});
