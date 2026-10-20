// Playwright config for the G5 browser proof. Plain-object config on
// purpose: this package does not depend on @playwright/test — the
// runner comes from the sibling pngine checkout's existing install
// (see browser/g5/playwright.mjs), so importing '@playwright/test'
// here would fail before the runner even starts.
//
// The server command is the SAME documented command the parent/QA
// uses (`npm run g5:serve` semantics: node browser/server.mjs), bound
// to the fixture port 8046; reuseExistingServer lets an externally
// started server (the parent's) be used as-is.
//
// PACER_G5_PORT / PACER_G5_ROOT (G5 corrections wave): a worker run
// can point the proof at its own ephemeral server + webroot — e.g. a
// RED run against a preserved pre-fix copy — without touching the
// parent's 8046 origin. Unset → the documented defaults, unchanged.
const port = process.env.PACER_G5_PORT ?? '8046';
const rootFlag = process.env.PACER_G5_ROOT ? ` --root ${process.env.PACER_G5_ROOT}` : '';

export default {
  testDir: './browser',
  testMatch: /bundle-names\.spec\.js/,
  timeout: 120_000,
  expect: { timeout: 15_000 },
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    headless: true,
    viewport: { width: 1365, height: 900 },
  },
  webServer: {
    command: `node browser/server.mjs --port ${port}${rootFlag}`,
    url: `http://127.0.0.1:${port}/manifest.json`,
    reuseExistingServer: true,
    timeout: 15_000,
  },
};
