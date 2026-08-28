// Everything that makes a capture reproducible.
//
// VD.0 asks for "deterministic capture: fixed fixture data, frozen clock,
// disabled animation, stable fonts". Each of those is one section below, and
// each names what it is defending against — a flag whose reason has been lost
// is a flag that gets removed the next time it is inconvenient.
//
// FIXED FIXTURE DATA is not here: it is upstream. The demo generator is a pure
// function of its seed (src/blocktracer/demo/generator.nim) and the exporter
// rebuilds `dist/` byte-identically from it, so the bytes the browser is
// handed are already fixed before this module runs. `capture.mjs` records the
// digest of the served tree in the manifest so a changed fixture is visible as
// a fixture change rather than as a mysterious hash drift.

import { FROZEN_TIME, RANDOM_SEED } from "../views.mjs";

// ── Renderer flags ─────────────────────────────────────────────────────────
// Pinned so the raster output depends on the page, not on the host's GPU,
// display scaling, colour profile or font-hinting configuration.

export const CHROMIUM_ARGS = [
  // Geometry: a 2x capture is a different rasterisation path entirely.
  "--force-device-scale-factor=1",
  // Scrollbars are drawn by the platform theme and differ per OS.
  "--hide-scrollbars",
  // Colour: without this, output depends on the attached display's profile.
  "--force-color-profile=srgb",
  // Text: hinting, subpixel positioning and LCD filtering are all host- and
  // fontconfig-dependent, and all three move glyph pixels.
  "--font-render-hinting=none",
  "--disable-font-subpixel-positioning",
  "--disable-lcd-text",
  // Raster: keep it off the GPU and off any runtime-detected SIMD path, so the
  // same bytes come out on a machine with a different CPU feature set.
  "--disable-gpu",
  "--disable-partial-raster",
  "--disable-skia-runtime-opts",
  "--disable-checker-imaging",
  // Timing: anything that can render a partial frame can render a different
  // partial frame.
  "--disable-threaded-animation",
  "--disable-threaded-scrolling",
  "--disable-image-animation-resync",
  "--disable-new-content-rendering-timeout",
  "--disable-background-timer-throttling",
  "--disable-backgrounding-occluded-windows",
  "--disable-renderer-backgrounding",
  "--disable-ipc-flooding-protection",
  // Features that introduce their own timing or defer work.
  "--disable-features=PaintHolding,LazyFrameLoading,LazyImageLoading,BackForwardCache,Translate,AcceptCHFrame,AutoExpandDetailsElement",
  // Deterministic JS engine seed, for anything that reaches for randomness
  // before our init script can shadow Math.random.
  `--js-flags=--random-seed=${RANDOM_SEED}`,
  // Container hygiene: /dev/shm is small in Docker's default config, and a
  // renderer that runs out of it crashes non-deterministically.
  "--disable-dev-shm-usage",
  "--no-first-run",
  "--no-default-browser-check",
  "--mute-audio",
];

// ── Context options ────────────────────────────────────────────────────────

export function contextOptions({ size, theme }) {
  return {
    viewport: { width: size.width, height: size.height },
    deviceScaleFactor: size.deviceScaleFactor,
    // The theme axis. Both signals are set: the media query here, and the
    // explicit attribute in the init script below.
    colorScheme: theme,
    // Motion tokens must honour reduced-motion (VD.9); capturing with it on
    // also removes an entire class of frame-timing nondeterminism.
    reducedMotion: "reduce",
    forcedColors: "none",
    // Locale and timezone reach number formatting, date formatting and
    // sometimes font fallback.
    locale: "en-US",
    timezoneId: "UTC",
    // A fixed UA string, so anything that branches on it branches the same way.
    bypassCSP: false,
  };
}

// ── Init scripts, injected before any page script runs ─────────────────────

