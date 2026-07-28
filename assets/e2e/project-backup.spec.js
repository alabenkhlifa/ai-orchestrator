const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

async function waitConnected(page) {
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 15000,
  });
}

// Creates the accountless project on the first run. Later desktop/mobile runs
// select the same canonical repository and follow the existing-project action.
async function openDeviceProject(page) {
  await page.goto("/onboarding/local");
  await waitConnected(page);

  const pairForm = page.locator("[data-pairing-form]");
  if (await pairForm.count()) {
    await page.locator("#pairing-code").fill("4K7Q-2P9X");
    await page.locator("[data-pair]").click();
  }

  // A reused dev database can contain only a stale stub worker. Pair a fresh
  // stand-in through the same LiveView event as the visible replacement form;
  // this is setup only and leaves the product backup path unchanged.
  if (await page.locator("[data-worker-status=unavailable]").count()) {
    await page.evaluate(() => {
      const liveRoot = document.querySelector("[data-phx-main]");
      const form = document.createElement("form");
      const input = document.createElement("input");
      form.setAttribute("phx-submit", "pair");
      input.name = "pairing[code]";
      input.value = "4K7Q-2P9X";
      form.appendChild(input);
      liveRoot.appendChild(form);
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      form.remove();
    });
  }

  await expect(page.locator("[data-worker-status=detected]")).toBeVisible();
  await page.locator("[data-continue]").click();
  await expect(page.locator("[data-select-folder]")).toBeVisible();
  await page.locator("[data-select-folder]").click();
  await expect(page.locator("[data-selected-repository]")).toBeVisible();
  await page.locator("[data-continue-storage]").click();

  await expect(page).toHaveURL(/\/onboarding\/local\/storage\//);
  await page.locator("#storage-device").click();
  await page.locator("button[phx-click=continue]").click();

  await expect(page.locator("[data-step=review]")).toBeVisible();
  const disclosure = page.locator("[data-confirm-disclosure]");
  if (await disclosure.count()) {
    await disclosure.click();
    await expect(page.locator("[data-create]")).toBeEnabled();
  }

  await page.locator("#project-name").fill("Portability browser proof");
  await page.locator("[data-create]").click();

  const duplicate = page.locator("[data-duplicate]");
  await Promise.race([
    page.waitForURL(/\/local\/projects\/[^/]+$/),
    duplicate.waitFor({ state: "visible" }),
  ]);

  if (await duplicate.isVisible().catch(() => false)) {
    await duplicate.getByRole("link", { name: /^Open / }).click();
  }

  await expect(page).toHaveURL(/\/local\/projects\/[^/]+$/);
  await expect(page.locator('[data-screen="device-project-dashboard"]')).toBeVisible();
}

test.describe("project backup", () => {
  test("creates and downloads an encrypted backup with responsive accessible controls", async ({
    page,
  }) => {
    await openDeviceProject(page);
    const dashboardURL = page.url();

    await page.locator("[data-backup-project]").click();
    await expect(page).toHaveURL(/\/local\/projects\/[^/]+\/backup$/);
    await expect(page.locator('[data-screen="project-backup"]')).toBeVisible();

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
    expect(Buffer.concat(chunks).length).toBeGreaterThan(100);
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
  });
});
