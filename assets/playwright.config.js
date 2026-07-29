// Playwright configuration for SDD Orchestrator end-to-end browser tests.
//
// The web server is the real Phoenix application started through mise so the
// pinned Elixir/Erlang toolchain is used. `reuseExistingServer` lets a developer
// keep `mix phx.server` running locally while iterating on tests.
const { defineConfig, devices } = require("@playwright/test");

const baseURL = process.env.E2E_BASE_URL || "http://localhost:4003";
const serverPort = new URL(baseURL).port || "4003";
const serverEnv = {
  APP_ORIGIN: baseURL,
  DATABASE_NAME: process.env.E2E_DATABASE_NAME || "sdd_orchestrator_dev_slice03",
  E2E_MODE: process.env.E2E_MODE || "false",
  PORT: serverPort,
};

if (process.env.E2E_DEVICE_STORE_PATH) {
  serverEnv.E2E_DEVICE_STORE_PATH = process.env.E2E_DEVICE_STORE_PATH;
}

if (process.env.MIX_BUILD_PATH) {
  serverEnv.MIX_BUILD_PATH = process.env.MIX_BUILD_PATH;
}

module.exports = defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL,
    trace: "on-first-retry",
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "mobile-chromium", use: { ...devices["Pixel 7"] } },
  ],
  webServer: {
    command: "mise exec -- mix do ecto.create + ecto.migrate + assets.deploy + phx.server",
    cwd: "..",
    url: baseURL,
    reuseExistingServer: !process.env.CI && process.env.E2E_ISOLATED_RUN !== "true",
    timeout: 120_000,
    env: serverEnv,
  },
});
