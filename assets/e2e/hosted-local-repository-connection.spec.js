const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  openLive,
  waitConnected,
} = require("./support/harness");

// Browser proof for connecting a hosted local-repository project to a machine
// from the project's own page (specs/37, AC-01, AC-04, AC-06, AC-07).
//
// The seeded project's repository identity is generated from the very folder
// the worker stand-in's picker opens, so the connection here is proved against
// a real Git repository rather than a fixture that only resembles one.
//
// One machine is paired for this scenario, but the device workspace is this
// machine's own and is shared with every other browser scenario that pairs a
// worker. So the owner may legitimately be asked which machine to use — that is
// AC-04 working, not a failure — and `connectThisMachine` handles both shapes.
// For the same reason the no-worker-paired result (AC-05) is not provable here:
// it cannot be isolated without revoking workers other scenarios still rely on.
// It is proved instead at the page level, against rendered markup, in
// `test/sdd_orchestrator_web/live/project_connect_machine_live_test.exs`.
const SETTLED = "[data-choose-machine], [data-worker-connection=connected], [data-connect-error]";

async function connectThisMachine(page) {
  await page.locator("[data-connect-machine]").click();

  // Wait for the click's own re-render, not merely for the socket: the machine
  // chooser appears a round trip later, and checking before it lands would read
  // as "no choice offered" and silently skip the selection.
  await page.waitForSelector(SETTLED);

  if (await page.locator("[data-choose-machine]").isVisible()) {
    await page.locator("[data-machine-option]", { hasText: "(ready)" }).first().click();
    await page.waitForSelector("[data-worker-connection=connected], [data-connect-error]");
  }
}

test.describe("hosted local repository connection", () => {
  test("an owner connects this machine and then disconnects it", async ({ page }) => {
    const { project_id } = await bootstrap(page, "hosted_local_repository_project");

    await openLive(page, `/projects/${project_id}/overview`);

    const region = page.locator("[data-worker-connection]");
    await expect(region).toHaveAttribute("data-worker-connection", "disconnected");
    await expect(page.locator("[data-worker-connection-title]")).toHaveText(
      /No machine connected yet/,
    );

    // Not connected must never read as a missing or broken project.
    await expect(page.locator("[data-worker-connection-detail]")).toContainText("already saved");

    await connectThisMachine(page);

    await expect(region).toHaveAttribute("data-worker-connection", "connected");
    await expect(page.locator("[data-connect-error]")).toHaveCount(0);
    await expect(page.locator("[data-disconnect-machine]")).toBeVisible();

    await page.locator("[data-disconnect-machine]").click();
    await waitConnected(page);

    await expect(region).toHaveAttribute("data-worker-connection", "disconnected");
    await expect(page.locator("[data-disconnect-machine]")).toHaveCount(0);
  });

  test("no repository path, identity, or worker detail is ever rendered", async ({ page }) => {
    const { project_id } = await bootstrap(page, "hosted_local_repository_project");

    await openLive(page, `/projects/${project_id}/overview`);
    await connectThisMachine(page);

    await expect(page.locator("[data-worker-connection]")).toHaveAttribute(
      "data-worker-connection",
      "connected",
    );

    const rendered = await page.locator("[data-screen=project-dashboard]").innerText();

    for (const forbidden of ["local-repo:v1:", "/Users/", "macos", "0.0.0-e2e"]) {
      expect(rendered).not.toContain(forbidden);
    }
  });

  test("a GitHub-backed project shows no machine connection region", async ({ page }) => {
    const { project_id } = await bootstrap(page, "project_owner");

    await openLive(page, `/projects/${project_id}/overview`);

    await expect(page.locator("[data-screen=project-dashboard]")).toBeVisible();
    await expect(page.locator("[data-worker-connection]")).toHaveCount(0);
    await expect(page.locator("[data-connect-machine]")).toHaveCount(0);
  });

  test("the connection region is accessible in both states", async ({ page }) => {
    const { project_id } = await bootstrap(page, "hosted_local_repository_project");

    await openLive(page, `/projects/${project_id}/overview`);
    await expectNoSeriousAxeViolations(page);

    await connectThisMachine(page);

    await expect(page.locator("[data-worker-connection]")).toHaveAttribute(
      "data-worker-connection",
      "connected",
    );
    await expectNoSeriousAxeViolations(page);
  });
});
