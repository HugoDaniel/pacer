// Launcher for the G5 browser proof: resolves the playwright CLI from
// the SIBLING pngine checkout's existing node_modules (pacer gains no
// new dependency), then runs the spec in npm/pacer with this
// directory's config. Loud failure with resolved absolute paths when
// the runner is absent — never a silent skip.
//
//   npm run test:browser                     # headless run
//   node browser/g5/playwright.mjs --headed  # or pass playwright args

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const G5 = fileURLToPath(new URL('./', import.meta.url));
const NPM_PACER = path.resolve(G5, '..', '..');
// Five levels up from browser/g5/ (B4: g5 → browser → npm/pacer →
// npm → repo root → the parent holding the sibling checkout).
const DEFAULT_PNGINE = fileURLToPath(new URL('../../../../../pngine', import.meta.url));

const pngineRoot = process.env.PACER_PNGINE
  ? path.resolve(process.env.PACER_PNGINE)
  : DEFAULT_PNGINE;
const pwBin = path.join(pngineRoot, 'node_modules', '.bin', 'playwright');
if (!existsSync(pwBin)) {
  console.error(
    `g5:browser: playwright CLI not found at ${pwBin} — the runner lives in the sibling pngine checkout ` +
      `(set PACER_PNGINE or install @playwright/test there); no new dependency is added to pacer`,
  );
  process.exit(1);
}

const config = path.join(NPM_PACER, 'playwright.config.js');
const result = spawnSync(pwBin, ['test', '--config', config, ...process.argv.slice(2)], {
  cwd: NPM_PACER,
  stdio: 'inherit',
});
if (result.error) {
  console.error(`g5:browser: failed to exec ${pwBin}: ${result.error.code}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
