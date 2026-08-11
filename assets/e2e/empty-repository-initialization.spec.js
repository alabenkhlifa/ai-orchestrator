const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

// Browser proof for the accountless empty-repository-initialization entry surface
// (specs/16, Tasks 2 and 3).
//
// The behavioural flow (eligibility classification, plan creation, and the
// guided-question decision gate) is proven deterministically at the LiveView
// level, where the device store is isolated per test. These browser scenarios
// mirror `local-onboarding.spec.js`'s style: they assert the graphical,
// terminal-free discovery guidance, the connection-state vocabulary, mobile
// call-to-action treatment, and accessibility, which hold regardless of the
// shared dev worker state.
//
// Task 3's plan-review and confirmation surface (AC-04, AC-05, AC-06) is
// fully proven at the LiveView level in
// `repository_initialization_live_test.exs`: the fixed skeleton preview, the
// kit package's exact details with its include/decline toggle and AC-06
// decline copy, the no-kit-available case, the worker/provider summary, the
// AC-05 processing-boundary disclosure gating the confirm control, a
// successful confirmation, and the changed-input "plan changed" case. It is
// not reachable from this Playwright suite yet: reaching it requires
// `select_folder` to resolve to a genuinely empty directory, which in
// dev/e2e mode reads `Application.get_env(:sdd_orchestrator,
// :device_worker_stub_folder)` and otherwise falls back to the running
// server's own working directory (this checkout — not empty, not eligible).
// The Elixir LiveView test suite sets that value in-process with
// `Application.put_env/3`; nothing in `playwright.config.js` or
// `E2EBootstrapController` currently gives an out-of-process browser test an
// equivalent seam. The scenario below is written to the same shape as the
// real flow and left `test.skip` (documented, not deleted) so it is ready to
// enable once such a seam exists — do not un-skip it without adding that
// wiring first.
//
// Task 6's own build-and-handoff surface (AC-13, AC-14) — "Start building"
// running `StagingBuilder` -> `Publisher` -> `Handoff` in sequence and
// reaching `:building_result` with the commit and the four independent
// readiness axes, or `:failed` on a pipeline failure — is fully proven at
// the LiveView level in `repository_initialization_live_test.exs`. It has
// the exact same out-of-process seam limitation as Task 3's scenario above
// (reaching the confirmed `:reviewing_plan` step at all requires the same
// `device_worker_stub_folder` seam), plus it also requires
// `:initialization_staging_root` to be configured for the running server —
// another seam this Playwright harness does not have. The scenario below is
// left `test.skip` for the same documented reason; do not un-skip it without
// adding both seams first.

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

  // See the file header: skipped until the harness can point `select_folder`
  // at a genuinely empty directory from outside the BEAM process.
  test.skip(
    "walks purpose through technical foundation, reviews the exact plan, and confirms it (Task 3)",
    async ({ page }) => {
      await page.goto("/onboarding/empty-repository");
      await page.getByRole("button", { name: /choose folder/i }).click();
      await page.getByRole("button", { name: /open folder picker/i }).click();

      const answers = [
        "A CLI tool",
        "Founders",
        "First working release",
        "None yet",
        "Elixir + Phoenix",
      ];

      for (const value of answers) {
        await page.locator("#answer-value").fill(value);
        await page.getByRole("button", { name: /continue/i }).click();
      }

      await expect(page.locator("[data-step=reviewing-plan]")).toBeVisible();
      await expect(page.locator("[data-structure-entry]")).toContainText("README.md");
      await expect(page.locator("[data-git-initial-branch]")).toContainText("main");

      await page.locator("[data-confirm-plan]").click();
      await expect(page.locator("[data-state=confirmed]")).toBeVisible();
    },
  );

  // See the file header: skipped for the same seam limitation as Task 3's
  // scenario above, plus the additional `:initialization_staging_root`
  // configuration the running server would need.
  test.skip(
    "starts the build from the confirmed plan and reaches the result step (Task 6)",
    async ({ page }) => {
      await page.goto("/onboarding/empty-repository");
      await page.getByRole("button", { name: /choose folder/i }).click();
      await page.getByRole("button", { name: /open folder picker/i }).click();

      const answers = [
        "A CLI tool",
        "Founders",
        "First working release",
        "None yet",
        "Elixir + Phoenix",
      ];

      for (const value of answers) {
        await page.locator("#answer-value").fill(value);
        await page.getByRole("button", { name: /continue/i }).click();
      }

      await page.locator("#kit-declined").click();
      await page.locator("[data-confirm-plan]").click();
      await page.locator("[data-start-build]").click();

      await expect(page.locator("[data-step=building-result]")).toBeVisible();
      await expect(page.locator("[data-commit-sha]")).not.toBeEmpty();
      await expect(page.locator("[data-readiness-assistant]")).toHaveAttribute(
        "data-readiness-assistant",
        "ready",
      );
      await expect(page.locator("[data-readiness-release]")).toHaveAttribute(
        "data-readiness-release",
        "blocked",
      );
    },
  );
});
