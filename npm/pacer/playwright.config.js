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

export default {
  testDir: './browser',
  testMatch: /bundle-names\.spec\.js/,
  timeout: 120_000,
  expect: { timeout: 15_000 },
  use: {
    baseURL: 'http://127.0.0.1:8046',
    headless: true,
    viewport: { width: 1365, height: 900 },
  },
  webServer: {
    command: 'node browser/server.mjs --port 8046',
    url: 'http://127.0.0.1:8046/manifest.json',
    reuseExistingServer: true,
    timeout: 15_000,
  },
};
