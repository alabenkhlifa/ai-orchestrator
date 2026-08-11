const { test, expect } = require("@playwright/test");
const { bootstrap, expectNoSeriousAxeViolations, openLive, tabTo } = require("./support/harness");

// Authenticated browser proof for the accessible notification inbox
// (specs/17 Task 4, AC-04). Each of these runs under both the desktop and the
// mobile Playwright project, which is what makes the "desktop or mobile"
// acceptance criterion a claim about two real viewports rather than about a
// breakpoint class.
test.describe("notification inbox", () => {
  test("lists the account's notifications with their unread and read state", async ({ page }) => {
    const { project_name, unread_title, read_title } = await bootstrap(page, "notifications");
    await openLive(page, "/notifications");

    await expect(page.locator("[data-notification]")).toHaveCount(2);

    const unread = page.locator('[data-notification][data-notification-unread="true"]');
    const read = page.locator('[data-notification][data-notification-unread="false"]');

    await expect(unread).toHaveCount(1);
    await expect(unread.locator("[data-notification-title]")).toHaveText(unread_title);
    await expect(unread).toContainText(project_name);
    await expect(unread.getByRole("button", { name: "Mark read" })).toBeVisible();
    await expect(unread.getByRole("button", { name: "Open" })).toBeVisible();

    await expect(read).toHaveCount(1);
    await expect(read.locator("[data-notification-title]")).toHaveText(read_title);
    await expect(read.getByText("Read")).toBeVisible();
    await expect(read.getByRole("button", { name: "Mark read" })).toHaveCount(0);
  });

  test("shows the caught-up empty state once nothing is unread or listed", async ({ page }) => {
    // A fresh account with no seeded delivery notifications proves the empty
    // state rather than an emptied list, since the list is never mutated to
    // reach zero here.
    await bootstrap(page, "project_owner");
    await openLive(page, "/notifications");

    await expect(page.locator("[data-notification]")).toHaveCount(0);
    await expect(page.getByText(/all caught up/i)).toBeVisible();
  });

  test("marking an unread notification read replaces its action with a Read badge", async ({
    page,
  }) => {
    const { unread_notification_id } = await bootstrap(page, "notifications");
    await openLive(page, "/notifications");

    const row = page.locator(`#notification-${unread_notification_id}`);

    await row.getByRole("button", { name: "Mark read" }).click();

    await expect(row).toHaveAttribute("data-notification-unread", "false");
    await expect(row.getByText("Read")).toBeVisible();
    await expect(row.getByRole("button", { name: "Mark read" })).toHaveCount(0);

    // The safe-link action stays available either way.
    await expect(row.getByRole("button", { name: "Open" })).toBeVisible();
  });

  test("opening a notification navigates to its linked feature", async ({ page }) => {
    const { project_id, feature_id, unread_notification_id } = await bootstrap(
      page,
      "notifications",
    );
    await openLive(page, "/notifications");

    await page.locator(`#notification-${unread_notification_id}-open`).click();

    await expect(page).toHaveURL(new RegExp(`/projects/${project_id}/features/${feature_id}$`));
    await expect(page.locator("[data-screen=feature-detail]")).toBeVisible();
  });

  test("the inbox is reachable by keyboard with a visible focus ring", async ({ page }) => {
    const { unread_notification_id } = await bootstrap(page, "notifications");
    await openLive(page, "/notifications");

    // The theme toggle is the shared page shell's first focusable control, so
    // it is a stable place to start tabbing forward from on any screen.
    await page.locator("#theme-toggle").focus();

    const markReadRing = await tabTo(page, `#notification-${unread_notification_id}-mark-read`);
    expect(markReadRing.style).not.toBe("none");

    const openRing = await tabTo(page, `#notification-${unread_notification_id}-open`);
    expect(openRing.style).not.toBe("none");
  });

  test("the inbox fits this device without scrolling the page sideways", async ({ page }) => {
    await bootstrap(page, "notifications");
    await openLive(page, "/notifications");

    const viewport = page.viewportSize().width;

    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );

    const boxes = await page
      .locator("[data-notification]")
      .evaluateAll((rows) => rows.map((row) => row.getBoundingClientRect().width));

    for (const width of boxes) expect(width).toBeLessThanOrEqual(viewport);
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`the inbox has no serious accessibility violations (${colorScheme})`, async ({
      page,
    }) => {
      await page.emulateMedia({ colorScheme });
      await bootstrap(page, "notifications");
      await openLive(page, "/notifications");

      await expect(page.locator("[data-notification]")).toHaveCount(2);
      await expectNoSeriousAxeViolations(page);
    });
  }
});
