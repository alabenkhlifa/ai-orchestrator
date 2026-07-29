// Shared helpers for the authenticated browser scenarios.
//
// The product issues an application session only through a live GitHub round
// trip and a hosted session only through a delivered passwordless credential,
// neither of which the local end-to-end server can perform. The dev/test-only
// bootstrap route establishes those sessions and seeds one scenario's project
// graph through the real domain commands; these helpers drive it.
const { expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

// Seeds one scenario and leaves its sessions in this browser context.
async function bootstrap(page, scenario, params = {}) {
  const query = new URLSearchParams({ scenario, ...params });
  const response = await page.goto(`/_e2e/session?${query}`);

  expect(response.status(), `bootstrap ${scenario} failed`).toBe(200);
  return await response.json();
}

async function waitConnected(page) {
  await page.waitForFunction(
    () =>
      window.liveSocket &&
      window.liveSocket.isConnected() &&
      document.querySelector("[data-phx-main]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15000 },
  );
}

async function openLive(page, path) {
  await page.goto(path);
  await waitConnected(page);
}

// The product forms debounce their change event. Filling and submitting in the
// same tick can let the debounced change land after the submit and reset the
// result the assertion is waiting for, so the debounce is allowed to settle.
const DEBOUNCE_MS = 350;

async function fillDebounced(page, selector, value) {
  await page.locator(selector).fill(value);
  await page.waitForTimeout(DEBOUNCE_MS);
}

// Tabs forward until the expected element holds focus, then reports the focus
// ring the keyboard user actually sees.
async function tabTo(page, selector, limit = 30) {
  const target = page.locator(selector);

  for (let step = 0; step < limit; step += 1) {
    if (await target.evaluate((el) => el === document.activeElement).catch(() => false)) {
      return await focusRing(page);
    }
    await page.keyboard.press("Tab");
  }

  throw new Error(`never reached ${selector} with the keyboard`);
}

async function focusRing(page) {
  return await page.evaluate(() => {
    const style = getComputedStyle(document.activeElement);
    return { style: style.outlineStyle, width: style.outlineWidth };
  });
}

async function expectNoSeriousAxeViolations(page) {
  const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa"]).analyze();
  const serious = results.violations.filter((v) => ["serious", "critical"].includes(v.impact));

  expect(serious, serious.map((v) => `${v.id}: ${v.help}`).join("\n")).toEqual([]);
}

module.exports = {
  bootstrap,
  expectNoSeriousAxeViolations,
  fillDebounced,
  focusRing,
  openLive,
  tabTo,
  waitConnected,
};
