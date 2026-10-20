// The G5 browser proof (playwright spec, run via browser/g5/playwright.mjs
// so the runner resolves from pngine's existing install — pacer adds
// no dependency). Resolves '@playwright/test' through pngine's
// package root explicitly: the spec must load the SAME runner
// instance that is executing it.
//
// Assertions follow the direction report's acceptance list: literal
// names, agreeing compressed/raw variants, supplied-time writes at
// the hand-oracle values, zero `.sjon` fetches in the observed server
// log, the malformed bundle producing the real error state (stale
// data cleared, eval blocked until a good load), hostile names
// rendered as literal glyphs with no injected img/b elements, both
// widths, and keyboard operation. Digests come from the page's own
// passive readback (window.__pacerProof) — computed in-page over the
// fetched bytes, never from headers.

import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Five levels up from browser/g5/ — the sibling pngine checkout (B4).
const PNGINE_ROOT = process.env.PACER_PNGINE
  ? path.resolve(process.env.PACER_PNGINE)
  : fileURLToPath(new URL('../../../../../pngine', import.meta.url));
const require_from_pngine = createRequire(path.join(PNGINE_ROOT, 'package.json'));
if (!existsSync(path.join(PNGINE_ROOT, 'package.json'))) {
  throw new Error(`pngine checkout not found at ${PNGINE_ROOT} (set PACER_PNGINE)`);
}
const { expect, test } = require_from_pngine('@playwright/test');

const HOSTILE = '<b>&<img/src=x>'; // the authored score's literal scene name
const f09 = Math.fround(0.9).toString(); // '0.8999999761581421'

async function waitReady(page) {
  await expect(page.locator('#status')).toHaveClass(/ready|error/, { timeout: 30_000 });
}

test('compressed variant: literal name, exposed metadata, oracle writes, verified digests', async ({
  page,
}) => {
  await page.goto('/');
  await waitReady(page);
  await expect(page.locator('#names')).toHaveText('drop');
  await expect(page.locator('#scene-count')).toHaveText('1');
  await expect(page.locator('#transport-bpm')).toHaveText('120');
  await expect(page.locator('#transport-dur')).toHaveText('2882880');
  await expect(page.locator('#transport-end')).toHaveText('loop');
  await expect(page.locator('#transport-bpb')).toHaveText('4');
  await expect(page.locator('#scene-start')).toHaveText('0');
  await expect(page.locator('#scene-dur')).toHaveText('1441440');
  await expect(page.locator('#names')).not.toHaveText(/<!--|[<>]/);

  // Supplied-time writes: preset t=0 then the oracle literal; t=2 for
  // the f32 spelling of 0.9. Presets set the numeric input; eval is
  // the explicit action.
  await page.locator('#preset-0').click();
  await page.locator('#eval-button').click();
  await page.locator('#preset-2').click();
  await page.locator('#eval-button').click();
  const rows = page.locator('#writes-table tbody tr');
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).locator('td')).toHaveText(['0', /#0 reg0 ×1/, '0.5', '1']);
  await expect(rows.nth(1).locator('td')).toHaveText(['2', /#0 reg0 ×1/, f09, '1']);
  await expect(page.locator('#writes')).toContainText('evals: 2');

  // Passive digest proof — computed in-page, compared against the manifest.
  const proof = await page.evaluate(() => window.__pacerProof);
  expect(proof.digests.bundle.match).toBe(true);
  expect(proof.digests.cartridge.match).toBe(true);
  expect(proof.digests.wasm.match).toBe(true);
  expect(proof.digests.bundle.sha256).toMatch(/^[0-9a-f]{64}$/);
  await expect(page.locator('#hash')).toContainText(/sha256 [0-9a-f]{64}/);

  // Zero source fetches — observed from the server's own log.
  const requestLog = await page.locator('#request-log').textContent();
  expect(requestLog).not.toContain('.sjon');
  expect(proof.requests.every((e) => !e.path.includes('.sjon'))).toBe(true);
});

test('raw variant extracts the same cartridge and agrees on the oracle', async ({ page }) => {
  await page.goto('/');
  await waitReady(page);
  await page.locator('#toggle-raw').click();
  await expect(page.locator('#names')).toHaveText('drop');
  await expect(page.locator('#toggle-raw')).toHaveAttribute('aria-pressed', 'true');
  const proof = await page.evaluate(() => window.__pacerProof);
  expect(proof.variant).toBe('raw');
  expect(proof.digests.cartridge.match).toBe(true);
  // The raw cartridge byte-digest equals the compressed variant's pin —
  // both variants extract the SAME cartridge (manifest cross-checked in-page).
  const manifest = await page.evaluate(() => fetch('/manifest.json').then((r) => r.json()));
  expect(proof.digests.cartridge.sha256).toBe(manifest.variants.compressed.cartridgeSha256);
  expect(manifest.variants.raw.flags).toBe(0);
  expect(manifest.variants.compressed.flags).toBe(1);
});

test('hostile names render as literal glyphs — no injected img/b elements', async ({ page }) => {
  await page.goto('/');
  await waitReady(page);
  await page.locator('#toggle-hostile').click();
  await expect(page.locator('#names')).toHaveText(HOSTILE);
  // No injected elements anywhere in the document.
  expect(await page.locator('img').count()).toBe(0);
  expect(await page.locator('b').count()).toBe(0);
  // The names node's HTML carries escaped entities — the textContent path.
  expect(await page.locator('#names').innerHTML()).toBe('&lt;b&gt;&amp;&lt;img/src=x&gt;');
  const proof = await page.evaluate(() => window.__pacerProof);
  expect(proof.names).toEqual([HOSTILE]);
});

test('malformed bundle: real walker error, stale data cleared, eval blocked until a good load', async ({
  page,
}) => {
  await page.goto('/');
  await waitReady(page);
  await page.locator('#preset-0').click();
  await page.locator('#eval-button').click();
  await expect(page.locator('#writes-table tbody tr')).toHaveCount(1);

  await page.locator('#toggle-malformed').click();
  await expect(page.locator('#error')).toBeVisible();
  await expect(page.locator('#error')).toContainText(/chunk at byte|declares|CRC|past the end/i);
  await expect(page.locator('#names')).toHaveText('—');
  await expect(page.locator('#writes-table tbody tr')).toHaveCount(0);
  await expect(page.locator('#eval-button')).toBeDisabled();
  await expect(page.locator('#hash')).toHaveText('—');
  const proof = await page.evaluate(() => window.__pacerProof);
  expect(proof.status).toBe('error');
  expect(proof.names).toBeNull();

  // A good load clears the error and re-enables eval.
  await page.locator('#toggle-compressed').click();
  await expect(page.locator('#names')).toHaveText('drop');
  await expect(page.locator('#error')).toBeHidden();
  await expect(page.locator('#eval-button')).toBeEnabled();
});

test('390 px: the same single column, all controls visible, no page overflow', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/');
  await waitReady(page);
  await expect(page.locator('#names')).toBeVisible();
  for (const id of [
    'toggle-compressed',
    'toggle-raw',
    'toggle-malformed',
    'toggle-hostile',
    'time-input',
    'eval-button',
  ]) {
    await expect(page.locator(`#${id}`)).toBeVisible();
  }
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);
});

