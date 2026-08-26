const { test, expect } = require("@playwright/test");
const { bootstrap, expectNoSeriousAxeViolations, openLive } = require("./support/harness");

// Browser proof for the signed-in combined catalog (specs/05 Task 5, AC-10 and
// AC-11). The composition rules are proven deterministically at the query and
// LiveView level; what only a browser can show is that a real signed-in session
// renders both authorities in one list, that a stable-id collision surfaces as
// two separate rows carrying a stated conflict and no resolution control, and
// that signing out withdraws the hosted half while the device half stays
// reachable under the local operating-system boundary.
//
// The device records are seeded through the `specs/06-project-portability/`
// restore path, because a visibility-bounded restore is the only way two
// separately authoritative records come to share one stable project id.
//
// Other suites leave their own device projects in this run's device store, so
// every assertion here addresses its own seeded ids rather than the size of the
// catalog.

const CATALOG = "#project-catalog";

function row(page, mode, id) {
  return page.locator(`${CATALOG} [data-project-row][data-storage-mode="${mode}"][data-id="${id}"]`);
}

test.describe("signed-in combined catalog", () => {
  test("composes both authorities and keeps a shared stable id as two conflicting rows", async ({
    page,
  }) => {
    const seeded = await bootstrap(page, "mixed_catalog");

    expect(seeded.conflicting_project_id).toBe(seeded.hosted_project_id);

    await openLive(page, "/projects");

    // Each authoritative record appears once, under its own storage mode.
    const hostedRow = row(page, "hosted", seeded.hosted_project_id);
    const deviceOnlyRow = row(page, "device", seeded.device_project_id);
    const deviceTwinRow = row(page, "device", seeded.conflicting_project_id);

    await expect(hostedRow).toHaveCount(1);
    await expect(deviceOnlyRow).toHaveCount(1);
    await expect(deviceTwinRow).toHaveCount(1);

    // Storage mode and availability are stated, not inferred from color.
    await expect(hostedRow).toContainText("In my SDD Orchestrator account");
    await expect(deviceOnlyRow).toContainText("On this device");
    await expect(deviceTwinRow).toContainText("On this device");
    // Availability is stated in words next to each row, never by color alone.
    await expect(hostedRow).toContainText(/Connected|Disconnected|Temporarily unavailable/);
    await expect(deviceOnlyRow).toContainText(/Connected|Unavailable/);

    // A device repository never exposes a shareable label, only its fingerprint
    // stays on the device, so the row states the mode without naming a repo.
    await expect(deviceOnlyRow).not.toContainText("octo/example");

    // The collision: both records sharing the stable id are flagged, and the
    // record that shares nothing is not.
    await expect(hostedRow.locator("[data-identity-conflict]")).toHaveCount(1);
    await expect(deviceTwinRow.locator("[data-identity-conflict]")).toHaveCount(1);
    await expect(deviceOnlyRow.locator("[data-identity-conflict]")).toHaveCount(0);
    await expect(hostedRow.locator("[data-identity-conflict]")).toContainText(
      "this project also exists in another storage location",
    );

    // No resolution is offered: the catalog never lets a reader merge, choose an
    // authority, upload, or change a storage mode from the conflict state.
    const conflictText = await page.locator(CATALOG).innerText();
    for (const forbidden of ["Merge", "Resolve", "Keep this one", "Upload", "Move to"]) {
      expect(conflictText).not.toContain(forbidden);
    }

    // Each row still opens its own authority; neither was reassigned.
    await expect(hostedRow.locator("a")).toHaveAttribute(
      "href",
      `/projects/${seeded.hosted_project_id}`,
    );
    await expect(deviceTwinRow.locator("a")).toHaveAttribute(
      "href",
      `/local/projects/${seeded.conflicting_project_id}`,
    );

    // Duplicate stable ids must not produce duplicate DOM ids, which would make
    // the two records one node to assistive technology and to LiveView patching.
    const duplicateDomIds = await page.evaluate(() => {
      const ids = [...document.querySelectorAll("[id]")].map((el) => el.id);
      return ids.filter((id, index) => ids.indexOf(id) !== index);
    });
    expect(duplicateDomIds).toEqual([]);

    await expectNoSeriousAxeViolations(page);
  });

  test("signing out withdraws the hosted half and leaves the device half reachable", async ({
    page,
  }) => {
    const seeded = await bootstrap(page, "mixed_catalog", { conflict: "false" });

    expect(seeded.conflicting_project_id).toBeNull();

    await openLive(page, "/projects");
    await expect(row(page, "hosted", seeded.hosted_project_id)).toHaveCount(1);
    await expect(row(page, "device", seeded.device_project_id)).toHaveCount(1);

    // The product's own sign-out, not a cleared cookie.
    await page.getByRole("link", { name: "Sign out" }).click();
    await expect(page).toHaveURL(/\/$/);

    // The hosted catalog is protected again.
    await page.goto("/projects");
    await expect(page).toHaveURL(/\/$/);

    // The device project is still available under the local OS boundary, and
    // signing out changed neither its storage mode nor its ownership.
    await page.goto(`/local/projects/${seeded.device_project_id}`);
    await expect(page).toHaveURL(new RegExp(`/local/projects/${seeded.device_project_id}`));
    await expect(page.getByText(seeded.device_project_name)).toBeVisible();
  });
});
