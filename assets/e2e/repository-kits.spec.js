const { test, expect } = require("@playwright/test");
const { bootstrap, expectNoSeriousAxeViolations, openLive } = require("./support/harness");

// Focused browser proof for Slice 15 Task 1. The same scenario runs in the
// desktop and mobile Playwright projects. The seeded catalog is global (no
// project), read-only, and includes one superseded pair so both the detail
// panel and the derived supersession badge are provable in a real browser.
// This spec is intentionally read-only-safe: it asserts inspection only, and
// depends on no later task's application or diff logic.
test.describe("repository SDD kit catalog", () => {
  test("the owner inspects the catalog, opens one package, and sees supersession", async ({
    page,
  }) => {
    const { older_id, older_version, newer_id, newer_version } = await bootstrap(
      page,
      "repository_kits",
    );
    await openLive(page, "/repository-kits");

    const screen = page.locator("[data-screen=repository-kits]");
    await expect(screen).toBeVisible();
    await expect(page.locator("[data-empty-state]")).toHaveCount(0);

    const olderRow = page.locator(`[data-package-row][data-package-id="${older_id}"]`);
    const newerRow = page.locator(`[data-package-row][data-package-id="${newer_id}"]`);
    await expect(olderRow).toBeVisible();
    await expect(newerRow).toBeVisible();

    await expect(olderRow.locator("[data-superseded]")).toContainText(`v${newer_version}`);
    await expect(newerRow.locator("[data-superseded]")).toHaveCount(0);

    const viewport = page.viewportSize().width;
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );

    await olderRow.locator("button").click();

    const detail = page.locator("[data-package-detail]");
    await expect(detail).toBeVisible();
    await expect(detail.locator("[data-detail=source]")).toContainText("octo/sdd-kit");
    await expect(detail.locator("[data-detail=publisher]")).toContainText("octo");
    await expect(detail.locator("[data-detail=version]")).toContainText(older_version);
    await expect(detail.locator("[data-detail=license]")).toContainText("MIT");
    await expect(detail.locator("[data-provenance=ref_type]")).toContainText("commit");
    await expect(detail.locator("[data-provenance=repository]")).toContainText("octo/sdd-kit");
    await expect(detail.locator("[data-detail=supported_adapters]")).toContainText(
      "claude_code",
    );
    await expect(detail.locator("[data-detail=scripts]")).toContainText("scripts/check.sh");
    await expect(
      detail.locator('[data-manifest-file][data-path="scripts/check.sh"] [data-executable]'),
    ).toBeVisible();

    const detailBox = await detail.boundingBox();
    expect(detailBox.width).toBeLessThanOrEqual(viewport);

    await expectNoSeriousAxeViolations(page);
  });
});
