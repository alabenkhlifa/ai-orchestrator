const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const playwrightCli = path.join(
  path.dirname(require.resolve("@playwright/test/package.json")),
  "cli.js",
);
const requestedBaseURL = new URL(process.env.E2E_BASE_URL || "http://localhost:4003");
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "sdd-orchestrator-e2e-"));
const isolatedBuildPath = path.resolve(__dirname, "../_build/e2e");

const runs = [
  {
    project: "chromium",
    baseURL: requestedBaseURL,
    database: "sdd_orchestrator_e2e_desktop",
  },
  {
    project: "mobile-chromium",
    baseURL: mobileBaseURL(requestedBaseURL),
    database: "sdd_orchestrator_e2e_mobile",
  },
];

let exitCode = 0;

try {
  for (const [index, run] of runs.entries()) {
    const result = spawnSync(
      process.execPath,
      [playwrightCli, "test", `--project=${run.project}`],
      {
        cwd: __dirname,
        env: {
          ...process.env,
          E2E_BASE_URL: run.baseURL.toString().replace(/\/$/, ""),
          E2E_DATABASE_NAME: run.database,
          E2E_DEVICE_STORE_PATH: path.join(temporaryRoot, `${index}-${run.project}.dets`),
          E2E_ISOLATED_RUN: "true",
          E2E_MODE: "true",
          MIX_BUILD_PATH: isolatedBuildPath,
        },
        stdio: "inherit",
      },
    );

    if (result.status !== 0) {
      exitCode = result.status || 1;
      break;
    }
  }
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}

process.exit(exitCode);

function mobileBaseURL(desktopBaseURL) {
  if (process.env.E2E_MOBILE_BASE_URL) {
    return new URL(process.env.E2E_MOBILE_BASE_URL);
  }

  const mobile = new URL(desktopBaseURL);
  const desktopPort = Number(
    desktopBaseURL.port || (desktopBaseURL.protocol === "https:" ? 443 : 80),
  );
  mobile.port = String(desktopPort + 1);
  return mobile;
}