test('keyboard-only: variant toggles operate with Enter', async ({ page }) => {
  await page.goto('/');
  await waitReady(page);
  await page.locator('#toggle-compressed').focus();
  await page.keyboard.press('Tab'); // → #toggle-raw
  await page.keyboard.press('Enter');
  await expect(page.locator('#toggle-raw')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#names')).toHaveText('drop');
});

// ── Async load races (G5 corrections H-1) ────────────────────────────
//
// The page must be last-intent-wins: a load that was clicked EARLIER
// but completes LATER must never commit state. Every gate below holds
// a REAL fetch of REAL served bytes (route.fetch → fulfill) and is
// released deterministically — the page app runs unmodified; no state
// is mocked. Post-release assertions use a bounded 5 s wait so a RED
// fails fast for the right reason (observed stale data), never a
// runner timeout.

test('race: rapid raw→hostile toggle — the stale raw completion never overwrites the hostile state', async ({
  page,
}) => {
  await page.goto('/');
  await waitReady(page);
  let releaseRaw;
  const rawGated = new Promise((release) => {
    releaseRaw = release;
  });
  await page.route('**/bundle/g4-bundle-raw.png', async (route) => {
    const response = await route.fetch(); // real bytes from the real server
    await rawGated; // hold the raw chain mid-flight
    await route.fulfill({ response });
  });

  await page.locator('#toggle-raw').click();
  await page.locator('#toggle-hostile').click(); // newer intent while raw is pending
  await expect(page.locator('#names')).toHaveText(HOSTILE);
  await expect(page.locator('#toggle-hostile')).toHaveAttribute('aria-pressed', 'true');

  releaseRaw(); // let the OLDER raw load finish now
  // Hostile must still own every committed zone — bounded wait: a
  // stale overwrite shows up as 'drop' near-instantly.
  await expect(page.locator('#names')).toHaveText(HOSTILE, { timeout: 5_000 });
  await expect(page.locator('#toggle-hostile')).toHaveAttribute('aria-pressed', 'true', {
    timeout: 5_000,
  });
  await expect(page.locator('#eval-button')).toBeEnabled({ timeout: 5_000 });
  const proof = await page.evaluate(() => window.__pacerProof);
  expect(proof.variant).toBe('hostile');
  expect(proof.names).toEqual([HOSTILE]);
  expect(proof.status).toBe('ready');
  // The committed digests must be the WINNER's, not the stale raw's.
  const manifest = await page.evaluate(() => fetch('/manifest.json').then((r) => r.json()));
  expect(proof.digests.bundle.sha256).toBe(manifest.variants.hostile.bundleSha256);
  expect(proof.digests.cartridge.sha256).toBe(manifest.variants.hostile.cartridgeSha256);
});

test('race: variant pending while malformed errors — the stale good completion never clears the failure', async ({
  page,
}) => {
  await page.goto('/');
  await waitReady(page);
  let releaseCompressed;
  const compressedGated = new Promise((release) => {
    releaseCompressed = release;
  });
  await page.route('**/bundle/g4-bundle.png', async (route) => {
    const response = await route.fetch();
    await compressedGated;
    await route.fulfill({ response });
  });

  await page.locator('#toggle-compressed').click(); // held mid-flight
  await page.locator('#toggle-malformed').click(); // the real walker error
  await expect(page.locator('#error')).toBeVisible();
  await expect(page.locator('#names')).toHaveText('—');
  await expect(page.locator('#writes-table tbody tr')).toHaveCount(0);

  releaseCompressed(); // the OLDER good load finishes now
  // The demonstrated failure must stay committed: no stale re-render,
  // no eval re-enable, no ready flip.
  await expect(page.locator('#names')).toHaveText('—', { timeout: 5_000 });
  await expect(page.locator('#writes-table tbody tr')).toHaveCount(0, { timeout: 5_000 });
  await expect(page.locator('#eval-button')).toBeDisabled({ timeout: 5_000 });
  await expect(page.locator('#hash')).toHaveText('—', { timeout: 5_000 });
  await expect(page.locator('#error')).toBeVisible({ timeout: 5_000 });
  const proof = await page.evaluate(() => window.__pacerProof);
  expect(proof.status).toBe('error');
  expect(proof.names).toBeNull();
  expect(proof.variant).toBeNull();
});

test('race: malformed pending while a good load commits — the stale failure never clobbers the good state', async ({
  page,
}) => {
  await page.goto('/');
  await waitReady(page);
  let releaseMalformed;
  const malformedGated = new Promise((release) => {
    releaseMalformed = release;
  });
  await page.route('**/bundle/g5-malformed.png', async (route) => {
    const response = await route.fetch();
    await malformedGated;
    await route.fulfill({ response });
  });

  await page.locator('#toggle-malformed').click(); // held mid-flight
  await page.locator('#toggle-hostile').click(); // completes for real
  await expect(page.locator('#names')).toHaveText(HOSTILE);
  await expect(page.locator('#eval-button')).toBeEnabled();

  releaseMalformed(); // the OLDER failing chain wakes up now
  // Its error must NOT land: the good state stays committed.
  await expect(page.locator('#error')).toBeHidden({ timeout: 5_000 });
  await expect(page.locator('#names')).toHaveText(HOSTILE, { timeout: 5_000 });
  await expect(page.locator('#eval-button')).toBeEnabled({ timeout: 5_000 });
  const proof = await page.evaluate(() => window.__pacerProof);
  expect(proof.status).toBe('ready');
  expect(proof.variant).toBe('hostile');
  expect(proof.names).toEqual([HOSTILE]);
});

test('blank time input is refused with a visible validity hint — no eval write, no count advance', async ({
  page,
}) => {
  await page.goto('/');
  await waitReady(page);
  await page.locator('#preset-0').click();
  await page.locator('#eval-button').click();
  await expect(page.locator('#writes-table tbody tr')).toHaveCount(1);
  const writesLine = await page.locator('#writes').textContent();
  const writesProofBefore = (await page.evaluate(() => window.__pacerProof.writes)).length;

  // Clear the field entirely — the page previously coerced '' to t=0.
  await page.locator('#time-input').fill('');
  await page.locator('#eval-button').click();

  await expect(page.locator('#writes-table tbody tr')).toHaveCount(1, { timeout: 5_000 });
  await expect(page.locator('#writes')).toHaveText(writesLine, { timeout: 5_000 });
  const hint = await page.locator('#time-input').evaluate((el) => el.validationMessage);
  expect(hint).toContain('finite');
  const writesProofAfter = (await page.evaluate(() => window.__pacerProof.writes)).length;
  expect(writesProofAfter).toBe(writesProofBefore);
});
