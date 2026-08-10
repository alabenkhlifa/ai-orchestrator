const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

// Browser proof for the accountless empty-repository-initialization entry surface
// (specs/16, Task 2).
//
// The behavioural flow (eligibility classification, plan creation, and the
// guided-question decision gate) is proven deterministically at the LiveView
// level, where the device store is isolated per test. These browser scenarios
// mirror `local-onboarding.spec.js`'s style: they assert the graphical,
// terminal-free discovery guidance, the connection-state vocabulary, mobile
// call-to-action treatment, and accessibility, which hold regardless of the
// shared dev worker state.

// Shell-command shapes that would mean the user was asked to use a terminal.
const TERMINAL_MARKERS = [/\bsudo\b/, /\bbrew\b/, /\bcurl\b/, /\bchmod\b/, /\bbash\b/, /\$\s/, /```/];

test.describe("empty repository initialization", () => {
  test("reaches worker discovery without terminal commands", async ({ page }) => {
    await page.goto("/onboarding/empty-repository");

    await expect(
      page.getByRole("heading", { name: /Start with an empty repository/i }),
    ).toBeVisible();

    // Worker discovery is always rendered in one of its four states.
    await expect(page.locator("[data-worker-status]")).toBeVisible();

    // Graphical guidance never asks the user to run a terminal command.
    const body = await page.locator("body").innerText();
    for (const marker of TERMINAL_MARKERS) {
      expect(body, `discovery guidance must not contain ${marker}`).not.toMatch(marker);
    }
  });

  test("keeps a full-width primary action for mobile and never wraps labels", async ({ page }) => {
    await page.goto("/onboarding/empty-repository");

    const cta = page.locator("[data-worker-status] .w-full").first();
    await expect(cta).toBeVisible();

    const nowrap = await cta.evaluate((el) => getComputedStyle(el).whiteSpace);
    expect(nowrap).toBe("nowrap");
  });

  test("returns to the entry surface", async ({ page }) => {
    await page.goto("/onboarding/empty-repository");
    await page.getByRole("link", { name: /Back/i }).click();
    await expect(page).toHaveURL(/\/$/);
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`has no serious accessibility violations (${colorScheme})`, async ({ page }) => {
      await page.emulateMedia({ colorScheme });
      await page.goto("/onboarding/empty-repository");
      const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa"]).analyze();
      const serious = results.violations.filter((v) => ["serious", "critical"].includes(v.impact));
      expect(serious, serious.map((v) => `${v.id}: ${v.help}`).join("\n")).toEqual([]);
    });
  }
});
