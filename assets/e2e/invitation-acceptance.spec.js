const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  fillDebounced,
  openLive,
  tabTo,
} = require("./support/harness");

// Authenticated browser proof for the invited person's entry point (specs/08
// Tasks 12 and 13). The link each test opens is the credential that was
// actually delivered for its own seeded invitation.
test.describe("invitation acceptance", () => {
  test("an unproven browser is asked to confirm the invited address", async ({ page }) => {
    const { invitation_path, invited_email, project_name } = await bootstrap(page, "invitation");
    await openLive(page, invitation_path);

    await expect(page.locator("[data-screen=invitation-acceptance]")).toBeVisible();
    await expect(page.locator("[data-invited-email]")).toHaveText(invited_email);
    await expect(page.getByRole("heading", { name: new RegExp(project_name, "i") })).toBeVisible();

    // Nothing is offered until the address is proven.
    await expect(page.locator("[data-accept-invitation]")).toHaveCount(0);
    await expect(page.locator("[data-decline-invitation]")).toHaveCount(0);
    await expect(page.locator("[data-request-proof]")).toBeVisible();

    await page.locator("[data-request-proof]").click();
    await expect(page.locator("[data-proof-requested]")).toBeVisible();
    await expect(page.locator("[data-accept-invitation]")).toHaveCount(0);
  });

  test("an already signed-in other identity is warned, not treated as proof", async ({ page }) => {
    const { invitation_path, invited_email } = await bootstrap(page, "invitation", {
      as: "other",
    });
    await openLive(page, invitation_path);

    const warning = page.locator("[data-identity-change-warning]");

    await expect(warning).toBeVisible();
    await expect(warning).toContainText(invited_email);
    await expect(warning).toContainText(/other sign-ins elsewhere are not affected/i);
    await expect(page.locator("[data-proof-complete]")).toHaveCount(0);
    await expect(page.locator("[data-accept-invitation]")).toHaveCount(0);
    await expect(page.locator("[data-request-proof]")).toBeVisible();
  });

  test("the proven invitee joins the project explicitly", async ({ page }) => {
    const { acceptance_path, project_id, project_name, owner_name } = await bootstrap(
      page,
      "invitation",
      { as: "invited" },
    );
    await openLive(page, acceptance_path);

    await expect(page.locator("[data-proof-complete]")).toBeVisible();
    await expect(page.locator("[data-owner-label]")).toContainText(owner_name);
    await expect(page.locator("[data-request-proof]")).toHaveCount(0);

    // Proof alone is not membership: an explicit outcome is still required.
    await expect(page.locator("[data-joined]")).toHaveCount(0);

    await fillDebounced(page, "#member-display-name", "Alex Joiner");
    await page.locator("[data-accept-invitation]").click();

    await expect(page.locator("[data-joined]")).toBeVisible();
    await expect(page.locator("[data-joined]")).toContainText(project_name);
    await expect(page.locator("[data-open-project]")).toBeVisible();

    await openLive(page, `/projects/${project_id}/participation`);
    await expect(page.locator("[data-member][data-member-role=participant] [data-member-name]")).toHaveText(
      "Alex Joiner",
    );
  });

  test("an unavailable project label is rejected without joining", async ({ page }) => {
    const { acceptance_path, owner_name } = await bootstrap(page, "invitation", {
      as: "invited",
    });
    await openLive(page, acceptance_path);

    await fillDebounced(page, "#member-display-name", owner_name.toUpperCase());
    await page.locator("[data-accept-invitation]").click();

    await expect(page.locator("#member-display-name-error")).toBeVisible();
    await expect(page.locator("[data-joined]")).toHaveCount(0);
  });

  test("the proven invitee declines and gains no access", async ({ page }) => {
    const { acceptance_path, project_id } = await bootstrap(page, "invitation", {
      as: "invited",
    });
    await openLive(page, acceptance_path);

    await page.locator("[data-decline-invitation]").click();

    await expect(page.locator("[data-declined]")).toBeVisible();
    await expect(page.locator("[data-accept-invitation]")).toHaveCount(0);

    await page.goto(`/projects/${project_id}/participation`);
    await expect(page.locator("[data-screen=participation-settings]")).toHaveCount(0);
  });

  test("a used-up invitation reports one safe unavailable result", async ({ page }) => {
    const { acceptance_path, invitation_path } = await bootstrap(page, "invitation", {
      as: "invited",
    });
    await openLive(page, acceptance_path);
    await page.locator("[data-decline-invitation]").click();
    await expect(page.locator("[data-declined]")).toBeVisible();

    // The delivered link stops working, and the result names neither the
    // project nor the invited address.
    await openLive(page, invitation_path);
    await expect(page.locator("[data-invitation-unavailable]")).toBeVisible();
    await expect(page.locator("[data-invited-email]")).toHaveCount(0);
  });

  test("the acceptance actions are reachable by keyboard with a visible focus ring", async ({
    page,
  }) => {
    const { acceptance_path } = await bootstrap(page, "invitation", { as: "invited" });
    await openLive(page, acceptance_path);

    await page.locator("#member-display-name").focus();
    const ring = await tabTo(page, "[data-accept-invitation]");

    expect(ring.style).not.toBe("none");
    expect(ring.width).toBe("2px");

    const declineRing = await tabTo(page, "[data-decline-invitation]");
    expect(declineRing.style).not.toBe("none");
  });

  test("the acceptance actions fit the viewport", async ({ page }) => {
    const { acceptance_path } = await bootstrap(page, "invitation", { as: "invited" });
    await openLive(page, acceptance_path);

    const viewport = page.viewportSize().width;
    const accept = await page.locator("[data-accept-invitation]").boundingBox();

    expect(accept.width).toBeLessThanOrEqual(viewport);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`invitation acceptance has no serious accessibility violations (${colorScheme})`, async ({
      page,
    }) => {
      await page.emulateMedia({ colorScheme });
      const { acceptance_path } = await bootstrap(page, "invitation", { as: "invited" });
      await openLive(page, acceptance_path);

      await expectNoSeriousAxeViolations(page);
    });
  }
});
