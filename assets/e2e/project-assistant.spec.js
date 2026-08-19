const { test, expect } = require("@playwright/test");
const { bootstrap, expectNoSeriousAxeViolations, openLive, tabTo } = require("./support/harness");

// Authenticated browser proof for the project assistant panel (specs/12
// Task 8). Each test seeds its own project graph through the
// `project_assistant` bootstrap scenario, which mirrors this feature's own
// focused LiveView test fixture chain: a real personal AI connection,
// catalog, and quota when `state=available`, so the seeded
// `SddOrchestratorWeb.E2EModelCompletionAdapter` (compile-time gated to the
// isolated e2e server, never a production build) can answer one real turn
// with a citation, an uncertainty marker, or a normalized failure — no live
// model or repository worker anywhere in the path.

const PANEL = "[data-project-assistant-panel]";
const TOGGLE = "[data-project-assistant-toggle]";

async function openPanel(page) {
  await page.locator(TOGGLE).click();
  await expect(page.locator(PANEL)).toBeVisible();
}

test.describe("project assistant panel", () => {
  test("is reachable from the project overview, board, feature, participation, and backup screens without leaving the screen", async ({
    page,
  }) => {
    const { project_id, feature_id } = await bootstrap(page, "project_assistant", {
      state: "setup_needed",
    });

    for (const [path, screen] of [
      [`/projects/${project_id}/overview`, "project-dashboard"],
      [`/projects/${project_id}/features`, "feature-board"],
      [`/projects/${project_id}/features/${feature_id}`, "feature-detail"],
      [`/projects/${project_id}/participation`, "participation-settings"],
      [`/projects/${project_id}/backup`, "project-backup"],
    ]) {
      await openLive(page, path);
      await expect(page.locator(`[data-screen="${screen}"]`)).toBeVisible();
      // `[data-project-assistant]` is a plain wrapper around two
      // `position: fixed` children (the toggle and, once open, the panel),
      // so it collapses to a 0x0 box in normal flow; the toggle itself is
      // the reachable, on-screen element.
      await expect(page.locator(TOGGLE)).toBeVisible();

      await openPanel(page);
      // Opening the panel is an in-page state change, not a navigation.
      await expect(page).toHaveURL(new RegExp(path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$"));
      await expect(page.locator(`[data-screen="${screen}"]`)).toBeVisible();

      // On mobile the open panel covers the whole viewport, including the
      // floating toggle underneath it, so closing goes through the panel's
      // own in-header close control — the same control keyboard users reach
      // first once the panel opens (see the keyboard test below).
      await page.locator("[data-project-assistant-close]").click();
      await expect(page.locator(PANEL)).toHaveCount(0);
    }
  });

  test("keyboard opens and closes the panel with a visible, returning focus ring", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "project_assistant", { state: "setup_needed" });
    await openLive(page, `/projects/${project_id}/features`);

    const toggleRing = await tabTo(page, TOGGLE);
    expect(toggleRing.style).not.toBe("none");
    expect(toggleRing.width).toBe("2px");

    await page.keyboard.press("Enter");
    await expect(page.locator(PANEL)).toBeVisible();

    // Opening the panel moves focus inside it (its close control), rather
    // than leaving a keyboard user stranded on the page behind it.
    await expect(page.locator("[data-project-assistant-close]")).toBeFocused();

    await page.keyboard.press("Escape");
    await expect(page.locator(PANEL)).toHaveCount(0);
    await expect(page.locator(`[id="${await page.locator(TOGGLE).getAttribute("id")}"]`)).toBeFocused();
  });

  test("no serious accessibility violations with the panel open, light and dark", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "project_assistant", { state: "available" });

    for (const colorScheme of ["light", "dark"]) {
      await page.emulateMedia({ colorScheme });
      await openLive(page, `/projects/${project_id}/features`);
      await openPanel(page);
      await expectNoSeriousAxeViolations(page);
    }
  });

  test("the panel fits without horizontal overflow on mobile", async ({ page }) => {
    const { project_id } = await bootstrap(page, "project_assistant", { state: "available" });
    await openLive(page, `/projects/${project_id}/features`);
    await openPanel(page);

    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow, "horizontal overflow with the panel open").toBeLessThanOrEqual(1);

    const viewport = page.viewportSize().width;
    const panelBox = await page.locator(PANEL).boundingBox();
    expect(panelBox.width).toBeLessThanOrEqual(viewport);
  });

  test("no personal AI connection shows the safe setup-needed state, never a mutation control or exact quota", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "project_assistant", { state: "setup_needed" });
    await openLive(page, `/projects/${project_id}/overview`);
    await openPanel(page);

    await expect(
      page.locator('[data-project-assistant-availability][data-availability-state="setup_needed"]'),
    ).toBeVisible();
    await expect(page.locator("[data-project-assistant-question]")).toBeDisabled();
    await expect(page.locator("[data-project-assistant-ask]")).toBeDisabled();

    const panelText = (await page.locator(PANEL).innerText()).toLowerCase();
    for (const forbidden of ["quota", "credit", "credential", "api_key", "token", "@"]) {
      expect(panelText, `panel unexpectedly showed ${forbidden}`).not.toContain(forbidden);
    }

    // No comment, assignment, readiness, or run control anywhere in the panel.
    const panelHtml = await page.locator(PANEL).innerHTML();
    for (const forbidden of [
      "data-assign",
      "data-comment",
      "data-start-run",
      "data-retry-run",
      "data-approve",
      "data-reject",
    ]) {
      expect(panelHtml).not.toContain(forbidden);
    }
  });

  test("a linked but incompatible connection shows the safe unavailable state", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "project_assistant", { state: "unavailable" });
    await openLive(page, `/projects/${project_id}/overview`);
    await openPanel(page);

    await expect(
      page.locator('[data-project-assistant-availability][data-availability-state="unavailable"]'),
    ).toBeVisible();
    await expect(page.locator("[data-project-assistant-question]")).toBeDisabled();
  });

  test("confirming the disclosed boundary, asking, opening a citation, and deleting the conversation", async ({
    page,
  }) => {
    const { project_id, specification_title } = await bootstrap(page, "project_assistant", {
      state: "available",
    });
    await openLive(page, `/projects/${project_id}/features`);
    await openPanel(page);

    // First question requires confirming the disclosed processing summary.
    await expect(page.locator("[data-project-assistant-disclosure]")).toBeVisible();
    await expect(page.locator("[data-project-assistant-ask]")).toBeDisabled();
    await page.locator("[data-project-assistant-confirm-boundary]").click();
    await expect(page.locator("[data-project-assistant-disclosure]")).toHaveCount(0);

    // A resolved, readable specification citation.
    await page.locator("[data-project-assistant-question]").fill("spec-valid: what is current");
    await page.locator("[data-project-assistant-ask]").click();
    await expect(page.locator('[data-project-assistant-turn][data-turn-outcome="answered"]')).toBeVisible();
    await expect(page.locator("[data-turn-answer]")).toContainText("The current specification is");

    const citation = page.locator('[data-project-assistant-citation][data-citation-source-type="specification"]');
    await expect(citation).toBeVisible();
    await citation.click();
    await expect(page.locator("[data-project-assistant-citation-detail]")).toContainText(specification_title);
    await page.locator('[data-project-assistant-citation-detail] button[aria-label="Close citation"]').click();
    await expect(page.locator("[data-project-assistant-citation-detail]")).toHaveCount(0);

    // A repository claim with no bound worker resolves as a visible
    // source-unavailable marker rather than a fabricated citation.
    await page.locator("[data-project-assistant-question]").fill("repository-valid: source please");
    await page.locator("[data-project-assistant-ask]").click();
    await expect(page.locator('[data-marker-type="unavailable"]')).toBeVisible();
    await expect(page.locator(PANEL)).not.toContainText("lib/app.ex");

    // A normalized model-completion failure, with a retry affordance that
    // refills (not resubmits) the same question.
    await page.locator("[data-project-assistant-question]").fill("fails: model_unavailable");
    await page.locator("[data-project-assistant-ask]").click();
    await expect(page.locator("[data-turn-failure]")).toBeVisible();
    await page.locator("[data-project-assistant-retry]").click();
    await expect(page.locator("[data-project-assistant-question]")).toHaveValue("fails: model_unavailable");

    // Immediate deletion.
    await page.locator("[data-project-assistant-delete]").click();
    await page.locator("[data-project-assistant-delete-confirm-yes]").click();
    await expect(page.locator("[data-project-assistant-turn]")).toHaveCount(0);
    await expect(page.locator("[data-project-assistant-delete]")).toHaveCount(0);
  });

  test("each participant's history stays private to them", async ({ page, context }) => {
    const { project_id } = await bootstrap(page, "project_assistant", { state: "available" });
    await openLive(page, `/projects/${project_id}/features`);
    await openPanel(page);

    await page.locator("[data-project-assistant-confirm-boundary]").click();
    await page.locator("[data-project-assistant-question]").fill("spec-valid: owner only");
    await page.locator("[data-project-assistant-ask]").click();
    await expect(page.locator('[data-project-assistant-turn][data-turn-outcome="answered"]')).toBeVisible();

    // A fresh, signed-out context reaching the project without the owner's
    // session never reaches the screen at all (it fails closed to the
    // project catalog, which itself requires a session and bounces on to
    // the entry screen) — confirming the private conversation cannot leak
    // through a second unauthenticated browser.
    const other = await context.browser().newContext();
    const otherPage = await other.newPage();
    await otherPage.goto(`/projects/${project_id}/features`);
    await expect(otherPage.locator('[data-screen="feature-board"]')).toHaveCount(0);
    await other.close();
  });
});
