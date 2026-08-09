const { test, expect } = require("@playwright/test");
const { bootstrap, expectNoSeriousAxeViolations, openLive } = require("./support/harness");

// Focused browser proof for Slice 30 Task 12. The same scenario runs in the
// desktop and mobile Playwright projects. The pilot screen also shows
// read-only repository readiness: four independent axes derived from the
// approved execution profile, the selected pilot, and the project's latest
// completed assessment. The `repository_pilot` scenario seeds a profile whose
// evidence carries an unresolved conflict, which is exactly what proves
// agent execution can be blocked while release stays ready under the same
// profile — the axes are independent rather than a strict ladder.
test.describe("repository readiness", () => {
  test("the owner sees independent readiness axes before and after selecting the pilot", async ({
    page,
  }) => {
    const { project_id, specification_id, revision_id } = await bootstrap(
      page,
      "repository_pilot",
    );
    await openLive(page, `/projects/${project_id}/pilot`);

    const section = page.locator("[data-readiness-section]");
    await expect(section).toBeVisible();

    const assistant = page.locator('[data-readiness-axis="assistant"]');
    const specification = page.locator('[data-readiness-axis="specification"]');
    const agentExecution = page.locator('[data-readiness-axis="agent-execution"]');
    const release = page.locator('[data-readiness-axis="release"]');

    // No pilot is selected yet. The profile was approved, so the assistant
    // axis reads ready, but nothing downstream of the missing pilot can be
    // evaluated: specification, agent execution, and release all cascade the
    // same `no_pilot_selected` reason.
    await expect(assistant).toHaveAttribute("data-readiness-assistant", "ready");
    await expect(specification).toHaveAttribute("data-readiness-specification", "blocked");
    await expect(specification).toHaveAttribute(
      "data-readiness-specification-reason",
      "no_pilot_selected",
    );
    await expect(agentExecution).toHaveAttribute("data-readiness-agent-execution", "blocked");
    await expect(agentExecution).toHaveAttribute(
      "data-readiness-agent-execution-reason",
      "no_pilot_selected",
    );
    await expect(release).toHaveAttribute("data-readiness-release", "blocked");
    await expect(release).toHaveAttribute("data-readiness-release-reason", "no_pilot_selected");

    const viewport = page.viewportSize().width;
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(
      viewport,
    );

    await page.locator(`[data-selectable-specification="${specification_id}"]`).waitFor();
    await page.locator("[data-select-pilot]").click();
    await expect(page.locator("[data-pilot-field=revision]")).toContainText(revision_id);

    // The pilot is selected now, so specification is ready. The approved
    // profile's own evidence conflict blocks agent execution specifically —
    // and release, which is blocked only by an unreliable required-check
    // contract, stays ready under that same profile.
    await expect(assistant).toHaveAttribute("data-readiness-assistant", "ready");
    await expect(specification).toHaveAttribute("data-readiness-specification", "ready");
    await expect(agentExecution).toHaveAttribute("data-readiness-agent-execution", "blocked");
    await expect(agentExecution).toHaveAttribute(
      "data-readiness-agent-execution-reason",
      "unresolved_evidence_conflict",
    );
    await expect(release).toHaveAttribute("data-readiness-release", "ready");

    await expectNoSeriousAxeViolations(page);
  });
});
