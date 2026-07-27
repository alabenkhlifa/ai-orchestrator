const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;

function uniqueEmail(prefix) {
  return `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}@example.com`;
}

async function deliveredLinks(page, email) {
  const response = await page.request.get("/dev/mailbox/json");
  expect(response.ok()).toBeTruthy();

  const mailbox = await response.json();

  return mailbox.data
    .filter((message) => message.to.some((recipient) => recipient.includes(email)))
    .map((message) => message.text_body.match(/https?:\/\/\S+/)?.[0])
    .filter(Boolean);
}

async function waitForDeliveredLinks(page, email, count) {
  await expect
    .poll(async () => (await deliveredLinks(page, email)).length, {
      message: `expected ${count} delivered link(s) for ${email}`,
    })
    .toBeGreaterThanOrEqual(count);

  return deliveredLinks(page, email);
}

test.describe("hosted passwordless access", () => {
  test("explains the access and recovery boundary with keyboard and accessible behavior", async ({
    page,
  }) => {
    await page.goto("/");
    await page.getByRole("link", { name: /Use verified email/i }).click();

    await expect(page).toHaveURL(/\/hosted\/access/);
    await expect(
      page.getByRole("heading", { name: /Verify your email to continue/i }),
    ).toBeVisible();
    await expect(page.getByText(/linked beforehand/i)).toBeVisible();
    await expect(page.getByText(/Support can’t bypass/i)).toBeVisible();

    const emailInput = page.getByLabel("Email address");
    await expect(emailInput).toBeFocused();

    await emailInput.fill(uniqueEmail("neutral"));
    await page.getByRole("button", { name: /Send sign-in link/i }).click();

    await expect(page.getByRole("heading", { name: /Check your email/i })).toBeFocused();
    await expect(page.getByText(/If the address can receive email/i)).toBeVisible();
    await expect(page.getByRole("button", { name: /Resend email/i })).toBeVisible();

    const serious = (
      await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa"]).analyze()
    ).violations.filter((violation) => ["serious", "critical"].includes(violation.impact));

    expect(
      serious,
      serious.map((violation) => `${violation.id}: ${violation.help}`).join("\n"),
    ).toEqual([]);

    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    ).toBe(true);
  });

  test("resend invalidates the old link and the newest link survives browser restart", async ({
    page,
  }) => {
    const email = uniqueEmail("complete");

    await page.goto("/hosted/access?return_to=/onboarding/local");
    await page.getByLabel("Email address").fill(email);
    await page.getByRole("button", { name: /Send sign-in link/i }).click();

    const [firstLink] = await waitForDeliveredLinks(page, email, 1);

    await page.getByRole("button", { name: /Resend email/i }).click();
    await expect(page.getByText(/another sign-in link is on its way/i)).toBeVisible();

    const links = await waitForDeliveredLinks(page, email, 2);
    const newestLink = links.find((link) => link !== firstLink);
    expect(newestLink).toBeTruthy();

    await page.goto(firstLink);
    await expect(
      page.getByRole("heading", { name: /sign-in link is no longer available/i }),
    ).toBeVisible();

    await page.goto(newestLink);
    await expect(page.getByRole("heading", { name: /Email verified/i })).toBeVisible();
    await expect(page.getByRole("link", { name: /^Continue$/i })).toHaveAttribute(
      "href",
      "/onboarding/local",
    );

    await page.getByRole("link", { name: /Manage active sessions/i }).click();
    await expect(page.getByRole("heading", { name: /Active sessions/i })).toBeVisible();
    await expect(page.getByText(/Current device/i)).toBeVisible();
    await expect(page.getByText(/no IP address or fingerprint/i)).toBeVisible();

    const context = page.context();
    await page.close();
    const reopened = await context.newPage();

    await reopened.goto("/hosted/access/sessions");
    await expect(reopened.getByRole("heading", { name: /Active sessions/i })).toBeVisible();
    await expect(reopened.getByText(/Current device/i)).toBeVisible();

    await reopened.getByRole("link", { name: /Sign out this device/i }).click();
    await expect(reopened).toHaveURL(/hosted_access=signed_out/);
    await expect(reopened.getByText(/This device has been signed out/i)).toBeVisible();

    await reopened.goto("/hosted/access/sessions");
    await expect(reopened).toHaveURL(/hosted_access=required/);
  });

  test("invalid verification returns the same safe failure without opening hosted access", async ({
    page,
  }) => {
    await page.goto("/hosted/access/verify?attempt=invalid&token=invalid");

    await expect(
      page.getByRole("heading", { name: /sign-in link is no longer available/i }),
    ).toBeVisible();
    await expect(page.getByRole("alert")).toContainText(/No hosted\s+access was opened/i);
    await expect(page.getByRole("link", { name: /Request a new link/i })).toBeVisible();
  });
});
