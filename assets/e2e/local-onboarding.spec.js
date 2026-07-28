const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

// Browser proof for the accountless local-onboarding surface (specs/02, Task 7).
//
// The behavioural flow (stub pairing, native selection, first-connection
// disclosure and confirmation, project creation, the on-device dashboard, and
// Locate-repository recovery) is proven deterministically at the LiveView level,
// where the device store is isolated per test. These browser scenarios mirror the
// entry-surface style: they assert the graphical, terminal-free guidance, the
// storage-mode explanation, the connection-state vocabulary, mobile call-to-action
// treatment, and accessibility, which hold regardless of the shared dev worker
// state.

// Shell-command shapes that would mean the user was asked to use a terminal.
const TERMINAL_MARKERS = [/\bsudo\b/, /\bbrew\b/, /\bcurl\b/, /\bchmod\b/, /\bbash\b/, /\$\s/, /```/];

test.describe("local onboarding", () => {
  test("explains the storage modes and reaches worker discovery without terminal commands", async ({
    page,
  }) => {
    await page.goto("/onboarding/local");

    await expect(
      page.getByRole("heading", { name: /Connect a repository on this computer/i }),
    ).toBeVisible();

    // Storage-mode explanation names both modes before onboarding continues.
    const storage = page.locator("[data-storage-explanation]");
    await expect(storage).toBeVisible();
    await expect(storage).toContainText("On this device");
    await expect(storage).toContainText("In my SDD Orchestrator account");

    // Worker discovery is always rendered in one of its four states.
    await expect(page.locator("[data-worker-status]")).toBeVisible();

    // Graphical guidance never asks the user to run a terminal command.
    const body = await page.locator("body").innerText();
    for (const marker of TERMINAL_MARKERS) {
      expect(body, `install guidance must not contain ${marker}`).not.toMatch(marker);
    }
  });

  test("keeps a full-width primary action for mobile and never wraps labels", async ({ page }) => {
    await page.goto("/onboarding/local");

    // Whatever the worker state, the primary action is full-width on mobile.
    const cta = page.locator("[data-worker-status] .w-full").first();
    await expect(cta).toBeVisible();

    // Buttons carry the shared no-wrap treatment.
    const nowrap = await cta.evaluate((el) => getComputedStyle(el).whiteSpace);
    expect(nowrap).toBe("nowrap");
  });

  test("returns to the sign-in entry surface", async ({ page }) => {
    await page.goto("/onboarding/local");
    await page.getByRole("link", { name: /Back to sign in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
  });

  test("an unknown on-device project routes back to local onboarding", async ({ page }) => {
    await page.goto("/local/projects/00000000-0000-0000-0000-000000000000");
    await expect(page).toHaveURL(/\/onboarding\/local$/);
    await expect(
      page.getByRole("heading", { name: /Connect a repository on this computer/i }),
    ).toBeVisible();
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`local onboarding has no serious accessibility violations (${colorScheme})`, async ({
      page,
    }) => {
      await page.emulateMedia({ colorScheme });
      await page.goto("/onboarding/local");
      const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa"]).analyze();
      const serious = results.violations.filter((v) => ["serious", "critical"].includes(v.impact));
      expect(serious, serious.map((v) => `${v.id}: ${v.help}`).join("\n")).toEqual([]);
    });
  }
});
