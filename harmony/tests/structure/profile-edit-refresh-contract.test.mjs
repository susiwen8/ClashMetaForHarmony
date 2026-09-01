import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const INDEX_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'pages', 'Index.ets');

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

test('detail proxy manager reloads only after a submitting-to-completed refresh for the same active profile', async () => {
  const indexSource = await readUtf8(INDEX_PATH);

  assert.match(indexSource, /const\s+previousDetailState:\s*ProfileDetailViewState\s*=\s*this\.detailState;/u,
    'Index must snapshot the previous detail state before projecting a new one'
  );
  assert.match(indexSource, /const\s+shouldReloadProxyState:\s*boolean\s*=\s*this\.shouldReloadDetailProxyAfterCommand\(previousDetailState,\s*state\);/u,
    'Index must decide proxy reloads from the old and new detail states'
  );
  assert.match(indexSource, /this\.detailState\s*=\s*state[\s\S]*this\.detailCommandPending\s*=\s*state\.status\s*===\s*'SUBMITTING'[\s\S]*this\.detailCommandCompleted\s*=\s*state\.status\s*===\s*'COMPLETED'/u,
    'Index must project the latest detail state before evaluating reload side effects'
  );
  assert.match(indexSource, /if\s*\(\s*shouldReloadProxyState\s*\)\s*\{[\s\S]*this\.proxyViewModel\?\.load\(this\.detailProfileId\);[\s\S]*\}/u,
    'Index must reload proxy state when a qualifying detail command completes'
  );
  assert.match(indexSource, /private\s+shouldReloadDetailProxyAfterCommand\(\s*previousState:\s*ProfileDetailViewState,\s*nextState:\s*ProfileDetailViewState\s*\):\s*boolean/u,
    'Index must centralize the proxy reload gate in a dedicated helper'
  );
  assert.match(indexSource, /previousState\.status\s*===\s*'SUBMITTING'/u,
    'Index must only reload after a previously pending command'
  );
  assert.match(indexSource, /nextState\.status\s*===\s*'COMPLETED'/u,
    'Index must only reload after a completed command'
  );
  assert.match(indexSource, /this\.detailProxyExpanded/u,
    'Index must only reload when the detail proxy surface is already open'
  );
  assert.match(indexSource, /this\.route\s*===\s*'DETAIL'/u,
    'Index must only reload while the detail route is still mounted'
  );
  assert.match(indexSource, /this\.detailProxyLeavePromise\s*===\s*undefined/u,
    'Index must not reload while the proxy leave drain is still in progress'
  );
  assert.match(indexSource, /activeProfileId\s*===\s*this\.detailProfileId/u,
    'Index must only reload when the active profile still matches the open detail profile'
  );
  assert.doesNotMatch(indexSource, /nextState\.status\s*===\s*'ERROR'[\s\S]*load\(this\.detailProfileId\)/u,
    'Index must not reload proxy state for error outcomes'
  );
});
