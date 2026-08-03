const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  openLive,
  tabTo,
} = require("./support/harness");

test.describe("AI Connections", () => {
  test("guides missing, unavailable, and incompatible local workers", async ({ page }) => {
    for (const [workerState, guidance] of [
      ["missing", "missing"],
      ["unavailable", "unavailable"],
      ["incompatible", "incompatible"],
    ]) {
      await bootstrap(page, "ai_connections", { worker_state: workerState });
      await openLive(page, "/ai-connections");

      await expect(page.locator(`[data-worker-guidance=${guidance}]`)).toBeVisible();
      await expect(page.locator("[data-link-connection]")).toBeDisabled();
    }
  });

  test("links multiple credential-local connections then renames and revokes one", async ({
    page,
  }) => {
    await bootstrap(page, "ai_connections", { worker_state: "ready" });
    await openLive(page, "/ai-connections");

    await expect(page.locator("[data-screen=ai-connections]")).toBeVisible();
    await expect(page.getByText("Local worker 1", { exact: true }).first()).toBeVisible();
    await expect(page.locator("[data-catalog-panel]")).toContainText("currently unavailable");
    await expect(page.locator("[data-quota-panel]")).toContainText("currently unknown");

    await page.locator("#connection-label").fill("Personal ChatGPT");
    await page.locator("#connection-worker").selectOption("local-worker-1");
    await page.locator("input[value=chatgpt]").check();
    await page.locator("[data-link-connection]").click();

    await expect(page.locator("[data-link-state=pending]")).toBeVisible();
    await expect(page.locator("[data-link-state=ok]")).toContainText(
      "ChatGPT sign-in completed in the local worker",
    );

    await page.locator("#connection-label").fill("Personal API");
    await page.locator("input[value=api_key]").check();
    await page.locator("[data-link-connection]").click();

    await expect(page.locator("[data-link-state=pending]")).toBeVisible();
    await expect(page.locator("[data-link-state=ok]")).toContainText(
      "API-key entry stayed in the local worker",
    );
    await expect(page.locator("[data-connection]")).toHaveCount(2);

    const first = page.locator("[data-connection]").filter({ hasText: "Personal ChatGPT" });
    const firstId = await first.getAttribute("id");
    const firstCard = page.locator(`#${firstId}`);
    await first.locator("[data-rename-connection]").click();
    const rename = firstCard.locator("input[name='rename[label]']");
    await expect(rename).toBeFocused();
    await rename.fill("Primary ChatGPT");
    await firstCard.locator("[data-save-rename]").click();
    await expect(firstCard.locator("[data-connection-label]")).toHaveText("Primary ChatGPT");
    await expect(firstCard.locator("[data-rename-result]")).toBeFocused();

    await firstCard.locator("[data-revoke-connection]").click();
    await expect(firstCard.locator("[data-revoke-confirmation]")).toBeVisible();
    await expect(firstCard.locator("[data-confirm-revoke]")).toBeFocused();
    await firstCard.locator("[data-confirm-revoke]").click();
    await expect(firstCard.locator("[data-revoke-result]")).toContainText("Revocation requested");
    await expect(firstCard).toContainText("Revocation pending");

    await expect(
      page.locator("input[type=password], input[name*='credential'], input[name*='secret']"),
    ).toHaveCount(0);

    const body = await page.locator("body").innerText();
    expect(body).not.toContain("e2e-profile");
    expect(body).not.toContain("worker_profile_ref");
    expect(body).not.toContain("provider_account");
    expect(body).not.toContain("@example.com");
  });

  test("is reachable from Projects and keeps keyboard focus visible", async ({ page }) => {
    await bootstrap(page, "ai_connections", { worker_state: "ready" });
    await openLive(page, "/projects");

    await page.locator("[data-ai-connections-link]").click();
    await expect(page).toHaveURL(/\/ai-connections$/);
    await expect(page.locator("[data-screen=ai-connections]")).toBeVisible();

    await page.locator("#connection-label").focus();
    const ring = await tabTo(page, "#connection-worker");
    expect(ring.style).not.toBe("none");
    expect(ring.width).toBe("2px");
  });

  test("stays within the desktop and mobile viewport", async ({ page }) => {
    await bootstrap(page, "ai_connections", { worker_state: "mixed" });
    await openLive(page, "/ai-connections");

    const viewport = page.viewportSize().width;
    const screen = await page.locator("[data-screen=ai-connections]").boundingBox();

    expect(screen.width).toBeLessThanOrEqual(viewport);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );
  });

  test("has no serious or critical WCAG violations", async ({ page }) => {
    await bootstrap(page, "ai_connections", { worker_state: "ready" });
    await openLive(page, "/ai-connections");

    await expectNoSeriousAxeViolations(page);
  });
});
