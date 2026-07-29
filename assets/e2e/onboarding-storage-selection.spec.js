const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

// Browser proof for the shared storage-selection step reached through the
// accountless local flow (specs/05 Task 3). The behavioural contract — approved
// copy, identity-gated hosted availability, the sign-in and device-setup return
// handoffs, and no implicit selection — is proven deterministically at the
// LiveView level, where scope and state are isolated per test. This browser
// scenario asserts that the local flow actually reaches the shared step and that
// it renders the approved, source-neutral surface accessibly.

// Waits until the LiveView socket is connected so phx-click events are handled.
async function waitConnected(page) {
  await page
    .waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
      timeout: 15000,
    })
    .catch(() => {});
}

// Drives the accountless local flow to the shared storage step: pair the stubbed
// worker if it is not already detected, choose the repository (the stub folder is
// a real Git repo), and continue into the storage step.
async function reachStorageStep(page) {
  await page.goto("/onboarding/local");
  await waitConnected(page);

  const pairForm = page.locator("[data-pairing-form]");
  if (await pairForm.count()) {
    await page.locator("#pairing-code").fill("4K7Q-2P9X");
    await page.locator("[data-pair]").click();
  }
  await expect(page.locator("[data-worker-status=detected]")).toBeVisible();

  await page.locator("[data-continue]").click(); // choose repository
  await expect(page.locator("[data-select-folder]")).toBeVisible();
  await page.locator("[data-select-folder]").click(); // open folder picker (stub)
  await expect(page.locator("[data-selected-repository]")).toBeVisible();
  await page.locator("[data-continue-storage]").click(); // hand off to storage step

  await expect(page).toHaveURL(/\/onboarding\/local\/storage\//);
  await expect(page.locator('[data-screen="storage-selection"]')).toBeVisible();
}

test.describe("storage selection (accountless)", () => {
  test("the local flow reaches the shared storage step and renders it accessibly", async ({
    page,
  }) => {
    await reachStorageStep(page);

    await expect(
      page.getByRole("heading", { name: /Where should your project work be saved\?/ }),
    ).toBeVisible();

    // Approved, source-neutral explanation copy (never names GitHub).
    await expect(
      page.getByText(
        "Your project work includes specifications, tasks, agent runs, and generated files. Your linked repository stays where it is.",
      ),
    ).toBeVisible();
    const body = await page.locator("body").innerText();
    expect(body).not.toContain("on GitHub");

    // Both modes are visible with their approved labels.
    await expect(page.locator("#storage-hosted")).toContainText("In my SDD Orchestrator account");
    await expect(page.locator("#storage-device")).toContainText("On this device");

    // Accountless: hosted is unavailable with a non-selecting sign-in action,
    // while on-device is ready through the worker readiness receipt.
    await expect(page.locator("#storage-hosted")).toHaveAttribute("aria-disabled", "true");
    await expect(page.locator("button[phx-click=setup_hosted]")).toBeVisible();
    await expect(page.locator("#storage-device")).not.toHaveAttribute("aria-disabled", "true");

    // No mode is selected by default (no silent default) and continue is blocked.
    await expect(page.locator("#storage-hosted")).not.toHaveAttribute("aria-checked", "true");
    await expect(page.locator("#storage-device")).not.toHaveAttribute("aria-checked", "true");
    await expect(page.locator("button[phx-click=continue]")).toBeDisabled();

    // The step is accessible.
    const results = await new AxeBuilder({ page })
      .include('[data-screen="storage-selection"]')
      .analyze();

    expect(results.violations).toEqual([]);
  });
});
