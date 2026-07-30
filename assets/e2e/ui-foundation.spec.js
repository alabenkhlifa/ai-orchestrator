const { test, expect } = require("@playwright/test");
const AxeBuilder = require("@axe-core/playwright").default;
const { tabTo } = require("./support/harness");

// Browser proof for the shared presentation foundation (Task 2). Runs against
// the design-system preview at /_ui, which renders every shared primitive.
const PREVIEW = "/_ui";
const THEME_KEY = "sdd:theme";

// Hosts that would indicate an external font, icon, or analytics request. The
// application must serve every optional asset locally.
const EXTERNAL_HOST_RE =
  /fonts\.googleapis\.com|fonts\.gstatic\.com|googletagmanager|google-analytics|analytics|cdn\.jsdelivr\.net|unpkg\.com|cdnjs/i;

async function dataTheme(page) {
  return page.evaluate(() => document.documentElement.getAttribute("data-theme"));
}
async function themeSource(page) {
  return page.evaluate(() => document.documentElement.getAttribute("data-theme-source"));
}
async function canvasColor(page) {
  return page.evaluate(() => getComputedStyle(document.body).backgroundColor);
}

test.describe("shared presentation foundation", () => {
  test("issues no external font, icon, or analytics request", async ({ page }) => {
    const external = [];
    page.on("request", (req) => {
      const url = req.url();
      if (!url.startsWith("data:") && EXTERNAL_HOST_RE.test(url)) external.push(url);
    });

    await page.goto(PREVIEW);
    await page.waitForLoadState("networkidle");

    expect(external, `unexpected external requests: ${external.join(", ")}`).toEqual([]);
  });

  test("renders text in the self-hosted Public Sans face", async ({ page }) => {
    await page.goto(PREVIEW);
    const fontFamily = await page.evaluate(() => getComputedStyle(document.body).fontFamily);
    expect(fontFamily).toContain("Public Sans");
  });

  test("uses the OS preference when the device has no stored choice", async ({ page }) => {
    await page.emulateMedia({ colorScheme: "dark" });
    await page.goto(PREVIEW);
    await page.evaluate((k) => localStorage.removeItem(k), THEME_KEY);
    await page.reload();
    expect(await dataTheme(page)).toBe("dark");
    expect(await themeSource(page)).toBe("system");

    await page.emulateMedia({ colorScheme: "light" });
    await page.reload();
    expect(await dataTheme(page)).toBe("light");
    expect(await themeSource(page)).toBe("system");
  });

  test("a manual choice is device-local and persists across reloads", async ({ page }) => {
    await page.emulateMedia({ colorScheme: "light" });
    await page.goto(PREVIEW);
    await page.evaluate((k) => localStorage.removeItem(k), THEME_KEY);
    await page.reload();

    const lightCanvas = await canvasColor(page);

    // Toggle to an explicit choice (opposite of the current light theme).
    await page.locator("#theme-toggle").click();
    expect(await dataTheme(page)).toBe("dark");
    expect(await themeSource(page)).toBe("user");
    expect(await page.evaluate((k) => localStorage.getItem(k), THEME_KEY)).toBe("dark");

    const darkCanvas = await canvasColor(page);
    expect(darkCanvas).not.toBe(lightCanvas); // theme actually changed the surface

    // The explicit choice survives a reload without any server round-trip.
    await page.reload();
    expect(await dataTheme(page)).toBe("dark");
    expect(await themeSource(page)).toBe("user");

    // Clearing the device store returns to following the OS preference.
    await page.evaluate((k) => localStorage.removeItem(k), THEME_KEY);
    await page.reload();
    expect(await dataTheme(page)).toBe("light");
    expect(await themeSource(page)).toBe("system");
  });

  test("keyboard focus is visible", async ({ page }) => {
    await page.goto(PREVIEW);
    await page.keyboard.press("Tab");

    const focus = await page.evaluate(() => {
      const el = document.activeElement;
      const s = getComputedStyle(el);
      return { tag: el.tagName, outlineStyle: s.outlineStyle, outlineWidth: s.outlineWidth };
    });

    expect(focus.outlineStyle).not.toBe("none");
    expect(parseFloat(focus.outlineWidth)).toBeGreaterThan(0);
  });

  // A text field suppresses the browser's own ring and draws the approved one
  // instead, and the two utilities that do that share a Tailwind custom
  // property: the suppression sets `--tw-outline-style` and the width utility
  // reads it. A class list naming a 2px ring can therefore compute to
  // `outline-style: none` and paint nothing at all, which is exactly what
  // shipped. Only the values the browser computed for a really-focused field
  // distinguish the two, so this test tabs there and reads them.
  for (const field of ["#f-ok", "#f-err"]) {
    test(`a keyboard-focused text field paints its ring (${field})`, async ({ page }) => {
      await page.goto(PREVIEW);

      // `tabTo` throws unless the field itself holds focus, so this really is
      // the ring a keyboard user sees on that input.
      const ring = await tabTo(page, field);

      expect(ring.style).not.toBe("none");
      expect(ring.style).toBe("solid");
      expect(ring.width).toBe("2px");
      expect(ring.offset).toBe("0px");
      expect(ring.color).not.toBe("rgba(0, 0, 0, 0)");
      expect(ring.color).not.toBe("transparent");
    });
  }

  test("status meaning never depends on color alone", async ({ page }) => {
    await page.goto(PREVIEW);
    const badges = page.locator("section[aria-labelledby='s-status'] span.rounded-full");
    const count = await badges.count();
    expect(count).toBeGreaterThan(0);

    for (let i = 0; i < count; i++) {
      const badge = badges.nth(i);
      await expect(badge.locator("svg")).toHaveCount(1); // icon cue
      expect((await badge.innerText()).trim().length).toBeGreaterThan(0); // text cue
    }
  });

  test("layout fits without horizontal overflow on mobile and desktop", async ({ page }) => {
    for (const size of [
      { width: 375, height: 800 },
      { width: 1280, height: 900 },
    ]) {
      await page.setViewportSize(size);
      await page.goto(PREVIEW);
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      );
      expect(overflow, `horizontal overflow at ${size.width}px`).toBeLessThanOrEqual(1);
    }
  });

  for (const colorScheme of ["light", "dark"]) {
    test(`has no serious accessibility violations (${colorScheme})`, async ({ page }) => {
      await page.emulateMedia({ colorScheme });
      await page.goto(PREVIEW);
      await page.evaluate((k) => localStorage.removeItem(k), THEME_KEY);
      await page.reload();

      const results = await new AxeBuilder({ page })
        .withTags(["wcag2a", "wcag2aa"])
        .analyze();

      const serious = results.violations.filter((v) =>
        ["serious", "critical"].includes(v.impact),
      );
      expect(
        serious,
        serious.map((v) => `${v.id}: ${v.help}`).join("\n"),
      ).toEqual([]);
    });
  }
});