const SEEDED_RANDOM = (seed) => `
(() => {
  // xorshift32 — the same sequence on every run, so any incidental randomness
  // in the page (generated ids, shuffles) is reproducible.
  let s = ${seed} >>> 0 || 1;
  Math.random = () => {
    s ^= s << 13; s >>>= 0;
    s ^= s >> 17;
    s ^= s << 5;  s >>>= 0;
    return s / 4294967296;
  };
})();
`;

const THEME_SCRIPT = (theme) => `
(() => {
  const apply = () => {
    const el = document.documentElement;
    if (!el) return;
    // Page-Descriptions §13: dark and light via prefers-color-scheme WITH a
    // toggle. The media query is emulated by the browser context; this is the
    // toggle's own signal, so a page that reads either one agrees with the
    // filename the image is written under.
    el.setAttribute('data-theme', ${JSON.stringify(theme)});
    el.style.colorScheme = ${JSON.stringify(theme)};
  };
  apply();
  document.addEventListener('DOMContentLoaded', apply);
})();
`;

// Disabled animation. Playwright's screenshot(animations:'disabled') stops CSS
// animations at their first frame, but it does not stop transitions that a
// script kicks off, smooth scrolling, or a blinking caret — and each of those
// is a per-run coin flip in a screenshot.
const NO_MOTION_CSS = `
*, *::before, *::after {
  animation-delay: -1ms !important;
  animation-duration: 1ms !important;
  animation-iteration-count: 1 !important;
  transition-duration: 0ms !important;
  transition-delay: 0ms !important;
  scroll-behavior: auto !important;
  caret-color: transparent !important;
}
html { scroll-behavior: auto !important; }
`;

const NO_MOTION_SCRIPT = `
(() => {
  const css = ${JSON.stringify(NO_MOTION_CSS)};
  const inject = () => {
    if (!document.head || document.getElementById('vd0-no-motion')) return;
    const s = document.createElement('style');
    s.id = 'vd0-no-motion';
    s.textContent = css;
    document.head.appendChild(s);
  };
  inject();
  document.addEventListener('DOMContentLoaded', inject);
  new MutationObserver(inject).observe(document.documentElement, { childList: true, subtree: true });
})();
`;

export async function prepareContext(context, { theme }) {
  // Frozen clock. Installed on the context before any navigation, so the very
  // first script the page runs already sees the fixed instant. `install` leaves
  // the clock paused; the capture advances it by a fixed budget after load, so
  // timer-driven work completes the same way every run instead of racing the
  // screenshot.
  await context.clock.install({ time: FROZEN_TIME });

  await context.addInitScript(SEEDED_RANDOM(RANDOM_SEED));
  await context.addInitScript(THEME_SCRIPT(theme));
  await context.addInitScript(NO_MOTION_SCRIPT);
}

/** The fixed budget of page-time the clock is advanced by after load. */
export const SETTLE_BUDGET_MS = 2000;

export async function settlePage(page, { timeoutMs = 15000 } = {}) {
  await page.waitForLoadState("domcontentloaded", { timeout: timeoutMs });
  await page.waitForLoadState("load", { timeout: timeoutMs }).catch(() => {});

  // Stable fonts: do not screenshot mid-swap. The site serves its brand faces
  // from its own origin, so this resolves without a network race, but a
  // capture taken before it resolves shows the fallback stack instead.
  await page
    .evaluate(() => document.fonts.ready.then(() => undefined))
    .catch(() => {});

  // Advance the frozen clock by a fixed budget. Deterministic by construction:
  // the same number of milliseconds of page-time on every run, rather than
  // "however long the machine took".
  await page.context().clock.runFor(SETTLE_BUDGET_MS).catch(() => {});

  // Fonts again — the settle budget can have started a second face loading.
  await page
    .evaluate(() => document.fonts.ready.then(() => undefined))
    .catch(() => {});

  // Nothing in the corpus should still be in flight; tolerate the cases where
  // something long-polling keeps the network non-idle.
  await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});

  // Full-page screenshots stitch from the top; make sure that is where we are.
  await page.evaluate(() => window.scrollTo(0, 0)).catch(() => {});
}
