// "A link the page renders to a specific LINE of source arrives at that line —
//  the line is on the screen afterwards, and it was not before."
//
// Page-Descriptions.md §13 (an affordance does what it says, or is not
// rendered).
//
// THE REPORT THIS EXISTS FOR
// --------------------------
// Against the live home page: "there is a link 'line 4' that does nothing when
// clicked."
//
// It was the flow rail's link to the loop header, beside "Loop
// iterate_asteroids". The home page's embedded session is narrowed by
// `ssr.featuredSession` with `windowAround(radius = 12)` around the position at
// line 32, so the pane rendered ids `L-src-shield-nr-20` .. `-44`. The rail's
// href was built before that narrowing and still read `#L-src-shield-nr-4`.
// One anchor, twenty-five ids, and no overlap: the browser had nothing to
// scroll to, so the click did nothing at all.
//
// WHY THIS IS A SCROLL MEASUREMENT AND NOT AN `href` CHECK
// -------------------------------------------------------
// "The anchor's target exists in the DOM" is the adjacent question, and it
// passes on pages where the link still does nothing: an id inside a container
// that does not answer fragment navigation is present and unreachable. So the
// claim is asserted as a POSITION — the target's bounding rect is inside the
// viewport after the click — and the reading is taken from the same page twice,
// with and without the fragment, so "it arrived" is a difference between two
// measurements rather than a single number that could be true for free.
//
// THE NON-VACUITY ARM IS THE ONE THAT MATTERS HERE. A line near the top of a
// file is in the viewport whether or not anything scrolled to it, and an
// assertion that only checked the "after" reading would pass on a link that was
// never clicked. The control reading — the destination loaded with NO fragment
// — must find the target OUT of view, and it is asserted, not assumed.
//
// EVERY SCROLLABLE ELEMENT, NOT `window.scrollY`
// ----------------------------------------------
// The code listing is its own scroll container. On the fixed tree the document
// scroll offset does not change by a single pixel when this link is followed —
// `.src` moves from 338 to 73 and the window stays at 0. A measurement written
// against `window.scrollY`, which is the obvious thing to write, reads zero on
// a working link and would have been a gate that fails on the fix and passes on
// the defect. Every element whose `scrollHeight` exceeds its `clientHeight` is
// read, and the assertion is that SOME offset moved.
//
// SCROLL RESTORATION IS TURNED OFF, AND THE START IS STATED
// ---------------------------------------------------------
// A first attempt at this measurement read the home page at scrollTop 29 before
// the click, 0 after, and 633 on a plain reload of the same url — three numbers
// for one page, none of them caused by the link. That is scroll restoration and
// scroll anchoring. Every reading here is taken from a page with
// `history.scrollRestoration = "manual"`, parked at the top and settled across
// two animation frames, so a delta is attributable.

import { visit } from "../lib/probe.mjs";

export const id = "a-link-to-a-line-arrives-at-that-line";
export const claim =
  "A link the page renders to a specific line of source arrives at that line — the line is on the screen afterwards, and it was not before.";
export const spec = "Page-Descriptions.md §13 — BlockTracer";
export const assertions = 9; // eight `expect`s plus the `subjects` count

/**
 * Every scroll offset on the page, plus where the named line is.
 *
 * Runs as ONE evaluate: the pane is replaced on hydration, and a reading that
 * awaited between the scroll offsets and the rect could describe two different
 * documents.
 */
const PROBE = (targetId) => {
  const out = { doc: 0, offsets: [], target: null, url: location.href };
  const se = document.scrollingElement || document.documentElement;
  out.doc = Math.round(se.scrollTop);
  for (const el of document.querySelectorAll("*")) {
    if (el.scrollHeight > el.clientHeight + 2) {
      out.offsets.push(`${el.tagName.toLowerCase()}.${el.className || "?"}=${Math.round(el.scrollTop)}`);
    }
  }
  const t = document.getElementById(targetId);
  if (t) {
    const r = t.getBoundingClientRect();
    out.target = {
      top: Math.round(r.top),
      inViewport: r.top >= 0 && r.bottom <= window.innerHeight,
      text: (t.innerText || "").replace(/\s+/g, " ").trim().slice(0, 60),
    };
  }
  return out;
};

/** Park at the top and let layout settle, so a later delta means something. */
const parkAtTop = async (page) => {
  await page.evaluate(() => {
    try { history.scrollRestoration = "manual"; } catch {}
    const se = document.scrollingElement || document.documentElement;
    se.scrollTop = 0;
    window.scrollTo(0, 0);
  });
  await page.waitForTimeout(400);
  await page.evaluate(
    () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
  );
};

/** Let a fragment jump finish. NOT a navigation wait: a dead link never navigates. */
const settleJump = async (page) => {
  await page.waitForTimeout(1200);
  await page.evaluate(
    () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
  );
};

