const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  fillDebounced,
  openLive,
  tabTo,
} = require("./support/harness");

const COLUMNS = [
  ["draft", "Draft"],
  ["ready_for_development", "Ready for development"],
  ["in_development", "In development"],
  ["ready_for_review", "Ready for review"],
  ["done", "Done"],
];

// Authenticated browser proof for the feature board and detail screens
// (specs/07 Task 2).
test.describe("feature delivery", () => {
  test("an empty board still shows all five lifecycle columns", async ({ page }) => {
    const { project_id } = await bootstrap(page, "features");
    await openLive(page, `/projects/${project_id}/features`);

    await expect(page.locator("[data-screen=feature-board]")).toBeVisible();
    await expect(page.locator("[data-column]")).toHaveCount(5);

    for (const [column, label] of COLUMNS) {
      const section = page.locator(`[data-column="${column}"]`);
      await expect(section).toBeVisible();
      await expect(section.locator("[data-column-label]")).toHaveText(label);
      await expect(section.locator("[data-column-empty]")).toBeVisible();
    }

    await expect(page.locator("[data-feature]")).toHaveCount(0);
  });

  test("a populated board places each feature in its own column", async ({ page }) => {
    const { project_id, features, owner_name } = await bootstrap(page, "features", {
      populated: "true",
    });
    await openLive(page, `/projects/${project_id}/features`);

    await expect(page.locator("[data-feature]")).toHaveCount(5);

    for (const [column, label] of COLUMNS) {
      const section = page.locator(`[data-column="${column}"]`);
      await expect(section.locator("[data-column-label]")).toHaveText(label);
      await expect(section.locator("[data-column-empty]")).toHaveCount(0);
      await expect(section.locator("[data-feature]")).toHaveCount(1);
      await expect(section.locator("[data-feature]")).toHaveAttribute(
        "data-feature-id",
        features[column],
      );
      await expect(section.locator("[data-feature-creator]")).toHaveText(owner_name);
    }

    // A visible status is shown on the card without moving it out of its column.
    const blocked = page.locator('[data-column="in_development"] [data-feature]');
    await expect(blocked).toHaveAttribute("data-feature-status", "blocked");
    await expect(blocked.locator("[data-feature-status-label]")).toHaveText("Blocked");
    await expect(page.locator('[data-column="done"] [data-feature-status-label]')).toHaveCount(0);
  });

  test("cards offer no drag affordance", async ({ page }) => {
    const { project_id } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features`);

    await expect(page.locator("[data-board]")).toHaveAttribute("data-drag-enabled", "false");

    const draggable = await page.locator("[data-feature]").evaluateAll((cards) =>
      cards.map((card) => ({
        draggable: card.draggable,
        attribute: card.getAttribute("draggable"),
        handle: !!card.querySelector("[data-drag-handle]"),
      })),
    );

    expect(draggable).toHaveLength(5);
    for (const card of draggable) {
      expect(card.draggable).toBe(false);
      expect(card.attribute).toBeNull();
      expect(card.handle).toBe(false);
    }
  });

  test("a card opens its feature detail, which offers no direct column choice", async ({
    page,
  }) => {
    const { project_id, features, owner_name } = await bootstrap(page, "features", {
      populated: "true",
    });
    await openLive(page, `/projects/${project_id}/features`);

    const card = page.locator('[data-column="ready_for_review"] [data-feature]');
    const title = await card.locator("[data-feature-title]").textContent();

    await card.locator("[data-feature-title]").click();

    await expect(page).toHaveURL(new RegExp(`/features/${features.ready_for_review}$`));
    await expect(page.locator("[data-screen=feature-detail]")).toBeVisible();
    await expect(page.locator("[data-feature-title]")).toHaveText(title.trim());
    await expect(page.locator("[data-feature-column]")).toHaveText("Ready for review");
    await expect(page.locator("[data-feature-creator]")).toHaveText(owner_name);
    await expect(page.locator("[data-feature-assignee]")).toHaveText("Nobody yet");

    // The next step is described as one gated action, never as a column picker.
    await expect(page.locator("[data-gated-action]")).toBeVisible();
    await expect(page.locator("[data-gated-action]")).toContainText(/Review the result/i);
    await expect(page.locator("select")).toHaveCount(0);

    await page.getByRole("link", { name: /Features/ }).first().click();
    await expect(page.locator("[data-screen=feature-board]")).toBeVisible();
  });

  test("a new feature is added to Draft from the board", async ({ page }) => {
    const { project_id, owner_name } = await bootstrap(page, "features");
    await openLive(page, `/projects/${project_id}/features`);

    await fillDebounced(page, "#feature-title", "Search the catalog");
    await page.locator("[data-add-feature]").click();

    const draft = page.locator('[data-column="draft"] [data-feature]');

    await expect(draft).toHaveCount(1);
    await expect(draft.locator("[data-feature-title]")).toHaveText("Search the catalog");
    await expect(draft.locator("[data-feature-creator]")).toHaveText(owner_name);
    await expect(page.locator('[data-column="done"] [data-column-empty]')).toBeVisible();
  });

  test("the board is reachable by keyboard with a visible focus ring", async ({ page }) => {
    const { project_id } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features`);

    await page.locator("#feature-title").focus();
    const addRing = await tabTo(page, "[data-add-feature]");
    expect(addRing.style).not.toBe("none");

    const cardLink = '[data-column="draft"] [data-feature] [data-feature-title]';
    const cardRing = await tabTo(page, cardLink);
    expect(cardRing.style).not.toBe("none");

    await page.keyboard.press("Enter");
    await expect(page.locator("[data-screen=feature-detail]")).toBeVisible();
  });

  test("the columns fit the viewport on this device", async ({ page }) => {
    const { project_id } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features`);

    const viewport = page.viewportSize().width;

    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );

    for (const [column] of COLUMNS) {
      const box = await page.locator(`[data-column="${column}"]`).boundingBox();
      expect(box.width).toBeLessThanOrEqual(viewport);
    }
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`the feature board has no serious accessibility violations (${colorScheme})`, async ({
      page,
    }) => {
      await page.emulateMedia({ colorScheme });
      const { project_id } = await bootstrap(page, "features", { populated: "true" });
      await openLive(page, `/projects/${project_id}/features`);

      await expectNoSeriousAxeViolations(page);
    });
  }

  test("the feature detail has no serious accessibility violations", async ({ page }) => {
    const { project_id, features } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features/${features.draft}`);

    await expectNoSeriousAxeViolations(page);
  });
});
