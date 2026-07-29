const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

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

async function pairStubWorker(page) {
  await page.evaluate(() => {
    document.querySelector("[data-e2e-pair-form]")?.remove();

    const liveRoot = document.querySelector("[data-phx-main]");
    const form = document.createElement("form");
    const input = document.createElement("input");
    form.dataset.e2ePairForm = "";
    form.setAttribute("phx-submit", "pair");
    input.name = "pairing[code]";
    input.value = "4K7Q-2P9X";
    form.appendChild(input);
    liveRoot.appendChild(form);
    form.requestSubmit();
  });
}

async function ensurePortableBackupReady(page) {
  const upgrade = page.locator("[data-upgrade-repository-identity]");

  if (await upgrade.isVisible().catch(() => false)) {
    await upgrade.click();
    await waitConnected(page);
    await expect(page.locator("[data-step=selection][data-locate=true]")).toBeVisible();
    await page.locator("[data-select-folder]").click();
    await expect(page).toHaveURL(/\/local\/projects\/[^/]+$/);
    await expect(page.locator('[data-screen="device-project-dashboard"]')).toBeVisible();
  }

  await expect(page.locator("[data-backup-readiness=backup_ready]")).toBeVisible();
}

// Creates the accountless project on the first run. Later desktop/mobile runs
// select the same canonical repository and follow the existing-project action.
async function openDeviceProject(page) {
  await page.goto("/onboarding/local");
  await waitConnected(page);

  const pairForm = page.locator("[data-pairing-form]");
  const detectedWorker = page.locator("[data-worker-status=detected]");

  if (await pairForm.isVisible().catch(() => false)) {
    await page.locator("#pairing-code").fill("4K7Q-2P9X");
    await page.locator("[data-pair]").click();
  } else if (!(await detectedWorker.isVisible().catch(() => false))) {
    // A reused dev database can contain only a stale stub worker. Pair a fresh
    // stand-in through the same LiveView event as the visible replacement form;
    // this is setup only and leaves the product backup path unchanged.
    await pairStubWorker(page);
  }

  await expect(detectedWorker).toBeVisible({ timeout: 15000 });
  await page.locator("[data-continue]").click();
  await expect(page.locator("[data-select-folder]")).toBeVisible();
  const duplicate = page.locator("[data-duplicate]");
  const selectedRepository = page.locator("[data-selected-repository]");
  await page.locator("[data-select-folder]").click();
  await Promise.race([
    selectedRepository.waitFor({ state: "visible" }),
    duplicate.waitFor({ state: "visible" }),
  ]);

  if (await duplicate.isVisible().catch(() => false)) {
    await duplicate.getByRole("link", { name: /^Open / }).click();
    await expect(page).toHaveURL(/\/local\/projects\/[^/]+$/);
    await expect(page.locator('[data-screen="device-project-dashboard"]')).toBeVisible();
    await ensurePortableBackupReady(page);
    return;
  }

  await page.locator("[data-continue-storage]").click();

  await expect(page).toHaveURL(/\/onboarding\/local\/storage\//);
  await waitConnected(page);
  const deviceStorage = page.locator("#storage-device");
  const continueStorage = page.locator("button[phx-click=continue]");
  await deviceStorage.click();
  await expect(deviceStorage).toHaveAttribute("aria-checked", "true");
  await expect(continueStorage).toBeEnabled();
  await continueStorage.click();

  await expect(page.locator("[data-step=review]")).toBeVisible();
  const projectName = page.locator("#project-name");
  await projectName.fill("Portability browser proof");
  await projectName.blur();
  await expect(projectName).toHaveValue("Portability browser proof");
  const disclosure = page.locator("[data-confirm-disclosure]");
  if (await disclosure.count()) {
    await disclosure.check();
    await expect(disclosure).toBeChecked();
    await expect(page.locator("[data-create]")).toBeEnabled();
  }

  await page.locator("[data-create]").click();

  await Promise.race([
    page.waitForURL(/\/local\/projects\/[^/]+$/),
    duplicate.waitFor({ state: "visible" }),
  ]);

  if (await duplicate.isVisible().catch(() => false)) {
    await duplicate.getByRole("link", { name: /^Open / }).click();
  }

  await expect(page).toHaveURL(/\/local\/projects\/[^/]+$/);
  await expect(page.locator('[data-screen="device-project-dashboard"]')).toBeVisible();
  await ensurePortableBackupReady(page);
}

test.describe("project backup", () => {
  test("creates and downloads an encrypted backup with responsive accessible controls", async ({
    page,
  }) => {
    test.setTimeout(90000);
    await openDeviceProject(page);
    const dashboardURL = page.url();

    await expect(page.locator("[data-backup-readiness=backup_ready]")).toBeVisible();
    await page.locator("[data-backup-project]").click();
    await expect(page).toHaveURL(/\/local\/projects\/[^/]+\/backup$/);
    await expect(page.locator('[data-screen="project-backup"]')).toBeVisible();
    await expect(page.locator("[data-backup-readiness=ready]")).toBeVisible();

    const included = page.locator("[data-included-categories]");
    await expect(included).toContainText("Project identity and display name");
    await expect(included).toContainText("Canonical repository identity");
    await expect(included).toContainText("Current specifications");

    const excluded = page.locator("[data-excluded-categories]");
    await expect(excluded).toContainText("History");
    await expect(excluded).toContainText("agent runs");
    await expect(excluded).toContainText("generated artifacts");
    await expect(excluded).toContainText("comments");
    await expect(excluded).toContainText("attachments");
    await expect(excluded).toContainText("logs");
    await expect(excluded).toContainText("repository source");

    const body = await page.locator("body").innerText();
    expect(body).not.toMatch(/share this backup/i);
    expect(body).not.toMatch(/create a copy/i);

    const passphrase = page.locator("#backup-passphrase");
    const confirmation = page.locator("#backup-passphrase-confirmation");
    const acknowledgement = page.locator("[data-loss-acknowledgement] input");

    await passphrase.focus();
    await page.keyboard.press("Tab");
    await expect(confirmation).toBeFocused();

    await passphrase.fill("browser recovery phrase");
    await confirmation.fill("browser recovery phrase");
    expect(await acknowledgement.evaluate((element) => element.checkValidity())).toBe(false);

    await acknowledgement.check();
    await confirmation.fill("different phrase");
    await page.locator("[data-create-backup]").click();
    await expect(page.locator("#backup-form-error")).toBeFocused();
    await expect(page.locator("#backup-form-error")).toContainText(
      "The recovery passphrases don't match.",
    );

    // The server deliberately clears password controls after validation.
    await passphrase.fill("browser recovery phrase");
    await confirmation.fill("browser recovery phrase");
    await acknowledgement.check();

    const downloadPromise = page.waitForEvent("download");
    await page.locator("[data-create-backup]").click();
    const download = await downloadPromise;

    expect(download.suggestedFilename()).toMatch(/^sdd-project-.*\.sddbackup$/);
    const stream = await download.createReadStream();
    const chunks = [];
    for await (const chunk of stream) chunks.push(chunk);
    const encryptedBackup = Buffer.concat(chunks);
    expect(encryptedBackup.length).toBeGreaterThan(100);
    await expect(page.getByText("Your encrypted backup was downloaded.")).toBeVisible();

    const results = await new AxeBuilder({ page })
      .include('[data-screen="project-backup"]')
      .analyze();
    expect(results.violations).toEqual([]);

    const primary = page.locator("[data-create-backup]");
    if (page.viewportSize().width < 640) {
      const formWidth = await page.locator("#project-backup-form").evaluate((el) => el.clientWidth);
      const buttonWidth = await primary.evaluate((el) => el.getBoundingClientRect().width);
      expect(buttonWidth).toBeGreaterThan(formWidth * 0.9);
    }

    await page.locator("main [data-cancel-backup]").click();
    await expect(page).toHaveURL(dashboardURL);

    await page.goto("/restore");
    await waitConnected(page);
    await expect(page.locator('[data-screen="project-restore"]')).toBeVisible();
    await expect(page.locator("#restore-hosted")).toBeDisabled();
    await expect(page.locator("[data-setup-hosted]")).toBeVisible();

    const deviceDestination = page.locator("#restore-device");
    await deviceDestination.focus();
    await expect(deviceDestination).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(deviceDestination).toHaveAttribute("aria-checked", "true");

    await page.locator("[data-package-input]").setInputFiles({
      name: download.suggestedFilename(),
      mimeType: "application/vnd.sdd-orchestrator.project-backup",
      buffer: encryptedBackup,
    });
    await page.locator("#restore-passphrase").fill("browser recovery phrase");
    await page.locator("[data-validate-package]").click();
    await expect(page.locator("[data-validation-compatible]")).toBeVisible();
    await expect(page.locator("[data-validation-compatible]")).toContainText(
      "No project has been created yet.",
    );

    const confirmPassphrase = page.locator("#restore-confirm-passphrase");
    await confirmPassphrase.focus();
    await expect(confirmPassphrase).toBeFocused();
    await confirmPassphrase.fill("browser recovery phrase");
    await page.locator("[data-restore-project]").click();

    const conflict = page.locator(
      "[data-restore-blocked][data-conflict-type=same_identity]",
    );
    await expect(conflict).toBeVisible();
    await expect(page.locator("#restore-conflict")).toBeFocused();
    await expect(conflict).toContainText("This project already exists");
    await expect(conflict).toContainText(
      "can't be overwritten, merged, updated, or renamed",
    );

    const restoreBody = await page.locator("body").innerText();
    expect(restoreBody).not.toMatch(/share (this|the) (project|backup)/i);
    expect(restoreBody).not.toMatch(/create a copy/i);
    expect(restoreBody).not.toMatch(/choose a different repository/i);
    expect(restoreBody).not.toMatch(/relink/i);

    const restoreA11y = await new AxeBuilder({ page })
      .include('[data-screen="project-restore"]')
      .analyze();
    expect(restoreA11y.violations).toEqual([]);

    if (page.viewportSize().width < 640) {
      const restoreScreenWidth = await page
        .locator('[data-screen="project-restore"]')
        .evaluate((el) => el.clientWidth);
      const chooseAnotherWidth = await page
        .locator("[data-choose-another-package]")
        .evaluate((el) => el.getBoundingClientRect().width);
      expect(chooseAnotherWidth).toBeGreaterThan(restoreScreenWidth * 0.9);
    }

    await page.locator("main [data-cancel-restore]").click();
    await expect(page).toHaveURL(/\/onboarding\/local$/);
  });
});
