const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  fillDebounced,
  openLive,
  tabTo,
} = require("./support/harness");

// Authenticated browser proof for participation settings (specs/08 Tasks 28,
// 15, 29, 17, 18, 35). Each test seeds its own project graph, so the desktop
// and mobile projects run the same scenarios independently.
test.describe("participation settings", () => {
  // Task 35 retired the gate this used to prove: an owner who never edited the
  // label still reaches the invitation action, and correcting the label is a
  // choice offered beside it rather than a precondition (AC-26).
  test("the owner label is presented and correctable without blocking invitations", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "project_owner", { owner_profile: "false" });
    await openLive(page, `/projects/${project_id}/participation`);

    await expect(page.locator("[data-owner-profile-required]")).toHaveCount(0);
    await expect(page.locator("[data-invitations-unavailable]")).toHaveCount(0);
    await expect(page.locator("[data-invitations-available]")).toBeVisible();
    await expect(page.locator("#invite-email")).toBeVisible();

    // No stored label yet, so the neutral role label stands in — never an address.
    const ownerLabel = page.locator("[data-invitation-owner-label]");
    await expect(ownerLabel).toContainText("The invitation shows you as");
    await expect(page.locator("[data-invitation-owner-name]")).toHaveText("Project owner");
    await expect(ownerLabel).not.toContainText("@");

    await fillDebounced(page, "#owner-display-name", "Robin Owner");
    await page.locator("[data-save-owner-profile]").click();

    await expect(page.locator("[data-owner-profile-saved]")).toBeVisible();
    await expect(page.locator("[data-invitation-owner-name]")).toHaveText("Robin Owner");
    await expect(page.locator("[data-member][data-member-role=owner] [data-member-name]")).toHaveText(
      "Robin Owner",
    );
  });

  test("the owner corrects the invitation label inline and still sends", async ({ page }) => {
    const { project_id, owner_name } = await bootstrap(page, "project_owner");
    await openLive(page, `/projects/${project_id}/participation`);

    await expect(page.locator("[data-invitation-owner-name]")).toHaveText(owner_name);

    await page.locator("[data-correct-owner-label]").click();
    await expect(page.locator("#invitation-owner-name-input")).toHaveValue(owner_name);

    await fillDebounced(page, "#invitation-owner-name-input", "Robin Corrected");
    await page.locator("[data-save-invitation-owner-name]").click();

    await expect(page.locator("[data-invitation-owner-name-saved]")).toBeVisible();
    await expect(page.locator("[data-invitation-owner-name]")).toHaveText("Robin Corrected");
    await expect(page.locator("#invitation-owner-name-form")).toHaveCount(0);
    await expect(page.locator("[data-member][data-member-role=owner] [data-member-name]")).toHaveText(
      "Robin Corrected",
    );

    // The correction never stood between the owner and the invitation.
    await fillDebounced(page, "#invite-email", "newcomer@example.com");
    await page.locator("[data-send-invitation]").click();
    await expect(page.locator("[data-invitation-sent]")).toBeVisible();
  });

  test("a conflicting inline correction is rejected without a suffix", async ({ page }) => {
    const { project_id, owner_name, participant_name } = await bootstrap(page, "project_member");
    await openLive(page, `/projects/${project_id}/participation`);

    await page.locator("[data-correct-owner-label]").click();
    await fillDebounced(page, "#invitation-owner-name-input", participant_name.toUpperCase());
    await page.locator("[data-save-invitation-owner-name]").click();

    await expect(page.locator("#invitation-owner-name-input-error")).toBeVisible();
    await expect(page.locator("#invitation-owner-name-input")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
    await expect(page.locator("[data-invitation-owner-name-saved]")).toHaveCount(0);
    // The rejected input comes back for correction, never suffixed.
    await expect(page.locator("#invitation-owner-name-input")).toHaveValue(
      participant_name.toUpperCase(),
    );
    await expect(page.locator("[data-member][data-member-role=owner] [data-member-name]")).toHaveText(
      owner_name,
    );
  });

  test("a conflicting label is rejected inline without a suffix", async ({ page }) => {
    const { project_id, participant_name } = await bootstrap(page, "project_member");
    await openLive(page, `/projects/${project_id}/participation`);

    await fillDebounced(page, "#owner-display-name", participant_name.toLowerCase());
    await page.locator("[data-save-owner-profile]").click();

    await expect(page.locator("#owner-display-name-error")).toBeVisible();
    await expect(page.locator("#owner-display-name")).toHaveAttribute("aria-invalid", "true");
    await expect(page.locator("[data-owner-profile-saved]")).toHaveCount(0);
    await expect(page.locator("[data-member][data-member-role=participant] [data-member-name]")).toHaveText(
      participant_name,
    );
  });

  test("the owner sends, replaces, and cancels one invitation", async ({ page }) => {
    const { project_id } = await bootstrap(page, "project_owner");
    await openLive(page, `/projects/${project_id}/participation`);

    const invited = "newcomer@example.com";
    const invitation = page.locator("[data-invitation-list] [data-invitation]");

    await fillDebounced(page, "#invite-email", invited);
    await page.locator("[data-send-invitation]").click();

    await expect(page.locator("[data-invitation-sent]")).toBeVisible();
    await expect(invitation).toHaveCount(1);
    await expect(invitation.locator("[data-invitation-email]")).toHaveText(invited);
    await expect(invitation).toHaveAttribute("data-invitation-status", "pending");
    await expect(invitation.locator("[data-invitation-state]")).toHaveText(/Waiting for a reply/i);

    // Inviting the same address again offers replacement and cancellation
    // rather than a second pending invitation.
    await fillDebounced(page, "#invite-email", invited);
    await page.locator("[data-send-invitation]").click();
    await expect(page.locator("[data-resend-invitation]")).toBeVisible();

    await page.locator("[data-resend-invitation]").click();
    await expect(page.locator("[data-invitation-sent]")).toBeVisible();
    await expect(invitation).toHaveCount(1);
    await expect(invitation).toHaveAttribute("data-invitation-status", "pending");

    await fillDebounced(page, "#invite-email", invited);
    await page.locator("[data-send-invitation]").click();
    await page.locator("[data-cancel-invitation]").click();

    await expect(page.locator("[data-invitation-canceled]")).toBeVisible();
    await expect(invitation).toHaveAttribute("data-invitation-status", "canceled");
    await expect(invitation.locator("[data-invitation-state]")).toHaveText(/Canceled/i);
  });

  test("the owner sees member addresses and can remove a participant", async ({ page }) => {
    const { project_id, owner_name, participant_name, participant_email, pending_email } =
      await bootstrap(page, "project_member");
    await openLive(page, `/projects/${project_id}/participation`);

    const participant = page.locator("[data-member][data-member-role=participant]");

    await expect(page.locator("[data-member]")).toHaveCount(2);
    await expect(page.locator("[data-member][data-member-role=owner] [data-member-name]")).toHaveText(
      owner_name,
    );
    await expect(participant.locator("[data-member-name]")).toHaveText(participant_name);
    await expect(participant.locator("[data-member-email]")).toHaveText(participant_email);

    // Membership management is what the address is shown for, so the pending
    // invitation's address is listed too.
    await expect(page.locator("[data-invitation-list]")).toContainText(pending_email);

    await page.locator("[data-remove-member]").click();

    await expect(page.locator("[data-member-removed]")).toBeVisible();
    await expect(page.locator("[data-member]")).toHaveCount(1);
    await expect(page.locator("[data-member][data-member-role=participant]")).toHaveCount(0);
  });

  test("a participant sees no other address and no management controls", async ({ page }) => {
    const { project_id, owner_email, participant_email, pending_email } = await bootstrap(
      page,
      "project_member",
      { as: "participant" },
    );
    await openLive(page, `/projects/${project_id}/participation`);

    await expect(page.locator("[data-participant-view]")).toBeVisible();
    await expect(page.locator("[data-invitation-list]")).toHaveCount(0);
    await expect(page.locator("#invite-email")).toHaveCount(0);
    await expect(page.locator("[data-remove-member]")).toHaveCount(0);
    await expect(page.locator("[data-save-owner-profile]")).toHaveCount(0);
    // The owner label and its correction belong to the owner alone.
    await expect(page.locator("[data-invitation-owner-label]")).toHaveCount(0);
    await expect(page.locator("[data-correct-owner-label]")).toHaveCount(0);

    const body = page.locator("body");
    await expect(body).not.toContainText(owner_email);
    await expect(body).not.toContainText(pending_email);
    // Their own address is the one address they may see.
    await expect(page.locator("[data-member][data-member-role=participant] [data-member-email]")).toHaveText(
      participant_email,
    );
  });

  test("a participant renames only their own label and can leave", async ({ page }) => {
    const { project_id } = await bootstrap(page, "project_member", { as: "participant" });
    await openLive(page, `/projects/${project_id}/participation`);

    await fillDebounced(page, "#member-display-name", "Sam Renamed");
    await page.locator("[data-save-member-profile]").click();

    await expect(page.locator("[data-member-profile-saved]")).toBeVisible();
    await expect(page.locator("[data-member][data-member-role=participant] [data-member-name]")).toHaveText(
      "Sam Renamed",
    );

    await page.locator("[data-leave-project]").click();
    await expect(page.locator("[data-screen=participation-settings]")).toHaveCount(0);

    // Access ends immediately: the same browser cannot return to the project.
    await page.goto(`/projects/${project_id}/participation`);
    await expect(page.locator("[data-screen=participation-settings]")).toHaveCount(0);
  });

  test("the owner controls are reachable by keyboard with a visible focus ring", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "project_member");
    await openLive(page, `/projects/${project_id}/participation`);

    await page.locator("#owner-display-name").focus();
    const ring = await tabTo(page, "[data-save-owner-profile]");

    expect(ring.style).not.toBe("none");
    expect(ring.width).toBe("2px");

    // The invitation-action label correction sits next in the tab order and is
    // operable by keyboard alone, as is the field it reveals (AC-26).
    const correctRing = await tabTo(page, "[data-correct-owner-label]");

    expect(correctRing.style).not.toBe("none");
    expect(correctRing.width).toBe("2px");

    await page.keyboard.press("Enter");
    await expect(page.locator("#invitation-owner-name-input")).toBeVisible();

    await page.locator("#invitation-owner-name-input").focus();
    const saveRing = await tabTo(page, "[data-save-invitation-owner-name]");

    expect(saveRing.style).not.toBe("none");
    expect(saveRing.width).toBe("2px");

    await page.locator("[data-cancel-invitation-owner-name]").click();
    await page.locator("#invite-email").focus();
    const inviteRing = await tabTo(page, "[data-send-invitation]");

    expect(inviteRing.style).not.toBe("none");
  });

  test("the member and invitation rows stack within the viewport", async ({ page }) => {
    const { project_id } = await bootstrap(page, "project_member");
    await openLive(page, `/projects/${project_id}/participation`);

    const viewport = page.viewportSize().width;
    const member = await page.locator("[data-member]").first().boundingBox();

    expect(member.width).toBeLessThanOrEqual(viewport);

    // The owner label and its inline correction stay inside the viewport too.
    const label = await page.locator("[data-invitation-owner-label]").boundingBox();
    expect(label.width).toBeLessThanOrEqual(viewport);

    await page.locator("[data-correct-owner-label]").click();
    const correction = await page.locator("#invitation-owner-name-form").boundingBox();
    expect(correction.width).toBeLessThanOrEqual(viewport);

    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`participation settings has no serious accessibility violations (${colorScheme})`, async ({
      page,
    }) => {
      await page.emulateMedia({ colorScheme });
      const { project_id } = await bootstrap(page, "project_member");
      await openLive(page, `/projects/${project_id}/participation`);

      await expectNoSeriousAxeViolations(page);
    });
  }
});
