// "A visitor chooses a keyboard preset on /settings, and the keys that step a
//  trace change to match — on a different page, in a later navigation."
//
// `Configuration.md` §4 (`bt.ui.keymap` in `localStorage`); `Page-Descriptions`
// §13, the standing rule that this product does not ship a control that cannot
// succeed.
//
// WHY THIS JOURNEY EXISTS SEPARATELY FROM JOURNEY 20
// --------------------------------------------------
// Journey 20 proves the DEFAULT preset's chord steps the session, and that the
// debug route's own dialog lists what is bound. Both of its claims are true of
// a build in which the preset can never be changed — and that build is exactly
// what shipped: the chooser existed only inside a dialog on the debug route,
// and `/settings` was a page of prose with no control on it at all. A reader
// who went looking for their keyboard settings found four paragraphs.
//
// So the claim here is the one journey 20 cannot make: that the CHOICE is a
// control, that it CROSSES A PAGE BOUNDARY, and that what changes is what the
// keyboard does rather than what a page says.
//
// THE TRAP THIS JOURNEY IS WRITTEN AGAINST
// ----------------------------------------
// Asserting that the preference was WRITTEN. `localStorage.getItem("bt.ui")`
// after a click is trivially green over a build where nothing reads the value
// back, and it is the exact shape of claim this whole campaign keeps finding:
// a feature that is real at the layer being measured and absent at the layer
// being used. The brief for this work put it plainly — "not that a handler
// fired, not that state was written — press the key and observe the action."
//
// So the storage read is a CONTROL, never a verdict. The verdict is taken the
// way journey 03 and journey 20 take theirs: from the position the session
// reports and the line the pane marks, after a key press.
//
// AND THE NEGATIVE IS WHAT MAKES IT A REBINDING RATHER THAN AN ADDITION
// ---------------------------------------------------------------------
// A build that bound the new preset's chords WITHOUT UNBINDING the old ones
// would pass every positive assertion below. The letters preset's `n` and the
// VS Code preset's `F10` would both step, the reader would be none the wiser,
// and the "preset" would be an accumulating union rather than a choice.
//
// That is not a hypothetical failure mode for this codebase: `keymap.actionFor`
// walks `km.bindings`, and a `bindShortcuts` that added a listener per chosen
// preset instead of replacing the keymap would produce precisely it. So after
// choosing VS Code, `n` is pressed and asserted to move NOTHING — guarded by a
// control that proves the page was still live and still steppable at that
// moment, so a green cannot be a dead page.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-preset-chosen-on-settings-rebinds-the-keys";
export const claim =
  "Choosing a keyboard preset on /settings changes which keys step a trace on the debug route.";
export const spec = "Configuration.md §4; Page-Descriptions.md §13 — BlockTracer";
export const assertions = 16;
export const needsEngine = true;

const CHOOSER = "[data-kb-chooser]";

/**
 * Press a key and wait for ANY of the three things a step could move.
 *
 * A predicate, never a sleep — journey 03's rule. Returns the facts as they
 * settled, so both a move and a NON-move are read the same way and a negative
 * assertion cannot be a race this suite happened to win.
 */
async function pressAndSettle(page, key, before, budgetMs) {
  await page.keyboard.press(key);
  const deadline = Date.now() + budgetMs;
  let after = before;
  while (Date.now() < deadline) {
    after = await readFacts(page);
    if (
      after.urlQuery !== before.urlQuery ||
      after.step !== before.step ||
      after.markedNumber !== before.markedNumber
    )
      break;
    await page.waitForTimeout(200);
  }
  return after;
}

const moved = (a, b) =>
  a.urlQuery !== b.urlQuery || a.step !== b.step || a.markedNumber !== b.markedNumber;

