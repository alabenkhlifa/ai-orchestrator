const { test, expect } = require("@playwright/test");
const { bootstrap, expectNoSeriousAxeViolations, waitConnected } = require("./support/harness");

// Coordinated first-release browser proof for AC-02, which
// `specs/01-github-project-onboarding/` and `specs/02-local-project-onboarding/`
// state identically: from the shared entry surface, either primary action must
// reach its specified onboarding path through completion, with no disabled,
// placeholder, or dead action.
//
// Both halves run against this server. The GitHub half uses the deterministic
// provider and the local stand-in for GitHub's authorization page, so the
// browser makes the real round trip — the product's own state and PKCE binding,
// code exchange, session rotation, and post-authentication routing all execute.
// Only GitHub itself is replaced. The live GitHub App smoke that proves the real
// integration stays a separate, tagged, staging-only test.
//
// The local half takes its own freshly created Git repository from the harness.
// A device repository may back only one project, so specs that complete local
// onboarding would otherwise compete for the single configured stub folder and
// the later ones would correctly meet "this repository is already connected".

async function openEntry(page) {
  await page.goto("/");
  await waitConnected(page).catch(() => {});
}

test.describe("first usable release entry", () => {
  test("offers exactly two live primary actions, neither disabled nor a placeholder", async ({
    page,
  }) => {
    await openEntry(page);

    const github = page.getByRole("link", { name: /Login with GitHub/i });
    const local = page.getByRole("link", { name: /Work without GitHub/i });

    for (const action of [github, local]) {
      await expect(action).toBeVisible();
      await expect(action).toBeEnabled();
      // A placeholder announces itself; a live action does not.
      await expect(action).not.toHaveAttribute("aria-disabled", "true");
      await expect(action).not.toContainText(/soon|not available|placeholder/i);
    }

    await expect(github).toHaveAttribute("href", "/auth/github");
    await expect(local).toHaveAttribute("href", "/onboarding/local");

    await expectNoSeriousAxeViolations(page);
  });

  test("the GitHub action completes onboarding and opens the new project", async ({ page }) => {
    await openEntry(page);
    await page.getByRole("link", { name: /Login with GitHub/i }).click();

    // Authorization returns to the product and lands the new account in
    // onboarding, because a brand-new workspace owns no projects yet.
    await page.waitForURL(/\/onboarding\/repository-access\//);
    await waitConnected(page);
    // Access was granted, so the check resolves straight to the repository picker
    // rather than the grant screen.
    await expect(page.locator('[data-screen="repository-access"]')).toHaveAttribute(
      "data-state",
      "picker",
    );

    // Pick one repository from the granted access and continue.
    await page.locator("#repository-101").click();
    await page.locator("button[phx-click=continue]").click();

    // The shared storage step: hosted is available to a signed-in account.
    await page.waitForURL(/\/onboarding\/storage\//);
    await waitConnected(page);
    await expect(page.locator("#storage-hosted")).not.toHaveAttribute("aria-disabled", "true");
    await page.locator("#storage-hosted").click();
    await page.locator("button[phx-click=continue]").click();

    // Confirmation, then the project's own address.
    await page.waitForURL(/\/onboarding\/confirm\//);
    await waitConnected(page);
    await page.locator("#project-confirmation-form button[type=submit]").click();

    await page.waitForURL(/\/projects\/[0-9a-f-]{36}/);

    // The dashboard states the repository, storage mode, and connection status.
    const projectPath = new URL(page.url()).pathname.split("/").slice(0, 3).join("/");
    await page.goto(`${projectPath}/overview`);
    await expect(page.locator('[data-screen="project-dashboard"]')).toBeVisible();
    await expect(page.locator('[data-screen="project-dashboard"]')).toContainText("example");
    await expect(page.locator('[data-screen="project-dashboard"]')).toContainText(
      "In my SDD Orchestrator account",
    );
    await expect(page.locator('[data-screen="project-dashboard"]')).toContainText("Connected");
  });

  test("the local action completes onboarding and opens the new project", async ({ page }) => {
    await bootstrap(page, "local_repository");

    await openEntry(page);
    await page.getByRole("link", { name: /Work without GitHub/i }).click();

    await page.waitForURL(/\/onboarding\/local$/);
    await waitConnected(page);

    // Worker discovery through the pairing stand-in.
    const pairForm = page.locator("[data-pairing-form]");
    if (await pairForm.count()) {
      await page.locator("#pairing-code").fill("4K7Q-2P9X");
      await page.locator("[data-pair]").click();
    }
    await expect(page.locator("[data-worker-status=detected]")).toBeVisible();

    // Native repository selection.
    await page.locator("[data-continue]").click();
    await page.locator("[data-select-folder]").click();
    await expect(page.locator("[data-selected-repository]")).toBeVisible();

    // The shared storage step: on-device is available through the worker.
    await page.locator("[data-continue-storage]").click();
    await page.waitForURL(/\/onboarding\/local\/storage\//);
    await waitConnected(page);
    await page.locator("#storage-device").click();
    await page.locator("button[phx-click=continue]").click();

    // Review, first-connection disclosure, then creation.
    await page.waitForURL(/\/onboarding\/local/);
    await waitConnected(page);
    await expect(page.locator("[data-step=review]")).toBeVisible();

    // The accountless disclosure is required on this device's first connection
    // and stays reachable, without re-prompting, on every later one. Which case
    // this run is depends on whether an earlier spec already connected a
    // repository on this device, so both are asserted for what they promise:
    // a first connection genuinely gates creation, and a later one still offers
    // the disclosure rather than dropping it.
    const confirm = page.locator("[data-confirm-disclosure]");

    if (await confirm.count()) {
      await expect(page.locator("[data-create]")).toBeDisabled();
      await confirm.click();
    } else {
      await expect(page.locator("[data-disclosure-summary]")).toBeVisible();
    }

    await expect(page.locator("[data-create]")).toBeEnabled();

    await page.locator("#project-name").fill("Release Entry Local");
    await page.locator("[data-create]").click();

    await page.waitForURL(/\/local\/projects\/[0-9a-f-]{36}/);
    await expect(page.getByText("Release Entry Local")).toBeVisible();
  });
});
