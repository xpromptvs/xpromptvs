// Draw the actual footer CSS: remote native clients retain the web connection status.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { chromium } from '../../e2e/node_modules/@playwright/test/index.mjs';
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.setContent(`<html data-native-client="true"><body><footer id="statusbar" data-local-client="false">
    <span id="status-dot" class="dot" data-state="connected"></span><div id="status-cells" class="status-cells">
    <span class="status-cell" data-cell="state">connected <span class="status-detail">p2p</span></span>
    <span class="status-divider"></span><span class="status-cell" data-cell="remote">remote access enabled</span>
    </div></footer></body></html>`);
  await page.addStyleTag({ content: readFileSync(new URL('../src/client/style.css', import.meta.url), 'utf8') });
  await page.addStyleTag({ content: readFileSync(new URL('../src/client/terminal-settings.css', import.meta.url), 'utf8') });
  const visible = async selector => page.locator(selector).evaluate(e => getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0);
  assert.equal(await visible('#status-dot'), true);
  assert.equal(await visible('[data-cell="state"]'), true);
  assert.equal(await visible('.status-divider'), true);
  await page.locator('#statusbar').evaluate(e => e.dataset.localClient = 'true');
  assert.equal(await visible('#status-dot'), false);
  assert.equal(await visible('[data-cell="state"]'), false);
  assert.equal(await visible('.status-divider'), true, 'This Mac retains the sharing divider');
  await page.locator('#status-dot').evaluate(e => e.dataset.state = 'connecting');
  assert.equal(await visible('[data-cell="state"]'), true, 'This Mac still reports connecting/errors');
  console.log('PASS: remote native connection status visible; local connected status hidden; local sharing divider and connecting status retained.');
} finally { await browser.close(); }
