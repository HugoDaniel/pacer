// G5 fixture static server — an exact-route allowlist over an ISOLATED
// prepared webroot (default <repo>/.agent/artifacts/g5-web, gitignored).
// It serves the fixture files and NOTHING else: no monorepo mount, no
// directory listing, no fallback, no source text.
//
// Import-side-effect-free by contract (the browser harness and the
// specs import it; nothing listens until createPacerServer is called
// or the module is the process entry point).
//
// Routes are a literal table — resolution never touches user input:
// the decoded pathname must EXACTLY match a key. Any other request —
// unknown paths, traversal in raw or percent-encoded form, `.sjon`
// source paths — is an explicit 404, and every request (served or
// refused) lands in the request log the page's proof footer reads
// back through /__requests.json.

import { existsSync, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

/** The exact served inventory. `file` paths are webroot-relative. */
export const ROUTES = Object.freeze({
  '/': { file: 'index.html', mime: 'text/html; charset=utf-8' },
  '/app.js': { file: 'app.js', mime: 'text/javascript; charset=utf-8' },
  '/style.css': { file: 'style.css', mime: 'text/css; charset=utf-8' },
  '/viewer.mjs': { file: 'viewer.mjs', mime: 'text/javascript; charset=utf-8' },
  '/rt.js': { file: 'rt.js', mime: 'text/javascript; charset=utf-8' },
  '/meta.js': { file: 'meta.js', mime: 'text/javascript; charset=utf-8' },
  '/pact.js': { file: 'pact.js', mime: 'text/javascript; charset=utf-8' },
  '/pacer-rt.wasm': { file: 'pacer-rt.wasm', mime: 'application/wasm' },
  '/manifest.json': { file: 'manifest.json', mime: 'application/json; charset=utf-8' },
  '/bundle/g4-bundle.png': { file: 'bundle/g4-bundle.png', mime: 'image/png' },
  '/bundle/g4-bundle-raw.png': { file: 'bundle/g4-bundle-raw.png', mime: 'image/png' },
  '/bundle/g5-hostile.png': { file: 'bundle/g5-hostile.png', mime: 'image/png' },
  '/bundle/g5-malformed.png': { file: 'bundle/g5-malformed.png', mime: 'image/png' },
  '/__requests.json': { special: 'requests', mime: 'application/json; charset=utf-8' },
});

const LOG_CAP = 512;
// A prepared webroot never contains these; their presence means
// someone pointed the server at the repo (or a package) — refuse.
const MOUNT_MARKERS = ['.git', 'build.zig', 'CLAUDE.md', 'package.json', 'node_modules'];

/**
 * Default webroot: <repoRoot>/.agent/artifacts/g5-web (three levels up
 * from browser/ = the repo root; `.agent/` is gitignored via
 * .git/info/exclude, so the served tree stays out of version control).
 */
export function defaultWebroot() {
  return path.resolve(
    fileURLToPath(new URL('../../../', import.meta.url)),
    '.agent',
    'artifacts',
    'g5-web',
  );
}

/**
 * Create the fixture server. Resolves once listening.
 * @param {{ root: string, port?: number, host?: string }} options
 * @returns {Promise<{ server: import('node:http').Server, port: number,
 *   root: string, log: object[], close: () => Promise<void> }>}
 */
export function createPacerServer({ root, port = 0, host = '127.0.0.1' }) {
  const resolved = path.resolve(root);
  if (!existsSync(resolved) || !statSync(resolved).isDirectory()) {
    return Promise.reject(
      new Error(`g5 fixture root is not a directory: ${resolved} (run: npm run g5:prepare)`),
    );
  }
  const markers = MOUNT_MARKERS.filter((m) => existsSync(path.join(resolved, m)));
  if (markers.length > 0) {
    return Promise.reject(
      new Error(
        `refusing to mount ${resolved}: it looks like a repo/package root (${markers.join(', ')}) — ` +
          'point --root at the prepared fixture webroot (default .agent/artifacts/g5-web)',
      ),
    );
  }

  const log = [];
  let seq = 0;
  const record = (entry) => {
    log.push({ seq: seq++, at: new Date().toISOString(), ...entry });
    if (log.length > LOG_CAP) log.splice(0, log.length - LOG_CAP);
  };

  const server = createServer(async (req, res) => {
    const finish = (status, mime, body) => {
      record({ method: req.method, path: req.url, status, bytes: body.length });
      res.writeHead(status, {
        'content-type': mime,
        'content-length': body.length,
        'cache-control': 'no-store',
      });
      res.end(req.method === 'HEAD' ? undefined : body);
    };
    const refuse = (status, message) =>
      finish(
        status,
        'application/json; charset=utf-8',
        Buffer.from(JSON.stringify({ error: message })),
      );

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return refuse(405, 'method not allowed — the fixture serves GET/HEAD only');
    }
    // Path-ONLY target handling: never hand the raw target to the URL
    // parser — `//host/path` would be absorbed as an authority and
    // `..` normalized away before any check could see it. Split off
    // query/fragment, percent-decode ONCE, then demand a clean
    // absolute path; the exact-match table does the rest.
    const raw = req.url ?? '/';
    const cut = raw.search(/[?#]/);
    let pathname;
    try {
      const decoded = decodeURIComponent(cut === -1 ? raw : raw.slice(0, cut));
      if (
        !decoded.startsWith('/') ||
        decoded.includes('//') ||
        decoded.includes('\\') ||
        decoded.includes('..') ||
        decoded.includes('\0')
      ) {
        return refuse(404, 'not found — no such fixture route');
      }
      pathname = decoded;
    } catch {
      return refuse(404, 'not found — malformed request path');
    }

    const route = ROUTES[pathname];
    if (!route) {
      return refuse(
        404,
        `not found — no fixture route ${pathname} (source paths and compiler artifacts are never served)`,
      );
    }
    if (route.special === 'requests') {
      // The readback includes itself: record first, serialize, then
      // patch the entry's byte count so the log stays exact.
      const entry = {
        seq: seq++,
        at: new Date().toISOString(),
        method: req.method,
        path: req.url,
        status: 200,
        bytes: 0,
      };
      log.push(entry);
      if (log.length > LOG_CAP) log.splice(0, log.length - LOG_CAP);
      const body = Buffer.from(JSON.stringify({ requests: log }, null, 2));
      entry.bytes = body.length;
      res.writeHead(200, {
        'content-type': route.mime,
        'content-length': body.length,
        'cache-control': 'no-store',
      });
      return void res.end(req.method === 'HEAD' ? undefined : body);
    }
    const filePath = path.join(resolved, route.file);
    let body;
    try {
      body = await readFile(filePath);
    } catch {
      return refuse(404, `not found — fixture file missing (run: npm run g5:prepare): ${pathname}`);
    }
    return finish(200, route.mime, body);
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      resolve({
        server,
        port: server.address().port,
        root: resolved,
        log,
        close: () => new Promise((done) => server.close(() => done())),
      });
    });
  });
}

