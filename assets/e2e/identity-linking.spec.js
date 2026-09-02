const { test, expect } = require("@playwright/test");

// Browser proof for the identity-linking surface (Task 9). The authenticated
// detected -> verify -> confirm flow needs a live GitHub sign-in and is carried
// deterministically by the LiveView integration tests; these scenarios cover the
// account-neutral, unauthenticated boundary that is driveable against the dev
// server.
test.describe("identity linking", () => {
  test("the linking confirmation is protected when unauthenticated", async ({ page }) => {
    await page.goto("/identity/link/00000000-0000-0000-0000-000000000000");
    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
  });

  test("an invalid verification link is account-neutral and discloses no account", async ({
    page,
  }) => {
    await page.goto(
      "/identity/link/verify?challenge=00000000-0000-0000-0000-000000000000&token=invalid-token",
    );

    // The link is invalid, so nothing is linked and the user is returned through a
    // protected redirect to the generic entry surface — no account is disclosed.
    // That redirect lands on the catalog, which takes either sign-in (specs/45)
    // and turns an unauthenticated browser away carrying its own marker.
    await expect(page).toHaveURL(/\/\?project_access=required$/);
    await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
  });
});
