const { test, expect } = require("@playwright/test");
const {
  bootstrap,
  expectNoSeriousAxeViolations,
  openLive,
  waitConnected,
} = require("./support/harness");

// Browser proof for connecting a hosted local-repository project to a machine
// from the project's own page (specs/37, AC-01, AC-05, AC-06, AC-07).
//
// The seeded project's repository identity is generated from the very folder
// the worker stand-in's picker opens, so the connection here is proved against
// a real Git repository rather than a fixture that only resembles one.
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
    await expect(page.locator("[data-worker-connection-detail]")).toContainText(
      "already saved",
    );

    await page.locator("[data-connect-machine]").click();
    await waitConnected(page);

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
    await page.locator("[data-connect-machine]").click();
    await waitConnected(page);

    await expect(page.locator("[data-worker-connection]")).toHaveAttribute(
      "data-worker-connection",
      "connected",
    );

    const rendered = await page.locator("[data-screen=project-dashboard]").innerText();

    for (const forbidden of ["local-repo:v1:", "/Users/", "macos", "0.0.0-e2e"]) {
      expect(rendered).not.toContain(forbidden);
    }
  });

  test("an unpaired machine is told to install and pair, with no terminal step", async ({
    page,
  }) => {
    const { project_id } = await bootstrap(page, "hosted_local_repository_project", {
      paired: "false",
    });

    await openLive(page, `/projects/${project_id}/overview`);
    await page.locator("[data-connect-machine]").click();
    await waitConnected(page);

    const guidance = page.locator("[data-no-worker-paired]");
    await expect(guidance).toBeVisible();
    await expect(guidance).toContainText("Download the worker for macOS");
    await expect(guidance).toContainText("Open it and enter the pairing code");

    const copy = await guidance.innerText();
    for (const terminal of ["Terminal", "sudo", "brew ", "curl "]) {
      expect(copy).not.toContain(terminal);
    }

    await expect(page.locator("[data-worker-connection]")).toHaveAttribute(
      "data-worker-connection",
      "disconnected",
    );
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

    await page.locator("[data-connect-machine]").click();
    await waitConnected(page);

    await expect(page.locator("[data-worker-connection]")).toHaveAttribute(
      "data-worker-connection",
      "connected",
    );
    await expectNoSeriousAxeViolations(page);
  });
});
