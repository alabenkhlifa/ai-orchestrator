const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  openLive,
  tabTo,
} = require("./support/harness");

// Focused browser proof for Slice 14 Task 11. The same scenario runs in the
// desktop and mobile Playwright projects. Everything the owner reads is derived
// from the seeded completed assessment and its stored proposal envelope; the
// screen offers no field the reviewer could replace before approving.
test.describe("repository execution profile review", () => {
  test("the owner reviews every assessment-bound field and approves one immutable version", async ({
    page,
  }) => {
    const { project_id, commit, command, gap, conflict } = await bootstrap(
      page,
      "repository_execution_profile",
    );
    await openLive(page, `/projects/${project_id}/profile`);

    const screen = page.locator("[data-screen=repository-execution-profile]");
    await expect(screen).toHaveAttribute("data-profile-stage", "review");
    await expect(screen).toHaveAttribute("data-profile-role", "owner");

    const boundary = page.locator("[data-managed-runtime-only]");
    await expect(boundary).toContainText("Orchestrator-managed runs only");
    await expect(boundary).toContainText(
      "changes no repository file, instruction, CI rule, or branch policy",
    );
    await expect(boundary).toContainText("Existing repository instructions stay authoritative");

    await expect(page.locator("[data-assessment-summary]")).toBeVisible();
    await expect(page.locator("[data-profile-field=repository]")).toContainText("octo/example");
    await expect(page.locator("[data-profile-field=root]")).toContainText(".");
    await expect(page.locator("[data-profile-field=base-revision]")).toContainText(commit);
    await expect(page.locator("[data-profile-field=cache-source]")).toContainText(
      "Freshly scanned",
    );
    await expect(page.locator("[data-profile-field=cache-stored]")).toContainText("Yes");
    await expect(page.locator("[data-profile-field=cache-key-digest]")).toContainText(
      /[0-9a-f]{64}/,
    );
    await expect(page.locator("[data-profile-field=evidence-digest]")).toContainText(
      /[0-9a-f]{64}/,
    );

    await expect(page.locator("[data-instruction-precedence]")).toContainText(
      "remain authoritative",
    );
    await expect(page.locator("[data-precedence-empty]")).toBeVisible();

    await expect(page.locator("[data-proposal-field]")).toHaveCount(6);
    await expect(page.locator("[data-proposal-field=commands]")).toContainText(command);
    await expect(page.locator("[data-proposal-field=required-checks]")).toContainText(command);
    await expect(page.locator("[data-proposal-field=allowed-scope]")).toContainText("lib");
    await expect(page.locator("[data-proposal-field=gaps]")).toContainText(gap);
    await expect(page.locator("[data-proposal-field=conflicts]")).toContainText(conflict);
    await expect(
      page.locator("[data-proposal-field=multi-root-blockers] [data-proposal-empty]"),
    ).toBeVisible();

    await expect(page.locator("[data-no-profile-versions]")).toBeVisible();
    await expect(page.locator("[data-read-only]")).toHaveCount(0);

    const viewport = page.viewportSize().width;
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );

    const ring = await tabTo(page, "[data-approve-profile]");
    expect(ring.style).not.toBe("none");
    expect(parseFloat(ring.width)).toBeGreaterThan(0);

    await page.locator("[data-approve-profile]").click();

    await expect(screen).toHaveAttribute("data-profile-stage", "decided");
    await expect(page.locator('[data-profile-version="1"]')).toBeVisible();
    await expect(page.locator("[data-profile-message]")).toContainText(
      "Approved profile version 1",
    );
    await expect(page.locator("[data-approve-profile]")).toHaveCount(0);
    await expect(page.locator("[data-reject-profile]")).toHaveCount(0);
    await expectNoSeriousAxeViolations(page);
  });
});
