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
    // The only select on the screen assigns a person; no control anywhere offers
    // a lifecycle column as a destination.
    await expect(page.locator("[data-gated-action]")).toBeVisible();
    await expect(page.locator("[data-gated-action]")).toContainText(/Review the result/i);
    await expect(page.locator("[data-gated-action] select")).toHaveCount(0);

    const optionLabels = await page.locator("select option").allTextContents();
    for (const [, label] of COLUMNS) {
      expect(optionLabels).not.toContain(label);
    }

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

  test("a feature is assigned to another current participant", async ({ page }) => {
    const { project_id, features, owner_name, participant_name } = await bootstrap(
      page,
      "features",
      { populated: "true" },
    );
    await openLive(page, `/projects/${project_id}/features/${features.draft}`);

    const select = page.locator("[data-assignment-select]");

    await expect(page.locator("[data-feature-assignee]")).toHaveText("Nobody yet");
    await expect(page.locator("[data-feature-responsible]")).toHaveText(owner_name);

    // The selector offers exactly the current members, by project display name.
    await expect(select.locator("option")).toHaveText(["Nobody yet", owner_name, participant_name]);
    await expect(page.locator("body")).not.toContainText("@example.com");

    await select.selectOption({ label: participant_name });

    await expect(page.locator("[data-feature-assignee]")).toHaveText(participant_name);
    await expect(page.locator("[data-feature-responsible]")).toHaveText(participant_name);
    await expect(page.locator("[data-assignment-error]")).toHaveCount(0);
  });

  test("Assign to me takes the feature for the acting participant", async ({ page }) => {
    const { project_id, features, participant_name } = await bootstrap(page, "features", {
      populated: "true",
      as: "participant",
    });
    await openLive(page, `/projects/${project_id}/features/${features.draft}`);

    await page.locator("[data-assign-to-me]").click();

    await expect(page.locator("[data-feature-assignee]")).toHaveText(participant_name);
    await expect(page.locator("[data-feature-responsible]")).toHaveText(participant_name);
  });

  test("the assignment controls are keyboard reachable and fit the viewport", async ({ page }) => {
    const { project_id, features } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features/${features.draft}`);

    await page.locator("[data-assignment-select]").focus();
    const ring = await tabTo(page, "[data-assign-to-me]");
    expect(ring.style).not.toBe("none");

    const viewport = page.viewportSize().width;
    const box = await page.locator("[data-assignment]").boundingBox();

    expect(box.width).toBeLessThanOrEqual(viewport);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );
  });

  test("a participant comments under their project display name", async ({ page }) => {
    const { project_id, features, participant_name } = await bootstrap(page, "features", {
      populated: "true",
      as: "participant",
    });
    await openLive(page, `/projects/${project_id}/features/${features.draft}`);

    await expect(page.locator("[data-comments-empty]")).toBeVisible();

    await fillDebounced(page, "#comment-body", "The empty state needs work.");
    await page.locator("[data-post-comment]").click();

    await expect(page.locator("[data-comment]")).toHaveCount(1);
    await expect(page.locator("[data-comment-body]")).toHaveText("The empty state needs work.");
    await expect(page.locator("[data-comment-author]")).toHaveText(participant_name);
    await expect(page.locator("[data-comments-empty]")).toHaveCount(0);
    await expect(page.locator("body")).not.toContainText("@example.com");
  });

  test("a comment carrying an address is refused inline", async ({ page }) => {
    const { project_id, features } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features/${features.draft}`);

    await fillDebounced(page, "#comment-body", "ask alex@example.com about this");
    await page.locator("[data-post-comment]").click();

    await expect(page.locator("#comment-body-error")).toContainText(/Remove the address/i);
    await expect(page.locator("[data-comment]")).toHaveCount(0);
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

  // Verification evidence (specs/07 Task 31, AC-40). These scenarios run under
  // both the desktop and the mobile Playwright project, which is what makes the
  // responsive claim a claim about two real viewports rather than about a
  // breakpoint class.
  test("the evidence section is present and says when nothing has been proved", async ({
    page,
  }) => {
    const { project_id, features } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features/${features.in_development}`);

    const evidence = page.locator("[data-evidence]");

    await expect(evidence).toBeVisible();
    await expect(page.locator("#evidence-heading")).toHaveText("Verification evidence");
    await expect(evidence).toHaveAttribute("aria-labelledby", "evidence-heading");

    // An untouched feature has proved nothing, and says so rather than
    // presenting an empty list that could be read as "everything passed".
    await expect(page.locator("[data-evidence-empty]")).toBeVisible();
    await expect(page.locator("[data-evidence-item]")).toHaveCount(0);
    await expect(page.locator("[data-verification]")).toHaveCount(0);
  });

  test("the evidence section fits this device without scrolling the page sideways", async ({
    page,
  }) => {
    const { project_id, features } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features/${features.in_development}`);

    const viewport = page.viewportSize().width;
    const box = await page.locator("[data-evidence]").boundingBox();

    expect(box.width).toBeLessThanOrEqual(viewport);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );
  });

  test("the evidence section keeps the detail screen keyboard reachable", async ({ page }) => {
    const { project_id, features } = await bootstrap(page, "features", { populated: "true" });
    await openLive(page, `/projects/${project_id}/features/${features.in_development}`);

    // The evidence section sits between the assignment controls and the comment
    // form. Tabbing from before it to the control after it is what proves the
    // section introduces no keyboard trap, and that control still shows a ring.
    await page.locator("[data-assignment-select]").focus();

    const postRing = await tabTo(page, "[data-post-comment]");
    expect(postRing.style).not.toBe("none");
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`the feature detail with its evidence section is accessible (${colorScheme})`, async ({
      page,
    }) => {
      await page.emulateMedia({ colorScheme });
      const { project_id, features } = await bootstrap(page, "features", { populated: "true" });
      await openLive(page, `/projects/${project_id}/features/${features.in_development}`);

      await expect(page.locator("[data-evidence]")).toBeVisible();
      await expectNoSeriousAxeViolations(page);
    });
  }
});