export async function run({ browser, site, j }) {
  const home = await visit(browser, site.origin, "/");
  let promisedId = null;
  let landedUrl = null;
  let afterClick = null;

  try {
    // The subject: the rail's link to the loop header, as the home page ships
    // it. Read rather than named — the line number and the file are the demo
    // tree's business, and a journey that hard-coded them would stop measuring
    // the product the first time the seed moved.
    const rail = await home.page.evaluate(() => {
      const el = document.querySelector("a.frline");
      if (!el) return { present: false, span: !!document.querySelector("span.frline") };
      return {
        present: true,
        href: el.getAttribute("href"),
        title: el.getAttribute("title") || "",
        text: (el.innerText || "").trim(),
      };
    });

    j.subjects(
      rail.present ? [rail] : [],
      1,
      "links on the home page that name a source line and promise to reach it",
    );

    // The document-level property the defect violated. Asserted over EVERY
    // same-page fragment the page emits, not over the rail's href, because
    // "this one link resolves" is fixable by patching one string and "this
    // document contains a fragment link with no target" is the actual defect.
    const dangling = await home.page.evaluate(() => {
      const bad = [];
      for (const a of document.querySelectorAll('a[href^="#"]')) {
        const id = decodeURIComponent(a.getAttribute("href").slice(1));
        if (id && !document.getElementById(id)) bad.push(id);
      }
      return bad;
    });
    const fragmentCount = await home.page.evaluate(
      () => document.querySelectorAll('a[href^="#"]').length,
    );

    j.expect(
      dangling.length === 0,
      "every same-page fragment link on the home page has a target on the home page",
      dangling.length ? `dangling: ${dangling.join(", ")}` : `${fragmentCount} fragment links, all resolved`,
    );
    j.expect(
      fragmentCount > 0,
      "CONTROL: the home page emits fragment links at all, so the absence above is a measurement",
      `${fragmentCount} anchors with a same-page fragment`,
    );

    // What the link promises: a specific line, named in the link's own text.
    promisedId = rail.present ? decodeURIComponent(String(rail.href).split("#")[1] || "") : "";
    j.expect(
      promisedId.length > 0,
      "the link names the line it goes to, in its href",
      `text "${rail.text}", href "${rail.href}", title "${rail.title}"`,
    );

    await parkAtTop(home.page);
    const before = await home.page.evaluate(PROBE, promisedId);

    await home.page.locator("a.frline").first().click();
    await settleJump(home.page);
    afterClick = await home.page.evaluate(PROBE, promisedId);
    landedUrl = afterClick.url.split("#")[0];

    j.expect(
      afterClick.target !== null,
      "after the click, the promised line is in the document the browser is on",
      afterClick.target
        ? `${promisedId} found: "${afterClick.target.text}"`
        : `${promisedId} is on NO page the click reached — from ${before.url} to ${afterClick.url}`,
    );
    j.expect(
      afterClick.target !== null && afterClick.target.inViewport,
      "and it is inside the viewport — the click arrived somewhere a reader can see",
      afterClick.target ? `rect top ${afterClick.target.top}` : "no such element",
    );
  } finally {
    await home.page.close();
  }

  // THE CONTROL FOR THE JUMP ITSELF. The destination with no fragment, from an
  // identical parked-at-top start. Without this, "the line is in the viewport"
  // could be true because the line is near the top of the file and would have
  // been visible whether or not anything scrolled.
  const destPath = landedUrl ? new URL(landedUrl).pathname : "/";
  const plain = await visit(browser, site.origin, destPath);
  let control = null;
  try {
    await parkAtTop(plain.page);
    control = await plain.page.evaluate(PROBE, promisedId);
  } finally {
    await plain.page.close();
  }

  j.expect(
    control.target !== null && control.target.inViewport === false,
    "CONTROL: on the same page WITHOUT the fragment, that line is off the screen",
    control.target
      ? `rect top ${control.target.top} (viewport starts at 0)`
      : "the line is not on the destination at all — the arm above cannot be a measurement",
  );

  j.expect(
    afterClick !== null &&
      (afterClick.doc !== control.doc ||
        afterClick.offsets.join("|") !== control.offsets.join("|")),
    "a scroll offset MOVED between the two readings — the arrival is a scroll, not a coincidence",
    afterClick
      ? `without: doc=${control.doc} [${control.offsets.join(" ")}] / with: doc=${afterClick.doc} [${afterClick.offsets.join(" ")}]`
      : "no reading was taken",
  );

  j.expect(
    afterClick !== null &&
      control.target !== null &&
      afterClick.target !== null &&
      afterClick.target.top !== control.target.top,
    "and the line itself moved on the screen, by the distance the scroll covered",
    afterClick && afterClick.target && control.target
      ? `top ${control.target.top} -> ${afterClick.target.top}`
      : "one of the two readings found no line",
  );
}
