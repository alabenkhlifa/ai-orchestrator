const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

// Browser proof for the entry surface and session-aware routing (Task 3).
// The full GitHub sign-in round trip runs against a live GitHub App in a
// secret-backed environment (the tagged smoke test), not against this dev
// server, so it is exercised at the integration layer instead.
test.describe("entry surface", () => {
  test("shows exactly the two primary actions with correct destinations", async ({ page }) => {
    await page.goto("/");

    const login = page.getByRole("link", { name: /Login with GitHub/i });
    const local = page.getByRole("link", { name: /Work without GitHub/i });

    await expect(login).toBeVisible();
    await expect(local).toBeVisible();
    await expect(login).toHaveAttribute("href", "/auth/github");
    await expect(local).toHaveAttribute("href", "/onboarding/local");
  });

  test("the primary actions are keyboard focusable", async ({ page }) => {
    await page.goto("/");
    await page.getByRole("link", { name: /Login with GitHub/i }).focus();
    const focused = await page.evaluate(() => document.activeElement.textContent.trim());
    expect(focused).toMatch(/Login with GitHub/i);
  });

  test("renders the failure recovery state with retry", async ({ page }) => {
    await page.goto("/?auth=failed");
    await expect(page.getByText(/connect to GitHub/i)).toBeVisible();
    await expect(page.getByRole("link", { name: /Try again/i })).toHaveAttribute(
      "href",
      "/auth/github",
    );
  });

  test("renders the cancelled recovery state", async ({ page }) => {
    await page.goto("/?auth=cancelled");
    await expect(page.getByText(/Authentication cancelled/i)).toBeVisible();
  });

  test("the local action hands off to the local-onboarding page", async ({ page }) => {
    await page.goto("/");
    await page.getByRole("link", { name: /Work without GitHub/i }).click();
    await expect(page).toHaveURL(/\/onboarding\/local$/);
    await expect(page.getByRole("heading", { name: /Work without GitHub/i })).toBeVisible();
  });

  test("a protected route redirects to the entry when unauthenticated", async ({ page }) => {
    await page.goto("/projects");
    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
  });

  test("the onboarding repository-access route is protected when unauthenticated", async ({
    page,
  }) => {
    // The catalog and repository-access screens are behind a valid session; their
    // authenticated end-to-end browser scenarios are carried by the integration
    // task (Task 9) once the full onboarding flow is wired.
    await page.goto("/onboarding/repository-access/00000000-0000-0000-0000-000000000000");
    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
  });

  test("the onboarding storage route is protected when unauthenticated", async ({ page }) => {
    // The grant, picker, and storage handoff are behind a valid session; the
    // authenticated flow is carried by the integration task (Task 9).
    await page.goto("/onboarding/storage/00000000-0000-0000-0000-000000000000");
    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
  });

  test("the GitHub install handoff is protected when unauthenticated", async ({ page }) => {
    await page.goto("/github/install?attempt_id=00000000-0000-0000-0000-000000000000");
    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
  });

  for (const path of ["device-setup", "confirm"]) {
    test(`the onboarding ${path} route is protected when unauthenticated`, async ({ page }) => {
      await page.goto(`/onboarding/${path}/00000000-0000-0000-0000-000000000000`);
      await expect(page).toHaveURL(/\/$/);
      await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
    });
  }

  test("the project dashboard route is protected when unauthenticated", async ({ page }) => {
    // A created project's dashboard is behind a valid session; the authenticated
    // end-to-end flow is carried by the integration task (Task 9).
    await page.goto("/projects/00000000-0000-0000-0000-000000000000");
    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByRole("link", { name: /Login with GitHub/i })).toBeVisible();
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`entry has no serious accessibility violations (${colorScheme})`, async ({ page }) => {
      await page.emulateMedia({ colorScheme });
      await page.goto("/");
      const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa"]).analyze();
      const serious = results.violations.filter((v) => ["serious", "critical"].includes(v.impact));
      expect(serious, serious.map((v) => `${v.id}: ${v.help}`).join("\n")).toEqual([]);
    });
  }
});
