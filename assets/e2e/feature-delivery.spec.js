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

  // Recorded evidence, rendered. Until the `evidence` scenario existed no
  // browser could reach a feature that had actually proved anything, so the
  // states below were only ever asserted at the LiveView and domain level. Each
  // of these runs under both the desktop and the mobile Playwright project.
  test.describe("recorded evidence", () => {
    test("every recorded state renders as its own distinguishable result", async ({ page }) => {
      const { project_id, feature_id } = await bootstrap(page, "evidence");
      await openLive(page, `/projects/${project_id}/features/${feature_id}`);

      const items = page.locator("[data-evidence-item]");

      await expect(page.locator("[data-evidence-empty]")).toHaveCount(0);
      await expect(items).toHaveCount(6);

      // A passed, a failed, and a missing required check, each carrying the
      // exit code that makes the result checkable rather than asserted.
      await expect(check(page, "passed")).toHaveCount(1);
      await expect(check(page, "failed")).toHaveCount(2);
      await expect(check(page, "missing")).toHaveCount(1);
      await expect(check(page, "missing").locator("[data-evidence-fact=exit-code]")).toHaveText(
        "127",
      );
      await expect(check(page, "passed").locator("[data-evidence-fact=exit-code]")).toHaveText("0");

      // A capture that happened, and one the environment could not perform.
      // The absence is a typed record with a stated reason, not a gap.
      const captured = screenshot(page, "passed");
      const unsupported = screenshot(page, "unsupported");

      await expect(captured).toHaveCount(1);
      await expect(unsupported).toHaveCount(1);
      await expect(captured.locator("[data-evidence-fact=artifact]")).toContainText("image/png");
      await expect(captured.locator("[data-view-evidence]")).toBeVisible();
      await expect(unsupported.locator("[data-view-evidence]")).toHaveCount(0);
      await expect(unsupported.locator("[data-evidence-capture-reason]")).toContainText(
        /could not capture/i,
      );

      // Only the screenshot with stored bytes offers to open them.
      await expect(page.locator("[data-view-evidence]")).toHaveCount(1);

      // Every state names itself in words beside its colour, one label per
      // state and no label shared between two, so a reader who cannot see the
      // colours still tells the four results apart.
      const labels = (await items.locator("[data-evidence-state-label]").allInnerTexts()).map(
        (label) => label.trim(),
      );
      const states = await items.evaluateAll((rows) =>
        rows.map((row) => row.getAttribute("data-evidence-state")),
      );

      expect(new Set(states)).toEqual(new Set(["passed", "failed", "missing", "unsupported"]));
      for (const label of labels) expect(label.length).toBeGreaterThan(0);
      expect(new Set(labels).size).toBe(new Set(states).size);
      expect(new Set(pair(states, labels)).size).toBe(new Set(states).size);

      // Colour is never the only cue: each state badge carries an icon too.
      await expect(items.locator("[data-evidence-state-label] svg")).toHaveCount(6);
    });

    test("each item carries the provenance a reader checks the work against", async ({ page }) => {
      const { project_id, feature_id, branch, commit_sha, evidence } = await bootstrap(
        page,
        "evidence",
      );
      await openLive(page, `/projects/${project_id}/features/${feature_id}`);

      const items = page.locator("[data-evidence-item]");

      // Branch and commit are the same for every item because one run on one
      // commit produced them all, and both are shown in full rather than
      // shortened: they are what the work is actually checked against.
      await expect(items.locator("[data-evidence-fact=branch]")).toHaveText(Array(6).fill(branch));
      await expect(items.locator("[data-evidence-fact=commit]")).toHaveText(
        Array(6).fill(commit_sha),
      );

      // The digest is per item and is the content hash the record declares.
      await expect(items.locator("[data-evidence-fact=digest]")).toHaveText(
        evidence.map((item) => item.digest),
      );

      // Where the result came from is stated in words, never left implicit.
      const sources = await items.locator("[data-evidence-fact=source]").allInnerTexts();
      for (const source of sources) expect(source.trim().length).toBeGreaterThan(0);
    });

    test("a replaced result stays visible with the result it recorded", async ({ page }) => {
      const { project_id, feature_id, evidence } = await bootstrap(page, "evidence");
      await openLive(page, `/projects/${project_id}/features/${feature_id}`);

      const replaced = page.locator('[data-evidence-item][data-evidence-superseded="true"]');

      await expect(replaced).toHaveCount(1);
      await expect(replaced).toBeVisible();

      // It is the first recorded run of the check, not the rerun that replaced it.
      await expect(replaced).toHaveAttribute("data-evidence-id", evidence[0].id);
      await expect(replaced.locator("[data-evidence-name]")).toHaveText(evidence[0].name);

      // Its own result is still legible; being replaced did not flatten it into
      // a single "superseded" state that hides whether it passed or failed.
      await expect(replaced).toHaveAttribute("data-evidence-state", "failed");
      await expect(replaced.locator("[data-evidence-superseded-label]")).toBeVisible();
      await expect(replaced.locator("[data-evidence-replacement]")).toContainText(/replaced/i);

      // The rerun that replaced it is present under the same name and passed,
      // so the reader can see both halves of the disagreement.
      const rerun = page.locator(`[data-evidence-item][data-evidence-id="${evidence[5].id}"]`);
      await expect(rerun).toHaveAttribute("data-evidence-state", "passed");
      await expect(rerun.locator("[data-evidence-name]")).toHaveText(evidence[0].name);
      await expect(rerun).toHaveAttribute("data-evidence-superseded", "false");
    });

    test("no artifact address or reference ever reaches the page", async ({ page }) => {
      const { project_id, feature_id } = await bootstrap(page, "evidence");
      await openLive(page, `/projects/${project_id}/features/${feature_id}`);

      await expect(page.locator("[data-view-evidence]")).toBeVisible();
      await expectNoArtifactReference(page);

      // Opening the stored proof hands over content, not a location: the image
      // is embedded inline and still no reference or address exists to follow.
      await page.locator("[data-view-evidence]").click();

      const image = page.locator("[data-evidence-image]");
      await expect(image).toBeVisible();
      await expect(image).toHaveAttribute("src", /^data:image\/png;base64,/);
      await expect(page.locator("[data-evidence-artifact-note]")).toContainText(
        /no address of its own/i,
      );
      await expectNoArtifactReference(page);

      await page.locator("[data-hide-evidence]").click();
      await expect(page.locator("[data-evidence-image]")).toHaveCount(0);
    });

    test("the recorded evidence fits this device without scrolling sideways", async ({ page }) => {
      const { project_id, feature_id } = await bootstrap(page, "evidence");
      await openLive(page, `/projects/${project_id}/features/${feature_id}`);

      const viewport = page.viewportSize().width;

      await expect(page.locator("[data-evidence-item]")).toHaveCount(6);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
        viewport,
      );

      // The commit and the digest are long single tokens, so an item that keeps
      // them intact is where a sideways scroll would first appear.
      const boxes = await page.locator("[data-evidence-item]").evaluateAll((rows) =>
        rows.map((row) => row.getBoundingClientRect().width),
      );
      for (const width of boxes) expect(width).toBeLessThanOrEqual(viewport);
    });

    for (const colorScheme of ["light", "dark"]) {
      test(`the recorded evidence is accessible (${colorScheme})`, async ({ page }) => {
        await page.emulateMedia({ colorScheme });
        const { project_id, feature_id } = await bootstrap(page, "evidence");
        await openLive(page, `/projects/${project_id}/features/${feature_id}`);

        await expect(page.locator("[data-evidence-item]")).toHaveCount(6);
        await expectNoSeriousAxeViolations(page);
      });
    }
  });
});

