const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  openLive,
  tabTo,
  waitConnected,
} = require("./support/harness");

// Browser proof for project-scoped navigation and the board-as-default landing
// (specs/07 Task 53, AC-48). Runs under both the desktop and the mobile
// Playwright projects.
test.describe("project navigation", () => {
  test("a configured project opens on its board", async ({ page }) => {
    const { project_id } = await bootstrap(page, "features");

    await page.goto(`/projects/${project_id}`);
    await waitConnected(page);

    await expect(page).toHaveURL(new RegExp(`/projects/${project_id}/features$`));
    await expect(page.locator("[data-screen=feature-board]")).toBeVisible();
    await expect(page.locator("[data-project-nav]")).toBeVisible();
    await expect(page.locator("[data-nav-current]")).toHaveAttribute(
      "data-nav-destination",
      "features",
    );
  });

  test("a project that is not configured yet opens on its overview", async ({ page }) => {
    const { project_id } = await bootstrap(page, "project_owner", { owner_profile: "false" });

    await page.goto(`/projects/${project_id}`);
    await waitConnected(page);

    await expect(page).toHaveURL(new RegExp(`/projects/${project_id}/overview$`));
    await expect(page.locator("[data-screen=project-dashboard]")).toBeVisible();
    await expect(page.locator("[data-project-nav]")).toBeVisible();
    await expect(page.locator("[data-nav-current]")).toHaveAttribute(
      "data-nav-destination",
      "overview",
    );
  });

  test("the navigation moves between the overview and the board without typing", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "features");
    await openLive(page, `/projects/${project_id}/overview`);

    await expect(page.locator("[data-screen=project-dashboard]")).toBeVisible();

    await page.locator("[data-nav-destination=features]").click();
    await waitConnected(page);

    await expect(page).toHaveURL(new RegExp(`/projects/${project_id}/features$`));
    await expect(page.locator("[data-screen=feature-board]")).toBeVisible();
    await expect(page.locator("[data-nav-destination=features]")).toHaveAttribute(
      "aria-current",
      "page",
    );
    await expect(page.locator("[data-nav-destination=overview]")).not.toHaveAttribute(
      "data-nav-current",
      /.*/,
    );

    await page.locator("[data-nav-destination=overview]").click();
    await waitConnected(page);

    await expect(page).toHaveURL(new RegExp(`/projects/${project_id}/overview$`));
    await expect(page.locator("[data-screen=project-dashboard]")).toBeVisible();
    await expect(page.locator("[data-nav-destination=overview]")).toHaveAttribute(
      "aria-current",
      "page",
    );
  });

  test("a participant is offered no destination they cannot open", async ({ page }) => {
    const { project_id } = await bootstrap(page, "features", { as: "participant" });
    await openLive(page, `/projects/${project_id}/features`);

    await expect(page.locator("[data-project-nav]")).toBeVisible();
    await expect(page.locator("[data-nav-destination=overview]")).toHaveCount(0);
    await expect(page.locator("[data-nav-destination=features]")).toBeVisible();
    await expect(page.locator("[data-nav-destination=people]")).toBeVisible();
  });

  test("a navigation link is reachable by keyboard with a ring that actually paints", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "features");
    await openLive(page, `/projects/${project_id}/features`);

    const ring = await tabTo(page, "[data-nav-destination=people]");

    // The computed values, not the class list: a Tailwind v4 outline utility can
    // name a 2px ring that resolves to `outline-style: none` and never paints.
    expect(ring.style).not.toBe("none");
    expect(ring.width).toBe("2px");
    expect(parseFloat(ring.width)).toBeGreaterThan(0);
    expect(ring.color).not.toBe("");
    expect(ring.color).not.toBe("rgba(0, 0, 0, 0)");
  });

  test("the destinations stay on one row inside the viewport", async ({ page }) => {
    const { project_id } = await bootstrap(page, "features");
    await openLive(page, `/projects/${project_id}/features`);

    const viewport = page.viewportSize().width;
    const nav = await page.locator("[data-project-nav]").boundingBox();

    expect(nav.width).toBeLessThanOrEqual(viewport);

    // One row: every destination shares the navigation's own height, so no
    // label has wrapped onto a second line.
    const heights = await page
      .locator("[data-nav-destination]")
      .evaluateAll((links) => links.map((link) => link.getBoundingClientRect().height));

    expect(heights.length).toBe(3);
    for (const height of heights) {
      expect(height).toBeLessThanOrEqual(nav.height + 1);
    }

    const tops = await page
      .locator("[data-nav-destination]")
      .evaluateAll((links) => links.map((link) => Math.round(link.getBoundingClientRect().top)));

    expect(new Set(tops).size).toBe(1);

    // The page itself never scrolls sideways to fit them.
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );
  });

  test("project navigation has no serious accessibility violations", async ({ page }) => {
    const { project_id } = await bootstrap(page, "features");
    await openLive(page, `/projects/${project_id}/features`);

    await expect(page.locator("nav[aria-label=Project]")).toBeVisible();
    await expectNoSeriousAxeViolations(page);
  });
});