/** Entry-point guard: `node browser/server.mjs [--port N] [--root D] [--host H]`. */
function main(argv) {
  const thisFile = pathToFileURL(fileURLToPath(import.meta.url)).href;
  if (!argv[1] || pathToFileURL(path.resolve(argv[1])).href !== thisFile) return false;
  const opts = { root: defaultWebroot(), port: 8046, host: '127.0.0.1' };
  for (let i = 2; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === '--port') opts.port = Number(argv[++i]);
    else if (flag === '--root') opts.root = path.resolve(argv[++i]);
    else if (flag === '--host') opts.host = argv[++i];
    else {
      console.error(
        `unknown argument ${flag} — usage: node server.mjs [--port 8046] [--root DIR] [--host 127.0.0.1]`,
      );
      process.exit(2);
    }
  }
  createPacerServer(opts).then(
    (h) => {
      console.log(`g5 fixture serving ${h.root} at http://${opts.host}:${h.port}/ (Ctrl-C stops)`);
      const stop = () => h.close().then(() => process.exit(0));
      process.on('SIGINT', stop);
      process.on('SIGTERM', stop);
    },
    (error) => {
      console.error(String(error?.message ?? error));
      process.exit(1);
    },
  );
  return true;
}

if (!main(process.argv)) {
  // Imported as a module: nothing listens, nothing logs — side-effect-free.
}
