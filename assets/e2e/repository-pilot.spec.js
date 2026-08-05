const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  openLive,
  tabTo,
} = require("./support/harness");

// Focused browser proof for Slice 30 Task 4. The same scenario runs in the
// desktop and mobile Playwright projects. The owner adopts one current
// authoritative specification revision as the pilot; the screen commits a
// reference — identity, revision, digest, and the approved profile version —
// and never a specification document or a repository backlog item.
test.describe("repository pilot selection", () => {
  test("the owner selects one current authoritative specification revision", async ({ page }) => {
    const { project_id, specification_id, revision_id, revision_digest, profile_version } =
      await bootstrap(page, "repository_pilot");
    await openLive(page, `/projects/${project_id}/pilot`);

    const screen = page.locator("[data-screen=repository-pilot]");
    await expect(screen).toHaveAttribute("data-pilot-stage", "select");
    await expect(screen).toHaveAttribute("data-pilot-role", "owner");

    await expect(page.locator("[data-no-pilot]")).toBeVisible();
    await expect(page.locator("[data-read-only]")).toHaveCount(0);

    const option = page.locator(`[data-selectable-specification="${specification_id}"]`);
    await expect(option).toBeVisible();
    await expect(option).toContainText(revision_id);

    // A pilot references the specification; the screen shows no document body.
    await expect(page.locator("body")).not.toContainText("Adopt one bounded pilot feature");

    const viewport = page.viewportSize().width;
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );

    const ring = await tabTo(page, "[data-select-pilot]");
    expect(ring.style).not.toBe("none");
    expect(parseFloat(ring.width)).toBeGreaterThan(0);

    await page.locator("[data-select-pilot]").click();

    await expect(screen).toHaveAttribute("data-pilot-stage", "selected");
    await expect(page.locator("[data-pilot-message]")).toContainText(
      "Pilot set to this specification revision",
    );
    await expect(page.locator("[data-pilot-field=specification]")).toContainText(specification_id);
    await expect(page.locator("[data-pilot-field=revision]")).toContainText(revision_id);
    await expect(page.locator("[data-pilot-field=revision-digest]")).toContainText(revision_digest);
    await expect(page.locator("[data-pilot-field=profile-version]")).toContainText(
      String(profile_version),
    );
    await expect(page.locator("[data-no-pilot]")).toHaveCount(0);
    await expect(page.locator("[data-current-pilot]")).toBeVisible();
    await expect(page.locator("[data-select-pilot]")).toHaveCount(0);

    await expectNoSeriousAxeViolations(page);
  });
});
