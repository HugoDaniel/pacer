// Node spec for the G5 fixture static server (browser/server.mjs).
//
// This file lives OUTSIDE `npm test` autodiscovery on purpose: node's
// recursive test walk matches `*.test.*` / `test-*` names, and this
// file is deliberately named `server-spec.mjs` so `npm test` (and
// playwright's default testMatch) never discover it. Run it
// explicitly:
//
//   node --test browser/g5/server-spec.mjs
//
// Safety posture under test (G5 brief): a fresh configured root (a
// temp dir the spec fills itself — never the repo, never an arbitrary
// user path); traversal in raw and percent-encoded forms must 404;
// source paths (.sjon) must 404 explicitly with no stale body; MIME
// for .wasm must be application/wasm; the route table is an exact
// allowlist. Each block pairs the negative assertion with a positive
// control (a good path 200 in the same server) so the harness
// provably distinguishes blocked from reachable — the mutation
// control for an endpoint leak.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { get } from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createPacerServer } from '../server.mjs';

/**
 * GET with a RAW request target: unlike fetch (whose URL parser
 * normalizes backslashes and dot segments before a byte is sent) this
 * puts the exact bytes on the wire — what a malicious client does.
 * @returns {Promise<{ status: number, contentType: string | null, body: string }>}
 */
function rawGet(origin, target) {
  return new Promise((resolve, reject) => {
    const req = get(`${origin}${target}`, { rejectOnHttpError: false }, (res) => {
      let body = '';
      res.on('data', (c) => {
        body += c;
      });
      res.on('end', () =>
        resolve({
          status: res.statusCode ?? 0,
          contentType: res.headers['content-type'] ?? null,
          body,
        }),
      );
    });
    req.on('error', reject);
  });
}

/** Build a minimal but complete fixture webroot in a fresh temp dir. */
async function seedRoot(markers = []) {
  const root = await mkdtemp(path.join(tmpdir(), 'pacer-g5-server-'));
  await mkdir(path.join(root, 'bundle'), { recursive: true });
  await writeFile(path.join(root, 'index.html'), '<!doctype html><html><body>g5</body></html>');
  await writeFile(path.join(root, 'app.js'), 'export const k = 1;\n');
  await writeFile(path.join(root, 'style.css'), 'body { color: #111; }\n');
  await writeFile(path.join(root, 'manifest.json'), '{"seeded":true}\n');
  await writeFile(path.join(root, 'pacer-rt.wasm'), Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]));
  await writeFile(
    path.join(root, 'bundle', 'g4-bundle.png'),
    Buffer.from([0x89, 0x50, 0x4e, 0x47]),
  );
  for (const marker of markers) await writeFile(path.join(root, marker), 'marker');
  return root;
}

const SECRET = 'pacer-g5-secret-outside-the-webroot';

/** Fresh root + a secret sibling file that must never be served. */
async function seededPair() {
  const base = await mkdtemp(path.join(tmpdir(), 'pacer-g5-traversal-'));
  const root = path.join(base, 'web');
  await mkdir(root, { recursive: true });
  await writeFile(path.join(base, 'secret.txt'), SECRET);
  await mkdir(path.join(root, 'bundle'), { recursive: true });
  await writeFile(path.join(root, 'index.html'), '<!doctype html>ok');
  await writeFile(path.join(root, 'bundle', 'g4-bundle.png'), 'pngbytes');
  return { base, root };
}

test('import is side-effect-free: importing server.mjs starts no listener', () => {
  // The runner's own static import above must not have bound a port;
  // prove it behaviorally in a fresh process: if the module listened
  // at import time, the event loop would never drain and the process
  // would hang until the hard kill (exit null), not exit 0.
  const modUrl = fileURLToPath(new URL('../server.mjs', import.meta.url));
  const probe = spawnSync(
    process.execPath,
    [
      '--input-type=module',
      '-e',
      `await import(${JSON.stringify(modUrl)}); console.log('drained');`,
    ],
    { encoding: 'utf8', timeout: 10_000 },
  );
  assert.equal(probe.status, 0, `import did not drain: ${probe.stderr}`);
  assert.match(probe.stdout, /drained/);
});