/** What /settings says about itself, read out of the rendered DOM. */
async function readSettings(page) {
  return page.evaluate((chooserSel) => {
    const chooser = document.querySelector(chooserSel);
    const panels = [...document.querySelectorAll("[data-kb-panel]")];
    // COMPUTED VISIBILITY, NOT `hasAttribute("hidden")`.
    //
    // The attribute version of this line was green over a build in which all
    // eight panels were on screen at once. `hidden` hides through the UA rule
    // `[hidden]{display:none}` — specificity (0,1,0) — and a single class
    // selector in the site stylesheet ties it and wins on order, which is
    // exactly what `.kbpanel{display:block}` did. The markup was right, the
    // attribute was right, the Nim suite agreed, and the page showed four
    // contradictory lists.
    //
    // So this asks the browser what it PAINTED. A journey that reads the cause
    // instead of the effect is the same defect as a page that describes a
    // feature instead of providing it.
    const shown = panels.filter(
      (p) => window.getComputedStyle(p).display !== "none" && p.offsetParent !== null,
    );
    return {
      present: !!chooser,
      // `hidden` present means the bundle has not run — the served state.
      live: chooser ? !chooser.hasAttribute("hidden") : false,
      presets: [...document.querySelectorAll('input[data-kb="preset"]')].map((i) => i.value),
      checked:
        [...document.querySelectorAll('input[data-kb="preset"]')]
          .filter((i) => i.checked)
          .map((i) => i.value)[0] ?? null,
      panels: panels.length,
      // Exactly one preset's rows may be visible; two would be the page
      // disagreeing with itself about what is bound.
      shownPanels: shown.length,
      shownPreset: shown[0]?.getAttribute("data-kb-panel") ?? null,
      // The chords the VISIBLE panel spells, keyed by the move they belong to.
      shownChords: Object.fromEntries(
        [...(shown[0]?.querySelectorAll(".kbrow[data-kb-action]") ?? [])].map((r) => [
          r.getAttribute("data-kb-action"),
          r.querySelector(".kbchord")?.textContent?.trim() ?? "",
        ]),
      ),
      // The other two registries, which are the same under every preset and
      // must be listed whichever one is chosen.
      scrubRows: document.querySelectorAll("[data-kb-scrub]").length,
      hardRows: document.querySelectorAll("[data-kb-hard]").length,
    };
  }, CHOOSER);
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  const subject = withSession[0];
  j.note(`driving /settings then ${subject.debugPath}`);

  // ── THE SERVED SETTINGS PAGE OFFERS NO LIVE CONTROL ───────────────────
  //
  // Asserted first, and it is the same rule journey 20 asserts about the gear:
  // the chooser is served `hidden` and the bundle unhides it, so a reader with
  // no script is never given a radio that stores nothing. The ROWS, by
  // contrast, must be there without script — they are the honest answer to
  // "what is bound", and a crawler and a script-less reader both get them.
  const noJs = await browser.newContext({ javaScriptEnabled: false });
  try {
    const p = await noJs.newPage();
    await p.goto(site.origin + "/settings", { waitUntil: "load", timeout: 45000 });
    const served = await readSettings(p);
    j.expect(
      served.present && !served.live,
      "the script-less settings page carries the chooser but does not offer it as a control",
      `present=${served.present} live=${served.live}`,
    );
    j.atLeast(served.panels, 2, "SUBJECTS: preset panels served in the bytes");
    j.countIs(
      served.shownPanels,
      1,
      `exactly one preset's rows are visible without script (showing ${served.shownPreset})`,
    );
    // The list is complete in the served bytes, not filled in later.
    j.atLeast(served.scrubRows, 1, "the timeline's keys are listed without script");
    j.atLeast(served.hardRows, 1, "the always-active keys are listed without script");
  } finally {
    await noJs.close();
  }

  // ── THE CHOOSER BECOMES A CONTROL WHEN THE BUNDLE RUNS ────────────────
  const ctx = await browser.newContext();
  try {
    const sp = await ctx.newPage();
    await sp.goto(site.origin + "/settings", { waitUntil: "load", timeout: 45000 });
    await sp.waitForSelector(`${CHOOSER}:not([hidden])`, { timeout: 15000 });
    const live = await readSettings(sp);
    j.expect(
      live.live,
      "the bundle turned the served chooser into a control a reader can operate",
      `chooser live=${live.live}, presets=${live.presets.join(",")}`,
    );

    // The preset to switch TO is chosen from what the page OFFERS, not written
    // here as a literal: a build that renamed or dropped a preset must fail by
    // finding nothing to select rather than by disagreeing with this file.
    const target = live.presets.find((v) => v !== live.checked && v !== "none");
    j.expect(
      !!target,
      "the page offers a preset other than the active one and other than `none`",
      `active=${live.checked} offered=${live.presets.join(",")}`,
    );

    const beforeChords = live.shownChords;
    await sp.click(`input[data-kb="preset"][value="${target}"]`);
    await sp.waitForTimeout(300);
    const after = await readSettings(sp);

    j.expect(
      after.shownPreset === target,
      "choosing a preset reveals that preset's rows",
      `showing ${after.shownPreset}, chose ${target}`,
    );
    j.countIs(after.shownPanels, 1, "still exactly one preset's rows are visible after the choice");

    // THE LIST FOLLOWED THE CHOICE. Compared as a relation between two
    // readings of the page, never against a chord written in this file.
    const stepAction = Object.keys(beforeChords)[0];
    j.expect(
      !!stepAction && beforeChords[stepAction] !== after.shownChords[stepAction],
      "the chord the list spells for a move changed with the preset",
      `${stepAction}: ${beforeChords[stepAction]} -> ${after.shownChords[stepAction]}`,
    );

    // CONTROL, NOT VERDICT — see this file's header. That the choice was
    // stored is worth knowing when the verdict below fails, and is worth
    // nothing on its own.
    const stored = await sp.evaluate(() => {
      try {
        return JSON.parse(window.localStorage.getItem("bt.ui") || "{}").keymap ?? null;
      } catch (_) {
        return null;
      }
    });
    j.expect(
      stored === target,
      "CONTROL: the choice reached the store the debug route reads",
      `bt.ui.keymap=${stored} chose=${target}`,
    );

    // The chord the NEW preset promises for the move journey 20 drives, and
    // the chord the OLD one promised. Both read off the page.
    const newChord = after.shownChords[stepAction];
    const oldChord = beforeChords[stepAction];

    // ── AND NOW THE KEYS THEMSELVES, ON A DIFFERENT PAGE ────────────────
    //
    // SAME CONTEXT, so the `localStorage` written above is the one the debug
    // route reads. A new context would be a fresh browser profile and would
    // silently test the default preset instead — which would pass the positive
    // assertion below and prove nothing.
    const dp = await ctx.newPage();
    await dp.goto(site.origin + subject.debugPath, { waitUntil: "load", timeout: 45000 });
    // Settle on the same condition journey 20 uses, so "there is something a
    // chord could step" is established before any key is pressed.
    const deadline = Date.now() + 60000;
    let facts = await readFacts(dp);
    while (Date.now() < deadline && !(facts.phase === "ready" && facts.controlsLive > 0)) {
      await dp.waitForTimeout(300);
      facts = await readFacts(dp);
    }
    j.expect(
      facts.phase === "ready" && facts.controlsLive > 0,
      "the session reached `ready` with live controls, so there is something a chord could step",
      `phase=${facts.phase} live=${facts.controlsLive}`,
    );

    // THE VERDICT. The chosen preset's key steps the session.
    const beforePress = facts;
    const afterNew = await pressAndSettle(dp, newChord, beforePress, 20000);
    j.expect(
      moved(afterNew, beforePress),
      `the chord the chosen preset spells (${newChord}) stepped the session`,
      `step ${beforePress.step} -> ${afterNew.step}, marked ${beforePress.markedNumber} -> ${afterNew.markedNumber}`,
    );

    // THE NEGATIVE. The preset that is no longer chosen no longer acts.
    //
    // Its control is the assertion immediately above: the page demonstrably
    // steps on a key press at this moment, so a non-move here is the binding
    // being absent and not the session being dead.
    const beforeOld = await readFacts(dp);
    const afterOld = await pressAndSettle(dp, oldChord, beforeOld, 4000);
    j.expect(
      !moved(afterOld, beforeOld),
      `the previous preset's chord (${oldChord}) no longer steps — a preset is a choice, not an accumulation`,
      `step ${beforeOld.step} -> ${afterOld.step}, marked ${beforeOld.markedNumber} -> ${afterOld.markedNumber}`,
    );

    // AND THE DEBUG ROUTE'S OWN DIALOG AGREES WITH THE PAGE THAT CHOSE.
    // Two surfaces, one stored value, one keymap table — asserted as an
    // agreement between them rather than against a literal.
    const dlg = await dp.evaluate(() => {
      const d = document.querySelector("#dbg-shortcuts");
      const on = [...(d?.querySelectorAll('input[data-kb="preset"]') ?? [])].filter(
        (i) => i.checked,
      );
      return on[0]?.value ?? null;
    });
    j.expect(
      dlg === target,
      "the debug route's shortcuts dialog shows the preset chosen on /settings",
      `dialog=${dlg} chose=${target}`,
    );
  } finally {
    await ctx.close();
  }
}