function check(page, state) {
  return page.locator(
    `[data-evidence-item][data-evidence-kind="required_check"][data-evidence-state="${state}"]`,
  );
}

function screenshot(page, state) {
  return page.locator(
    `[data-evidence-item][data-evidence-kind="screenshot"][data-evidence-state="${state}"]`,
  );
}

function pair(states, labels) {
  return states.map((state, index) => `${state} ${labels[index].trim()}`);
}

// Private project bytes are handed to a reader as content, never as somewhere to
// go. Nothing in the markup may carry the opaque store reference, and no
// attribute the browser would dereference may point at the artifact route.
async function expectNoArtifactReference(page) {
  const markup = await page.content();

  expect(markup).not.toContain("artifact:v1:sha256:");
  expect(markup).not.toContain("artifact:v1:");

  const addresses = await page.evaluate(() =>
    Array.from(document.querySelectorAll("[src], [href], [action], [data-url]"))
      .flatMap((el) => [
        el.getAttribute("src"),
        el.getAttribute("href"),
        el.getAttribute("action"),
        el.getAttribute("data-url"),
      ])
      .filter(Boolean),
  );

  for (const address of addresses) {
    expect(address).not.toMatch(/artifact/i);
    expect(address).not.toMatch(/\/evidence\//i);
  }
}

// Authenticated browser proof for branch-preview presentation (specs/07 Task 33,
// AC-22). The seeded feature verified twice on two runs: the configured adapter
// deployed one of them and refused the other, so one screen holds a preview a
// reader may open beside one that failed — and the feature reaches review either
// way. Each of these runs under both the desktop and the mobile project.
test.describe("branch preview", () => {
  test("a deployment that succeeded offers one non-production link", async ({ page }) => {
    const { project_id, feature_id, preview_link, ready_branch, commit_sha } = await bootstrap(
      page,
      "preview",
    );
    await openLive(page, `/projects/${project_id}/features/${feature_id}`);

    const ready = previewItem(page, "ready");
    await expect(ready).toHaveCount(1);

    const link = ready.locator("[data-preview-link]");

    await expect(link).toHaveAttribute("href", preview_link);
    await expect(link).toHaveAttribute("target", "_blank");
    await expect(link).toHaveAttribute("rel", "noopener noreferrer");

    // A preview is not production, and a reader has to be able to tell which
    // branch and commit they are about to open before they open it.
    await expect(ready.locator("[data-preview-nonproduction]")).toContainText("Non-production");
    await expect(ready.locator("[data-preview-link-note]")).toContainText(ready_branch);
    await expect(ready.locator("[data-preview-link-note]")).toContainText(commit_sha);
  });

  test("a deployment the provider refused shows its reason and no link", async ({ page }) => {
    const { project_id, feature_id, failed_branch } = await bootstrap(page, "preview");
    await openLive(page, `/projects/${project_id}/features/${feature_id}`);

    const failed = previewItem(page, "failed");

    await expect(failed).toHaveCount(1);
    await expect(failed.locator("[data-preview-link]")).toHaveCount(0);
    await expect(failed.locator("[data-preview-reason]")).toContainText(/no capacity left/i);
    await expect(failed.locator('[data-preview-fact="branch"]')).toHaveText(failed_branch);

    // Both outcomes stay on the screen, and exactly one of them is somewhere a
    // reader may be sent.
    await expect(page.locator("[data-preview-item]")).toHaveCount(2);
    await expect(page.locator("[data-preview-link]")).toHaveCount(1);
  });

  test("the feature reaches review even though a preview failed", async ({ page }) => {
    const { project_id, feature_id } = await bootstrap(page, "preview");
    await openLive(page, `/projects/${project_id}/features/${feature_id}`);

    await expect(page.locator("[data-feature-column]")).toHaveText("Ready for review");
    await expect(page.locator("[data-review-handoff]")).toBeVisible();
    await expect(page.locator("[data-preview-independence]")).toContainText(/ready for review/i);
  });

  test("the preview section fits this device without scrolling sideways", async ({ page }) => {
    const { project_id, feature_id } = await bootstrap(page, "preview");
    await openLive(page, `/projects/${project_id}/features/${feature_id}`);

    const viewport = page.viewportSize().width;

    await expect(page.locator("[data-preview-item]")).toHaveCount(2);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );

    // The link is one long unbroken token, so an item holding it is where a
    // sideways scroll would first appear.
    const boxes = await page
      .locator("[data-preview-item]")
      .evaluateAll((rows) => rows.map((row) => row.getBoundingClientRect().width));

    for (const width of boxes) expect(width).toBeLessThanOrEqual(viewport);
  });

  test("the preview link is reachable by keyboard with a visible focus ring", async ({ page }) => {
    const { project_id, feature_id } = await bootstrap(page, "preview");
    await openLive(page, `/projects/${project_id}/features/${feature_id}`);

    await page.locator("[data-assignment-select]").focus();

    const ring = await tabTo(page, "[data-preview-link]", 40);

    expect(ring.style).not.toBe("none");
    expect(parseFloat(ring.width)).toBeGreaterThanOrEqual(2);
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`the preview section is accessible (${colorScheme})`, async ({ page }) => {
      await page.emulateMedia({ colorScheme });
      const { project_id, feature_id } = await bootstrap(page, "preview");
      await openLive(page, `/projects/${project_id}/features/${feature_id}`);

      await expect(page.locator("[data-preview-item]")).toHaveCount(2);
      await expectNoSeriousAxeViolations(page);
    });
  }
});

function previewItem(page, state) {
  return page.locator(`[data-preview-item][data-preview-state="${state}"]`);
}