test('serves exactly the allowlisted fixture routes from a fresh configured root', async () => {
  const root = await seedRoot();
  const h = await createPacerServer({ root, port: 0 });
  try {
    const base = `http://127.0.0.1:${h.port}`;
    for (const [route, mime] of [
      ['/', 'text/html'],
      ['/app.js', 'text/javascript'],
      ['/style.css', 'text/css'],
      ['/manifest.json', 'application/json'],
      ['/bundle/g4-bundle.png', 'image/png'],
    ]) {
      const res = await fetch(new URL(route, base));
      assert.equal(res.status, 200, `${route} must serve`);
      assert.ok(res.headers.get('content-type')?.startsWith(mime), `${route} mime`);
    }
    // MIME wasm must be exactly application/wasm (module streaming).
    const wasm = await fetch(new URL('/pacer-rt.wasm', base));
    assert.equal(wasm.status, 200);
    assert.equal(wasm.headers.get('content-type'), 'application/wasm');
    assert.deepEqual(
      [...new Uint8Array(await wasm.arrayBuffer())],
      [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0],
    );
    // HEAD works; other methods are refused.
    const head = await fetch(new URL('/', base), { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(await head.text(), '');
    const post = await fetch(new URL('/', base), { method: 'POST' });
    assert.equal(post.status, 405);
    // Unknown route: 404 with no stale body.
    const missing = await fetch(new URL('/bundle/not-a-file.png', base));
    assert.equal(missing.status, 404);
    assert.equal((await missing.text()).includes('pngbytes'), false);
  } finally {
    await h.close();
    await rm(root, { recursive: true, force: true });
  }
});

test('traversal — raw, encoded, double-encoded, backslash, null — never escapes the root', async () => {
  const { base, root } = await seededPair();
  const h = await createPacerServer({ root, port: 0 });
  try {
    const origin = `http://127.0.0.1:${h.port}`;
    // Mutation control FIRST: the secret exists on disk next to the
    // root, and a webroot file IS served — this server can tell the
    // difference, so the 404s below mean the guard, not a broken seed.
    const good = await rawGet(origin, '/bundle/g4-bundle.png');
    assert.equal(good.status, 200);
    assert.equal((await rawGet(origin, '/nope')).status, 404);
    for (const bad of [
      '/../secret.txt',
      '/bundle/../secret.txt',
      '/bundle/../../secret.txt',
      '/%2e%2e/secret.txt',
      '/%2e%2e%2fsecret.txt',
      '/..%2fsecret.txt',
      '/%252e%252e/secret.txt',
      '/..%255csecret.txt',
      '/%5c..%5csecret.txt',
      '/..\\secret.txt',
      '/bundle%00.png',
      '/%00',
      '//secret.txt',
      '/./../secret.txt',
      '/bundle/g4-bundle.png/../../secret.txt',
    ]) {
      const res = await rawGet(origin, bad);
      assert.equal(res.status, 404, `expected 404 for ${bad}`);
      assert.equal(res.body.includes(SECRET), false, `leak via ${bad}`);
    }
  } finally {
    await h.close();
    await rm(base, { recursive: true, force: true });
  }
});

test('source paths (.sjon) are 404 — explicit, no stale data, honestly logged', async () => {
  const root = await seedRoot();
  const h = await createPacerServer({ root, port: 0 });
  try {
    const origin = `http://127.0.0.1:${h.port}`;
    for (const p of ['/bundle-wave.score.sjon', '/score.sjon', '/bundle/g4.sjon']) {
      const res = await rawGet(origin, p);
      assert.equal(res.status, 404, `${p} must be explicitly 404`);
      assert.match(res.body, /not found/, `${p} refusal is explicit`);
      assert.equal(res.body.includes('(target'), false, 'no score text in a refusal body');
      assert.equal(res.body.includes('scene'), false, 'no stale data in a refusal body');
    }
    // The server-side log records the 404s — a .sjon fetch attempt can
    // never hide (the QA proof asserts zero .sjon requests).
    const logRes = await fetch(new URL('/__requests.json', origin));
    assert.equal(logRes.status, 200);
    const log = await logRes.json();
    assert.ok(Array.isArray(log.requests));
    const sjon = log.requests.filter((e) => e.path.includes('.sjon'));
    assert.equal(sjon.length, 3);
    for (const e of sjon) assert.equal(e.status, 404);
    const good = log.requests.find((e) => e.path === '/__requests.json');
    assert.equal(good.status, 200);
  } finally {
    await h.close();
    await rm(root, { recursive: true, force: true });
  }
});

test('refuses to mount repo-looking or missing roots (no monorepo accident)', async () => {
  await assert.rejects(() =>
    createPacerServer({ root: path.join(tmpdir(), 'pacer-g5-nope-missing') }),
  );
  for (const marker of ['.git', 'build.zig', 'CLAUDE.md', 'package.json']) {
    const root = await seedRoot([marker]);
    try {
      await assert.rejects(() => createPacerServer({ root }), Error);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});
