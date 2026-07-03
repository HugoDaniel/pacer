// Packaging contract: the published shape is correct and the public API
// resolves through the package name exactly as a consumer imports it.
// (Functional behaviour lives in driver.test.js / corpus.test.js.)

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const fromRoot = (rel) => fileURLToPath(new URL(`../${rel}`, import.meta.url));

test('publishable: not private, ESM, ships the wasm + types + license', () => {
  assert.notEqual(pkg.private, true);
  assert.equal(pkg.type, 'module');
  assert.equal(pkg.sideEffects, false);
  assert.ok(pkg.version, 'has a version');
  assert.equal(pkg.license, 'CC0-1.0', 'declares the CC0-1.0 license');
  assert.ok(Array.isArray(pkg.files), 'has a files allowlist');
  assert.ok(pkg.files.includes('pacer.wasm'), 'files ships pacer.wasm');
  assert.ok(pkg.files.includes('types'), 'files ships the .d.ts');
  assert.ok(pkg.files.includes('LICENSE'), 'files ships the LICENSE');
  assert.ok(existsSync(fromRoot('LICENSE')), 'LICENSE exists on disk');
  assert.match(
    readFileSync(fromRoot('LICENSE'), 'utf8'),
    /CC0 1\.0 Universal/,
    'LICENSE is the CC0 text',
  );
  assert.equal(pkg.exports['.'].types, './types/index.d.ts');
});

test('publishConfig points the publish at the self-hosted registry', () => {
  assert.ok(pkg.publishConfig, 'has a publishConfig');
  assert.match(
    pkg.publishConfig.registry,
    /^https:\/\/git\.hugodaniel\.com\/api\/packages\/hugo\/npm\/$/,
    'registry is the Gitea per-owner npm endpoint (trailing slash required)',
  );
});

test('every exports condition points at a runtime file on disk', () => {
  for (const [sub, target] of Object.entries(pkg.exports)) {
    const conds = typeof target === 'string' ? { default: target } : target;
    for (const [cond, rel] of Object.entries(conds)) {
      // `types` and `pacer.wasm` are build outputs — verified by `npm run
      // build` + `npm pack`, not present during a bare `node --test`.
      if (cond === 'types' || rel.endsWith('.wasm')) continue;
      assert.ok(existsSync(fromRoot(rel)), `exports["${sub}"].${cond} → ${rel} is missing`);
    }
  }
});

test('public API resolves through the package name (self-reference)', async () => {
  const { Pacer } = await import('pacer');
  assert.equal(typeof Pacer, 'function');
  assert.equal(typeof Pacer.load, 'function');

  const route = await import('pacer/route');
  assert.equal(typeof route.toUniforms, 'function');
  assert.equal(typeof route.routeWrites, 'function');

  const clock = await import('pacer/clock');
  assert.equal(typeof clock.perfClock, 'function');
  assert.equal(typeof clock.masterClock, 'function');

  const audio = await import('pacer/audio');
  assert.equal(typeof audio.sointuHost, 'function');
  assert.equal(typeof audio.paramRegistry, 'function');
  assert.equal(typeof audio.applyParams, 'function');
});

test('version is in lockstep across package.json, build.zig.zon, and root.zig', () => {
  // The version is spelled by hand in three places; a release bump that
  // updates one but not the others ships a mislabeled package. Repo-root
  // reads are test-only (never published), same as corpus.test.js.
  const readRoot = (rel) =>
    readFileSync(fileURLToPath(new URL(`../../../${rel}`, import.meta.url)), 'utf8');
  const zon = readRoot('build.zig.zon').match(/\.version\s*=\s*"([^"]+)"/);
  const root = readRoot('src/root.zig').match(/pub const version\s*=\s*"([^"]+)"/);
  assert.ok(zon, 'build.zig.zon declares a .version');
  assert.ok(root, 'src/root.zig declares a pub const version');
  assert.equal(zon[1], pkg.version, 'build.zig.zon .version matches package.json');
  assert.equal(root[1], pkg.version, 'src/root.zig version matches package.json');
});
