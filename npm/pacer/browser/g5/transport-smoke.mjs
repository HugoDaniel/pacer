// 13-route byte-hash transport smoke over a PREPARED webroot (G5
// corrections M-2): proves the SERVED bytes — every allowlisted route
// fetched over HTTP from a real server instance — match the manifest
// pins byte-for-byte, and prints the exact digest table for the wave
// record. External utility: it changes no runtime behavior and adds
// no route; it only reads through the public seam.
//
//   node browser/g5/transport-smoke.mjs [--root DIR]
//
// The server runs as a foreground ephemeral instance on port 0 (an
// OS-assigned free port), is closed in a finally block, and nothing
// is left listening. Exit 0 = every route digest-ok; exit 1 = any
// mismatch, with the offending route named. The manifest itself is
// self-excluded by design (circular pin) — its own sha256 identity
// hash is printed instead and must be compared out of band.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { createPacerServer, defaultWebroot, ROUTES } from '../server.mjs';

const argv = process.argv.slice(2);
let root = defaultWebroot();
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--root') {
    if (i + 1 >= argv.length) {
      console.error('--root requires a value — usage: transport-smoke.mjs [--root DIR]');
      process.exit(2);
    }
    i++;
    root = argv[i];
  } else {
    console.error(`unknown argument ${argv[i]} — usage: transport-smoke.mjs [--root DIR]`);
    process.exit(2);
  }
}

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const h = await createPacerServer({ root, port: 0 });
let failures = 0;
try {
  const origin = `http://127.0.0.1:${h.port}`;
  console.log(`transport smoke — ephemeral server on ${origin} (root: ${h.root})`);
  const manifestBytes = new Uint8Array(
    await (await fetch(`${origin}/manifest.json`)).arrayBuffer(),
  );
  const manifest = JSON.parse(new TextDecoder().decode(manifestBytes));
  const manifestHash = sha256(manifestBytes);

  for (const [route, def] of Object.entries(ROUTES)) {
    if (route === '/__requests.json') continue; // readback endpoint, no pin
    const res = await fetch(`${origin}${route}`);
    if (!res.ok) {
      failures++;
      console.log(`${route} HTTP ${res.status} — FAIL (expected 200)`);
      continue;
    }
    const mime = res.headers.get('content-type') ?? '';
    if (mime !== def.mime) {
      failures++;
      console.log(`${route} mime "${mime}" — FAIL (expected "${def.mime}")`);
      continue;
    }
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (route === '/manifest.json') {
      // Self-excluded from its own inventory: identity hash only.
      const disk = sha256(readFileSync(path.join(h.root, def.file)));
      const ok = disk === manifestHash;
      if (!ok) failures++;
      console.log(
        `${route} ${bytes.length} B sha256 ${manifestHash} manifest-identity ${ok ? 'OK' : 'FAIL (served != disk)'}`,
      );
      continue;
    }
    const pin = manifest.files[route];
    const digest = sha256(bytes);
    const ok = Boolean(pin) && pin.sha256 === digest && pin.bytes === bytes.length;
    if (!ok) failures++;
    console.log(
      `${route} ${bytes.length} B sha256 ${digest} ${ok ? `digest-ok (pin ${pin.sha256}, ${pin.bytes} B)` : `FAIL (pin ${pin?.sha256}, ${pin?.bytes} B)`}`,
    );
  }

  // The readback endpoint answers and reports the log the page sees.
  const logRes = await fetch(`${origin}/__requests.json`);
  const log = await logRes.json();
  const ok = logRes.status === 200 && Array.isArray(log.requests);
  if (!ok) failures++;
  console.log(`/__requests.json ${ok ? `readback-ok (${log.requests.length} entries)` : 'FAIL'}`);

  console.log(
    failures === 0
      ? `transport smoke PASS — all ${Object.keys(ROUTES).length} routes digest-ok against manifest sha256 ${manifestHash}`
      : `transport smoke FAIL — ${failures} route(s) mismatched`,
  );
} finally {
  await h.close();
}
process.exit(failures === 0 ? 0 : 1);
