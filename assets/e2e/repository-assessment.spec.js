const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  openLive,
  tabTo,
} = require("./support/harness");

// Focused browser proof for Slice 14 Task 1. The same scenario runs in the
// desktop and mobile Playwright projects. Its deterministic worker adapter can
// prepare and revalidate metadata only; it exposes no scan command.
test.describe("repository assessment start", () => {
  test("the owner confirms disclosure, reviews one exact binding, and starts separately", async ({
    page,
  }) => {
    const { project_id, worker_id, commit } = await bootstrap(page, "repository_assessment");
    await openLive(page, `/projects/${project_id}/assessment`);

    const screen = page.locator("[data-screen=repository-assessment]");
    await expect(screen).toHaveAttribute("data-assessment-stage", "disclosure");
    await expect(page.locator("[data-disclosure-field]")).toHaveCount(8);
    await expect(page.locator("[data-disclosure-field=surfaces]")).toContainText(
      "Agent instructions",
    );
    await expect(page.locator("[data-disclosure-field=local]")).toContainText(
      "Raw source",
    );
    await expect(page.locator("[data-disclosure-field=transfer]")).toContainText(
      "No whole-repository source",
    );
    await expect(page.locator("[data-disclosure-field=processors]")).toContainText(
      "configured model",
    );
    await expect(page.locator("[data-disclosure-field=retention]")).toContainText(
      "short-lived and single-use",
    );
    await expect(page.locator("[data-disclosure-field=purpose]")).toContainText(
      "managed SDD pilot",
    );
    await expect(page.locator("[data-disclosure-field=limits]")).toContainText(
      "file-count, byte, path, and elapsed-time caps",
    );
    await expect(page.locator("[data-disclosure-field=explicit-limits]")).toContainText(
      "does not scan or modify",
    );

    await expect(page.locator("[data-verified-binding]")).toHaveCount(0);
    await expect(page.locator("[data-assessment-pending]")).toHaveCount(0);
    await expect(page.locator("[data-before-confirmation]")).toContainText(
      "No repository metadata call or scan command",
    );

    const viewport = page.viewportSize().width;
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );

    const formBox = await page.locator("[data-binding-form]").boundingBox();
    expect(formBox.width).toBeLessThanOrEqual(viewport);

    const ring = await tabTo(page, "[data-confirm-boundary]");
    expect(ring.style).not.toBe("none");
    expect(parseFloat(ring.width)).toBeGreaterThan(0);

    await page.locator("#assessment-root").fill(".");
    await page.locator("#assessment-worker").selectOption(worker_id);
    await page.locator("#assessment-confirmed").check();
    await page.locator("[data-confirm-boundary]").click();

    await expect(screen).toHaveAttribute("data-assessment-stage", "binding");
    await expect(page.locator("[data-verified-binding]")).toBeVisible();
    await expect(page.locator("[data-binding-field=root]")).toContainText(".");
    await expect(page.locator("[data-binding-field=commit]")).toContainText(commit);
    await expect(page.locator("[data-assessment-pending]")).toHaveCount(0);

    await page.locator("[data-start-assessment]").click();

    await expect(screen).toHaveAttribute("data-assessment-stage", "pending");
    await expect(page.locator("[data-assessment-pending]")).toBeVisible();
    await expect(page.locator("[data-assessment-state]")).toHaveText("Pending scan");
    await expect(page.locator("[data-verified-binding]")).toHaveCount(0);
    await expectNoSeriousAxeViolations(page);
  });
});
