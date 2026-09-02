// "A visitor can trace a value to its origin — and until they can, the product
//  does not say they can."
//
// WHAT CHANGED, AND WHY THE JOURNEY DID NOT SIMPLY GO GREEN
// --------------------------------------------------------
// This journey was written as an implication: IF the home page promises that a
// value can be traced to its origin, THEN some control offers it. The promise
// has now been removed from `client/src/pages/home.nim` and `client/src/ssr.nim`,
// which under the old shape would have turned this file green by deleting its
// antecedent — a legitimate resolution, and the one that was taken, but one
// that would have taken the SIGNAL with it.
//
// So the journey keeps the id and inverts the first half. It now asserts that
// the false claim is GONE (a regression guard on the copy, in the one place a
// visitor and a search engine actually read it) and still asserts the
// capability, unconditionally. That is the same signal, without the escape
// hatch.
//
// WHAT COLOUR IT IS — READ THE LEDGER, NOT THIS SENTENCE. This header used to
// say "It is RED today on the capability half, and it goes green when the
// surface lands." Both halves have expired. The surface HAS landed:
// `hydrate/session_project.nim` builds the `OriginChainVM`,
// `components/debugger.nim` renders the `.storigin` control, `hydrate.nim` wires
// the click to `onShowOrigin`, and `hydrate/live_origin.nim` reads the reply
// back. And this journey appears in NEITHER `known_red` NOR `_closed` in
// `tools/journeys/ledger.json` — that file's own prose records the entry being
// removed when the journey went green on real functionality, naming 2 of 6
// classified hops on the Noir demo capture. A journey with no ledger entry
// asserts nothing about its own colour; run it and read the verdict.
//
// THE PREVIOUS DIAGNOSIS IN THIS FILE WAS WRONG, AND SO WAS ITS CONTROL ARM
// ------------------------------------------------------------------------
// It said the surface was "ONE ASSIGNMENT AWAY" — that `StateVM.originChainLookup`
// is declared and BlockTracer merely never assigns it. Both halves of that are
// true and the conclusion does not follow, because there is nothing to look the
// origin of UP. Measured against the pinned Embed SDK (`ci/embed-sdk-pin.env`,
// 8d1c84a8):
//
//   `ReplayDataStore.requestLocals` (store/replay_data_store.nim:664-680) sends
//   `ct/load-locals` and DISCARDS the reply. Its `onSuccess` sets
//   `loadingState` and `loadedForRRTicks` and nothing else, and its own comment
//   says why: "The actual JSON→Variable parsing will be added when the locals
//   panel is converted; for now we just update loading state."
//
//   The only writer of `store.locals.locals` is `updateLocals`.
//
// AND THAT DIAGNOSIS HAS ITSELF BEEN OVERTAKEN — it is kept because it is the
// reason the code below is shaped as it is, not because it still describes the
// product. It went on: "Nothing under `client/hydrate/` calls `updateLocals`, so
// `StateVM.currentVariables` is empty for the life of every hydrated session and
// `hydrate.nim`'s PaneLatch — which only writes the State pane when
// `values.len > 0` — never fires."
//
// Two of those are now false in this tree. `client/hydrate/live_locals.nim` is
// the decorator that reads the discarded reply off the shared `BackendService`
// and calls `feed.store.updateLocals(...)`; `session_project.nim` calls it too.
// And the latch is `view.state.values.len > 0 or view.state.note.len > 0`, so it
// also fires for a pane that has only a sentence to print. What remains true of
// the PIN is the first paragraph: the SDK's own `requestLocals` still discards
// its reply, which is why the decorator exists at all.
//
// That is also what was wrong with the old control arm. It asserted
// `valuesShown >= 1` as its non-vacuity guard and concluded "there is something
// to ask the origin of". Those rows are the served frame's fixture text. The
// guard was satisfied by exactly the artefact whose persistence IS the defect,
// so the journey could not have detected the defect it was written for. This
// version measures the served frame and the hydrated page separately and
// compares them, which is the difference between "there are rows" and "the rows
// are the engine's".
//
// THE SECOND BLOCKER, WHICH OUTLIVES THE FIRST
// --------------------------------------------
// Fidelity. Every transaction this explorer publishes is declared rung 3, and
// `client/src/debugger/demo_session.nim` prints the consequence verbatim: "This
// recording carries no variable names: naming a local needs debug symbols,
// which an Aztec contract class does not publish." The origin classifier works
// by splitting the right-hand side of a source assignment (see codetracer's
// `tests/fixtures/origin/noir/simple_trivial_chain/ANSWERS.md`), so with no
// source and no names it has nothing to split. Fixing the SDK alone would give
// a live but nameless pane, and an origin chain over it would terminate at
// `UnknownVariable` on every hop.
//
// Where it WOULD be meaningful is the demo tour: the real Noir programs
// recorded by `nargo trace`, each with a `sources/` tree and `varnames` in its
// trace. That — not the real chain — is the subject the surface should first be
// demonstrated on.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING
// ---------------------------------------------
// THIS FILE CARRIED THE SAME SUBJECT-SELECTION DEFECT AS JOURNEYS 03 AND 09,
// and was the third occurrence of it. Until it was removed the subject was
//
//     sessions.find((t) => !t.real) ?? sessions[0]
//
// which PREFERS a synthetic fixture. With 19 synthetic sessions in the corpus
// the `??` arm could never be reached, so every assertion this journey has ever
// made about the capability was made about the demo chain — including the
// "counted 0" its ledger entry is written from. The claim above names no
// chain, so a corpus-wide absence was being inferred from one recording.
//
// (That "counted 0" was recorded in `ledger.json` at the time. THE ENTRY IS
// GONE — this journey appears in neither `known_red` nor `_closed` today — and
// three places in this file still spoke of it in the present tense. Corrected
// below; see the note beside `READ_CONTROLS`, which was resting on it.)
//
// The fix is the one 03 and 09 took: TWO SUBJECT LISTS SELECTED BY FILTER, each
// asserted non-empty with its count printed, both driven, and NO `??` between
// them. The fallback is what made "no real capture was available" and "a real
// capture passed" the same green — a corpus that loses one kind of recording
// must be a RED, because the journey can no longer judge the claim it makes.
//
// AND THE SPLIT IS NOW BY SOURCE, WHICH IS WHAT THE CAPABILITY DEPENDS ON
// -----------------------------------------------------------------------
// The two arms used to be synthetic-vs-real. That is not the property the
// claim turns on. Whether a value can be traced to its origin depends on
// whether the RECORDING published source: the classifier parses the
// right-hand side of the assignment that produced the value, so a recording
// with no source has nothing for it to read — permanently, and correctly.
//
// Today `hasSource` happens to separate the demo chain from the chain
// captures, and selecting on it rather than on `real` is what keeps that a
// coincidence the journey does not depend on. `corpus.mjs` reads it per
// transaction from the served markup, so a capture whose contract gains a
// verified artifact moves into the capability arm on its own.
//
// WHAT EACH ARM ASSERTS, AND WHY THEY DIFFER
// ------------------------------------------
// SOURCE-BEARING: the control is offered, AND it can answer. The second half
// is the one this journey most needed and did not have — `ct/originChain`
// replies `success: true` for a value it cannot attribute at all, so a chain
// of successful calls every one of which says `kind: "unknown"`,
// `confidence: 0`, `"built-in: source unavailable"` is precisely the false
// pass this entry was written from. The arm counts CLASSIFIED hops and
// prints the count.
//
// AND IT READS THE CONTROL'S OWN LABEL, WHICH WAS OBSERVED AND UNDEFENDED
// ----------------------------------------------------------------------
// The renderer writes the classified terminator expression into the control's
// `title` ("Trace to origin: <expr>"), and that is what makes the button an
// offer rather than a decoration: it says what the answer will be before it is
// asked. Every reading of it was printed as a note and asserted by nothing, so
// a control whose title had lost its expression — the empty-classification
// case this whole module is written around — would have read as a clean green
// with the evidence of the defect sitting two lines above the verdict in the
// transcript. It is now a count: as many titles naming an expression as there
// are controls on screen.
//
// SOURCE-LESS: the pane STATES WHY, and offers no control. Demanding an
// affordance here could only be satisfied by shipping one that answers
// "unknown" on every value — NR-05's "confident-looking affordance that
// resolves nothing … worse than the absence". A source-less capture that DOES
// offer a working control is a RED, because that is the direction the defect
// returns from.
//
// The two negative provenances are counted separately and must stay separate:
// "source unavailable" is a recording the classifier could not READ, while
// "unparseable source line" is one it read and could not attribute — the
// correct answer for a function parameter, and evidence the source arrived.
// The fix moves values out of the first bucket, so collapsing them would hide
// the regression.
//
// Measured over `just export-hydrated` with the published engine staged:
//   demo/tx/0x5c67… (Noir)      6 rows, 2 controls, 2 of 6 hops classified
//                               (kind=functionCall, confidence=0.7), no note
//   aztec-testnet/tx/0x1252…    5 rows, 0 controls, note present,
//                               5 of 5 hops "source unavailable"

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-value-can-be-traced-to-its-origin";
export const claim =
  "A visitor can trace a value to its origin — and until they can, the product does not say they can.";
export const spec =
  "client/src/pages/home.nim (the hero) and ssr.nim (the meta description) — the product's own promise, now withdrawn";
export const assertions = 22;
export const needsEngine = true;

const PROMISE = /trace any value to its origin/i;

/**
 * A title that names the origin it offers to trace to.
 *
 * The renderer writes `"Trace to origin: " & v.origin`, where `v.origin` is the
 * engine's classified terminator expression, so the title is the one place the
 * control states its own answer in advance. The CAPTURE is the load-bearing
 * half and the reason this is not a `startsWith`: a control titled
 * `"Trace to origin: "` with nothing after it satisfies a prefix test while
 * being exactly the empty-classification case the surface must not ship — the
 * confident-looking affordance NR-05 calls worse than the absence, wearing a
 * correct-looking label.
 *
 * Anchored at both ends and applied to the title as a whole, so a title that
 * merely CONTAINS the phrase somewhere does not count as one that leads with
 * it.
 */
const ORIGIN_TITLE = /^\s*Trace to origin:\s*(\S[\s\S]*?)\s*$/;

/** The State pane's rows as the DOM holds them, from an already-loaded page. */
const READ_ROWS = () => {
  const shown = (e) =>
    !!e &&
    typeof e.checkVisibility === "function" &&
    e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  const rows = [...document.querySelectorAll(".strow")];
  return {
    rows: rows.length,
    shown: rows.filter(shown).length,
    // The reading, not the markup: a class change elsewhere must not read as
    // "the engine supplied different values".
    text: rows.map((e) => (e.textContent ?? "").replace(/\s+/g, " ").trim()).join("|"),
  };
};

/**
 * The origin affordances on screen, and the interactive controls beside them.
 *
 * ONE selector for both arms, hoisted here so that "counted 0" means the same
 * measurement on a demo session and on a chain capture. Two copies of the regex
 * is two chances for the arms to disagree about what an origin control looks
 * like, and a difference there would read as a difference in the product.
 *
 * THE LABEL, NOT THE CONTENT — AND THIS IS A MEASURED CORRECTION
 * -------------------------------------------------------------
 * The previous form matched the regex against each candidate's whole
 * `textContent`. On the demo chain it counted 0 and the journey read as
 * correct. The first run that reached a CHAIN capture counted 1, and the one
 * match was this, on every one of the eight real captures in the corpus:
 *
 *   <a class="evrow k-event" href="?v=1&t=344&…">
 *     …avm:11912 status=unavailable-in-principle origin=settled-chain …
 *
 * An EVENT-LOG ROW. `origin=` there is a field of the event the chain recorded,
 * and `textContent` on a row flattens every column into one string. Nothing on
 * that page offers to trace anything; the word was in the data.
 *
 * That number is the whole verdict of this journey. `atLeast(…, 1)` asserts
 * PRESENCE, so a match that is not a control is a FALSE GREEN. The generosity
 * was written when this assertion claimed an ABSENCE, where erring wide is the
 * safe direction; it is the unsafe direction for the presence claim the file
 * now makes.
 *
 * WHAT THIS PARAGRAPH USED TO SAY, AND WHY THE CORRECTION MATTERS MORE THAN THE
 * SENTENCE. It read: "because this journey is ledgered known-red, a false green
 * here does not merely mis-measure, it FAILS THE RUN with 'this journey is in
 * ledger.json as known-red and it is GREEN'". That is not true and has not been
 * for some time — this journey is in neither `known_red` nor `_closed`. The
 * ledger's bidirectionality is real, and it was a genuine safety net while the
 * entry existed; with the entry gone, a false green here is simply a green.
 *
 * The argument was LOAD-BEARING, so it is replaced rather than deleted. Two
 * things defend this assertion now, and neither involves the ledger:
 *
 *   * the narrowing itself — the regex is applied to what an author WROTE as a
 *     label, so the event-log row that produced the historical false match
 *     cannot match again, and the wide count is still returned and printed so
 *     the narrowing stays auditable from the transcript;
 *   * and, decisively, the CLASSIFIED-hop assertion further down. Presence is
 *     not the capability: `ct/originChain` answers `success: true` for a value
 *     it cannot attribute at all, so the journey asks the engine and counts the
 *     hops that came back classified. A control matched out of an event-log
 *     string has no engine behind it and reddens there.
 *
 * A presence check whose only backstop was a ledger entry would have been
 * resting on a file nobody had to keep in step with this one.
 *
 * So the regex is applied to what an AUTHOR wrote as a label:
 *
 *   * `data-action`, `aria-label`, `title` — always authored, never content;
 *   * the element's text, but only where that text is SHORT ENOUGH TO BE A
 *     LABEL. A control says "Trace to origin"; a trace row is four columns of
 *     recorded data flattened together.
 *
 * The threshold is a property of labels, not a blacklist of classes, so a pane
 * that gains a row kind does not need an edit here. Both counts are returned
 * and both are printed: the wide one stays visible in the transcript, so a
 * future affordance that this narrowing would miss shows up as a gap between
 * two numbers rather than as silence.
 */
const READ_CONTROLS = () => {
  const RE = /origin|where did this come from|provenance|trace value/i;
  const LABEL_MAX_CHARS = 60;
  const shown = (e) =>
    !!e &&
    typeof e.checkVisibility === "function" &&
    e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  const candidates = [
    ...document.querySelectorAll("a, button, [data-action], [role=button]"),
  ];
  const attrs = (e) =>
    `${e.getAttribute("data-action") ?? ""} ${e.getAttribute("aria-label") ?? ""} ${
      e.getAttribute("title") ?? ""
    }`;
  const label = (e) => (e.textContent ?? "").replace(/\s+/g, " ").trim();
  return {
    // The verdict: an authored label offering the gesture.
    originAffordances: candidates.filter(
      (e) => RE.test(attrs(e)) || (label(e).length <= LABEL_MAX_CHARS && RE.test(label(e))),
    ).length,
    // The old, fully generous reading, kept and REPORTED so the narrowing is
    // visible as a number rather than as an absence.
    originMentions: candidates.filter((e) => RE.test(`${label(e)} ${attrs(e)}`)).length,
    // UNCHANGED from the form this control was written in — `a, button,
    // [data-action]`, on screen. It answers "did the bundle run", and moving it
    // while narrowing the selector above would have made the two numbers
    // incomparable with every reading taken before today.
    interactive: [...document.querySelectorAll("a, button, [data-action]")].filter(shown).length,
    // The AUTHORED control, by its own class, and the sentence that stands in
    // its place. Read together with `originAffordances` above: where the two
    // disagree the gap says the control was renamed rather than removed, which
    // a selector-only reading would report as a regression.
    originControls: [...document.querySelectorAll(".storigin")].filter(shown).length,
    // THE SAME SET `originControls` COUNTS — `shown`, and in the same order.
    // The titles used to be read off every `.storigin` in the document while
    // the count beside them was of the visible ones, so comparing the two
    // numbers compared two different subjects, and a title read off a control
    // no visitor can see would have answered for one they can.
    originTitles: [...document.querySelectorAll(".storigin")]
      .filter(shown)
      .map((e) => e.getAttribute("title") ?? ""),
    originNote: document.querySelector("#pane-state .stnote")?.textContent?.trim() ?? "",
  };
};

/**
 * The HOPS, asked of the engine the bundle itself booted.
 *
 * The DOM can say a control is offered; only the engine can say the control
 * would answer. This is the difference the whole journey turns on, because
 * `ct/originChain` replies `success: true` in BOTH states — a chain of
 * successful calls every one of which says `kind: "unknown"`,
 * `confidence: 0`, `classificationProvenance: "built-in: source unavailable"`
 * is exactly the state this journey was written after measuring. (It was
 * carried in `ledger.json` then; the entry no longer exists.)
 *
 * `globalThis.__btReplayWorker` is where `engine_transport.nim` parks the
 * worker. Nothing is added to the page for this: a session that never reached
 * an engine has no worker there and this returns `null`, which the caller
 * reports rather than scoring as zero.
 */
const ASK_ENGINE = async () => {
  const w = globalThis.__btReplayWorker;
  if (!w) return null;
  let seq = 900000; // clear of the bundle's own counter, so no reply is stolen
  const send = (command, args_) =>
    new Promise((resolve, reject) => {
      const s = seq++;
      const onMsg = (e) => {
        let m = e.data;
        if (typeof m === "string") {
          const t = m.trim();
          if (!t.startsWith("{")) return;
          try {
            m = JSON.parse(t);
          } catch {
            return;
          }
        }
        if (m && m.type === "response" && m.request_seq === s) {
          w.removeEventListener("message", onMsg);
          resolve(m);
        }
      };
      // addEventListener and not `onmessage`, which the transport owns and
      // which assigning would disconnect the live session out from under the
      // page this journey is judging.
      w.addEventListener("message", onMsg);
      setTimeout(() => {
        w.removeEventListener("message", onMsg);
        reject(new Error(`timeout on ${command}`));
      }, 45000);
      w.postMessage({ seq: s, type: "request", command, arguments: args_ ?? {} });
    });

  try {
    // WALK TO A POSITION THAT HAS VALUES. A session opens at its entry line
    // where nothing is bound yet, and a reading taken there finds no locals,
    // asks about nothing, and reports zero classified — a measurement of the
    // POSITION dressed as a measurement of the product. The `let` bindings a
    // chain can speak about are a dozen steps in.
    let rows = [];
    for (let i = 0; i < 14; i++) {
      const locals = await send("ct/load-locals", {
        rrTicks: 0,
        countBudget: 3000,
        minCountLimit: 50,
        depthLimit: 7,
        watchExpressions: [],
        lang: 0,
      });
      const got = locals?.body?.locals ?? [];
      if (got.length > rows.length) rows = got;
      await send("next", { threadId: 1 });
    }
    let hops = 0;
    let classified = 0;
    let unparseable = 0;
    let unavailable = 0;
    for (const r of rows.slice(0, 10)) {
      const res = await send("ct/originChain", {
        variableName: r.expression,
        variablePath: [],
        frameId: -1,
        stepId: -1,
        threadId: 1,
        maxHops: 32,
        lazy: false,
        sessionId: "",
        classifySource: true,
      });
      for (const h of res?.body?.hops ?? []) {
        hops += 1;
        const prov = String(h.classificationProvenance ?? "");
        // THE TWO NEGATIVE VERDICTS ARE COUNTED SEPARATELY AND MUST STAY SO.
        // "source unavailable" is a recording the classifier could not READ.
        // "unparseable source line" is one it read and could not attribute —
        // which is the correct answer for a function PARAMETER, and a sign the
        // source arrived. Collapsing them would hide the regression this
        // journey exists to catch, because the fix moves values from the first
        // bucket into the second and the third.
        if (/source unavailable/i.test(prov)) unavailable += 1;
        else if (/unparseable/i.test(prov)) unparseable += 1;
        if (
          h.kind &&
          String(h.kind).toLowerCase() !== "unknown" &&
          Number(h.confidence ?? 0) > 0 &&
          !/source unavailable/i.test(prov)
        )
          classified += 1;
      }
    }
    return { asked: rows.length, hops, classified, unparseable, unavailable };
  } catch (e) {
    return { error: String(e.message ?? e) };
  }
};

export async function run({ browser, site, j }) {
  // ---- half one: the product no longer claims what it cannot do -----------
  const home = await visit(browser, site.origin, "/");
  try {
    const rendered = await home.page.evaluate(() => document.body.innerText);
    j.expect(
      !PROMISE.test(rendered),
      "the home page does NOT promise that a value can be traced to its origin",
      PROMISE.test(rendered)
        ? "the sentence is back on screen — the surface must land before the copy does"
        : "the hero claims stepping and the call trace, both of which it has",
    );

    const meta = await home.page.evaluate(
      () =>
        document.querySelector('meta[name="description"]')?.getAttribute("content") ?? "",
    );
    j.expect(
      !PROMISE.test(meta),
      "and the meta description does not make the promise to search results either",
      meta.length > 0 ? "" : "NO meta description at all — this assertion would pass vacuously",
    );
    // Non-vacuity for the two above: an empty page and a missing tag each
    // satisfy "does not contain the sentence" for free.
    j.expect(
      rendered.length > 200 && meta.length > 40,
      "CONTROL: the page and the meta tag both have substantial copy, so the two absences above are measurements",
      `body ${rendered.length} chars, meta ${meta.length} chars`,
    );
  } finally {
    await home.page.close();
  }

  // ---- half two: the capability itself ------------------------------------
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(sessions, 3, "transactions whose landing is a session with rows in its Code pane");

  // TWO SUBJECT LISTS, EACH ASSERTED NON-EMPTY, AND NO FALLBACK BETWEEN THEM.
  // See the header: `find((t) => !t.real) ?? sessions[0]` is what kept this
  // journey on the demo chain for its whole life. Selecting by filter and
  // asserting each size makes a corpus that has lost one kind of recording a
  // RED — which is what it is, because the journey can no longer judge the
  // claim it makes — instead of a green over whichever kind survived.
  // ...AND THE SPLIT IS BY SOURCE, NOT BY SYNTHETIC-VS-REAL.
  //
  // The capability is a property of the RECORDING, not of where it came from.
  // The origin classifier reads the line that assigned a value, so a recording
  // that published source can support the gesture and one that did not cannot
  // — permanently, and correctly. Today those two sets happen to be the demo
  // chain and the chain captures, and selecting on `hasSource` rather than on
  // `real` is what makes that a coincidence the journey does not depend on:
  // the day a chain capture carries source (its contract gains a verified
  // artifact, which `corpus.mjs` reads per transaction), it moves into the
  // first arm and is judged by it, with no edit here.
  const withSource = sessions.filter((t) => t.hasSource);
  const withoutSource = sessions.filter((t) => !t.hasSource);
  j.atLeast(
    withSource.length,
    1,
    `SUBJECTS: sessions whose recording published source (${withSource.length}), so the capability arm has a subject`,
  );
  j.atLeast(
    withoutSource.length,
    1,
    `SUBJECTS: sessions whose recording published NO source (${withoutSource.length}), so the honest-absence arm has a subject`,
  );

  const subject = withSource[0];
  j.note(`driving ${subject.debugPath}`);

  // The SERVED frame: the same URL with scripting off, which is what the
  // exporter wrote and what the visitor sees before the bundle runs.
  //
  // `javaScriptEnabled` is a CONTEXT option in Playwright, not a page method —
  // this harness is Playwright (`chromium.launch` in lib/probe.mjs), and the
  // Puppeteer spelling `page.setJavaScriptEnabled(false)` throws here rather
  // than quietly leaving scripting on. Worth the sentence: a served-frame
  // reading taken with the bundle still running would compare the hydrated
  // page against itself and report "unchanged" for every session, which is the
  // failing verdict below arrived at for entirely the wrong reason.
  const servedCtx = await browser.newContext({ javaScriptEnabled: false });
  let served;
  try {
    const servedPage = await servedCtx.newPage();
    await servedPage.goto(site.origin + subject.debugPath, {
      waitUntil: "domcontentloaded",
      timeout: 45000,
    });
    served = await servedPage.evaluate(READ_ROWS);
  } finally {
    await servedCtx.close();
  }

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session went live, so the panes on screen are the bundle's to write",
      `phase=${live.facts.phase}`,
    );

    const probe = await live.page.evaluate(READ_CONTROLS);
    const hydrated = await live.page.evaluate(READ_ROWS);

    // NON-VACUITY. Comparing two empty panes would report "unchanged" for a
    // reason that has nothing to do with the engine.
    j.atLeast(
      served.shown,
      1,
      `the SERVED frame already shows Values rows, so the comparison below has something to compare (${served.rows} rows, ${served.shown} shown)`,
    );

    // CONTROL, and the one the previous version of this journey lacked: the
    // bundle demonstrably rewrites SOMETHING on this page. Without it, "the
    // Values pane did not change" is equally explained by a bundle that never
    // ran, and the defect below would be indistinguishable from a dead engine.
    j.atLeast(
      probe.interactive,
      5,
      `CONTROL: the live page has ${probe.interactive} interactive controls and reached phase=ready, so the bundle ran`,
    );

    // THE CLAIM. The pane a live session shows must be the ENGINE's answer for
    // the position it is at, and not the markup the exporter wrote. Byte
    // equality with the served frame is the shape the failure takes: a pane full
    // of the right-looking rows for the wrong frame.
    //
    // THE FAILURE MESSAGE NAMES NO CAUSE ANY MORE, deliberately. It used to
    // assert one — "the SDK discards the ct/load-locals reply, so
    // StateVM.currentVariables is empty and the PaneLatch never fires" — and two
    // thirds of that stopped being true: `client/hydrate/live_locals.nim` reads
    // that reply and calls `store.updateLocals`, and the latch fires on
    // `values.len > 0 or note.len > 0`. A verdict that hands the reader a stale
    // diagnosis is worse than one that hands them the measurement and lets them
    // go and look.
    j.expect(
      hydrated.text !== served.text,
      "the Values pane a live session shows is the ENGINE's, not the served frame's",
      hydrated.text === served.text
        ? `identical to the served frame (${hydrated.rows} rows) — the live pane is byte-for-byte the exported one; the cause is NOT diagnosed here, start at client/hydrate/live_locals.nim and hydrate.nim's PaneLatch`
        : `served ${served.rows} rows, live ${hydrated.rows} rows`,
    );

    // THE CONSEQUENT. The wide count is printed beside the verdict so the
    // narrowing in READ_CONTROLS is auditable from the transcript: on this page
    // the two agree, and where they ever diverge the gap says which reading to
    // go and look at.
    // THE CONTROL CAN ANSWER — asked FIRST, because asking also MOVES. This is the assertion the previous version
    // of this journey did not have and most needed: the surface being present
    // is not the capability, because `ct/originChain` answers `success: true`
    // for a value it cannot attribute at all. So the hops are asked for and
    // the CLASSIFIED ones are counted — kind not "unknown", confidence above
    // zero, provenance not "source unavailable" — and the count is printed
    // beside the verdict.
    // ZEROS AND NOT AN EARLY RETURN when the engine cannot be reached: the
    // three assertions below must be issued on every path, or the declared
    // assertion count varies with the failure and `run.mjs`'s count check
    // reddens for the wrong reason — hiding whichever real assertion was
    // skipped behind a arithmetic complaint.
    const engine = (await live.page.evaluate(ASK_ENGINE)) ?? {
      error: "no __btReplayWorker on the page — the bundle never reached an engine",
    };
    if (engine.error) j.note(`engine not queried: ${engine.error}`);
    const asked = engine.asked ?? 0;
    const hops = engine.hops ?? 0;
    const classified = engine.classified ?? 0;
    const unparseable = engine.unparseable ?? 0;
    const unavailable = engine.unavailable ?? 0;
    j.note(
      `hops: ${hops} over ${asked} values — ${classified} CLASSIFIED, ` +
        `${unparseable} read-but-unparseable, ${unavailable} source-unavailable`,
    );
    // Non-vacuity: universal quantification over an empty set passes for free,
    // and "no values here" would make every count below a zero that means
    // nothing.
    j.atLeast(
      asked,
      1,
      `the position has values to ask about (${asked}), so the counts below are measurements`,
    );
    j.atLeast(
      classified,
      1,
      `a value's origin is actually CLASSIFIED, not merely answered (${classified} of ${hops} hops)`,
    );
    // The two negative verdicts are different facts and the journey keeps them
    // apart. On a recording whose source DID arrive, no hop may say "source
    // unavailable" — that string reappearing here is the exact regression this
    // journey was red for, and it would otherwise hide behind a classified
    // count that was still non-zero.
    j.expect(
      unavailable === 0 && hops > 0,
      "no hop reports 'source unavailable' on a recording that published source",
      `${unavailable} of ${hops} did; ${unparseable} said 'unparseable source line', which is the correct answer for a parameter`,
    );

    // THE SURFACE, READ WHERE THE VALUES ARE.
    //
    // `probe` above was taken at the LANDING position, and a session lands on
    // its entry line where nothing is bound yet: the State pane has no rows
    // there, so it has no row controls either, and a reading taken then counts
    // zero for a reason that has nothing to do with whether the product offers
    // the gesture. `ASK_ENGINE` steps the session to a position that has
    // values — the same walk, for the same reason — so the pane is re-read
    // after it. The landing count is still printed beside this one, because
    // the two differing is a fact about the SUBJECT and not about the surface.
    const shownHere = await live.page.evaluate(READ_CONTROLS);
    j.note(
      `origin affordances at landing: ${probe.originAffordances} labelled, ${probe.originControls} authored; ` +
        `at a position with values: ${shownHere.originAffordances} labelled, ${shownHere.originControls} authored, ` +
        `${shownHere.originMentions} matched anywhere`,
    );
    for (const t of shownHere.originTitles) j.note(`  control says: ${t}`);
    j.atLeast(
      shownHere.originAffordances,
      1,
      "some control offers to trace a value to its origin",
    );
    // The control is offered exactly where a chain exists and nowhere else.
    // Without this the first assertion is satisfied by a control on every row,
    // which is the shape NR-05 calls worse than the absence.
    j.expect(
      shownHere.originControls === classified,
      "and it is offered on exactly the values whose origin was classified, not on every row",
      `${shownHere.originControls} control(s) against ${classified} classified of ${asked} values`,
    );

    // AND EACH OF THOSE CONTROLS SAYS WHAT IT WOULD ANSWER.
    //
    // The subject is the controls the page is SHOWING — read off the page by
    // the same `.storigin`-and-`checkVisibility` reading that produced the
    // count above, never a list of rows or names written here — and the
    // expectation is a relation between two numbers that page reports: as many
    // titles carrying an origin expression as there are controls carrying a
    // title.
    //
    // `countIs` and not `atLeast`: the size of this set is knowable, it is the
    // control count, and §4b's existential control ("at least one title is
    // fine") is satisfied by one good label among five empty ones — which is
    // the state a partial classification regression would actually leave.
    //
    // It cannot pass vacuously either. `originControls` is asserted equal to a
    // `classified` that is itself asserted `>= 1` two verdicts above, so a page
    // with no controls at all has already reddened before reaching here, and
    // `countIs(0, 0)` is not a verdict this assertion can reach on its own.
    const naming = shownHere.originTitles.filter((t) => ORIGIN_TITLE.test(t));
    j.countIs(
      naming.length,
      shownHere.originControls,
      "and each control names the origin it would trace to, so the offer states its own answer",
    );
  } finally {
    await live.page.close();
  }

  // ── THE RECORDING THAT CANNOT ─────────────────────────────────────────
  //
  // A separate subject and a separate page, asserting the OTHER correct
  // behaviour rather than the same one twice.
  await noSourceArm(browser, site, j, withoutSource[0]);
}

/**
 * The claim's OTHER half, over a recording that cannot support it.
 *
 * WHY THIS ARM DOES NOT ASSERT THE AFFORDANCE
 * -------------------------------------------
 * It used to, and that was wrong in a way worth writing down. A recording
 * that published no source cannot have an origin chain over any of its
 * values: the classifier works by parsing the right-hand side of the source
 * assignment that produced the value, and there is no source to parse. Every
 * chain capture this explorer publishes is in that state — `sourceBundles` is
 * empty and `execution.sourceLevel` is false on all of them — and it is not a
 * defect but a property of a rung-3 recording of a contract class that
 * publishes no debug information.
 *
 * So demanding a control here could only ever be satisfied by shipping one
 * that answers "unknown" on every value. `docs/NOIR-RECORDER-DEFECTS.md`
 * NR-05 says exactly what that would be: "a confident-looking affordance that
 * resolves nothing … worse than the absence".
 *
 * WHAT IT ASSERTS INSTEAD
 * -----------------------
 * The behaviour that IS correct here, and which is a real product
 * requirement rather than a lowered bar: the pane STATES why, rather than
 * silently offering nothing. That is the standard the rest of this surface
 * already holds — "Frames are recorded. Nothing resolved a position for this
 * recording" is the sibling sentence, and `demo_session.nim` states the
 * variable-names one verbatim.
 *
 * AND THE INVERSE MISTAKE IS A FAILURE TOO
 * ----------------------------------------
 * A source-less capture that DOES offer a working control is a red here, not
 * a bonus. That is the direction the defect would come back from: a control
 * keyed off "a summary arrived" or "the call succeeded" rather than off the
 * classification would reappear on exactly these pages, and an arm that only
 * checked for the sentence would pass while it did.
 *
 * The assertion texts contain no other assertion's text: `selftest.mjs`
 * resolves an arm's target with `r.what.includes(assertion)` and treats two
 * hits as no hit.
 */
async function noSourceArm(browser, site, j, subject) {
  j.note(`driving SOURCE-LESS capture ${subject.debugPath} (chain ${subject.chain})`);

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    j.expect(
      live.settled && !live.timedOut,
      "NO-SOURCE: the capture reached a live session, so the bundle owns its panes",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    const probe = await live.page.evaluate(READ_CONTROLS);

    // CONTROL. Without it, "no origin control here" is equally explained by a
    // page the bundle never reached, and the assertions below would be
    // statements about this suite rather than about the product.
    j.atLeast(
      probe.interactive,
      5,
      `NO-SOURCE: CONTROL — the page carries ${probe.interactive} interactive controls, so the bundle ran here too`,
    );

    // THE ENGINE FIRST, because asking also MOVES: the session lands on its
    // entry line with nothing bound, and a State pane read there has no rows,
    // hence no controls AND no note — a pair of zeros that would satisfy one
    // assertion below for free and fail the other for the wrong reason.
    // Zeros rather than an early return, for the reason the other arm gives:
    // the assertion count must not depend on whether the engine answered.
    const engine = (await live.page.evaluate(ASK_ENGINE)) ?? {
      error: "no __btReplayWorker on the page",
    };
    if (engine.error) j.note(`NO-SOURCE: engine not queried (${engine.error})`);
    const hops = engine.hops ?? 0;
    const classified = engine.classified ?? 0;
    const unavailable = engine.unavailable ?? 0;
    j.note(
      `NO-SOURCE hops: ${hops} over ${engine.asked ?? 0} values — ` +
        `${classified} classified, ${unavailable} source-unavailable`,
    );
    j.atLeast(
      hops,
      1,
      `NO-SOURCE: the engine did return hops (${hops}), so the zero below is a verdict and not an empty set`,
    );
    j.expect(
      classified === 0,
      "NO-SOURCE: and none of them is classified, which is why no control is offered",
      `${classified} classified; ${unavailable} said 'source unavailable'`,
    );

    // THE SURFACE, READ WHERE THE VALUES ARE — see the demo arm's note.
    const shownHere = await live.page.evaluate(READ_CONTROLS);
    j.note(
      `NO-SOURCE origin readings at a position with values: ${shownHere.originControls} authored controls, ` +
        `${shownHere.originAffordances} labelled, ${shownHere.originMentions} matched anywhere`,
    );

    // THE SENTENCE. This is the capability's honest form for this recording:
    // the pane states why, rather than leaving an absence the visitor has to
    // explain to themselves.
    j.expect(
      shownHere.originNote.length > 0,
      "NO-SOURCE: the pane says why a value here cannot be traced, instead of showing nothing",
      shownHere.originNote.length > 0
        ? shownHere.originNote
        : "no note in the State pane — the absence is unexplained, which is the state this arm exists to forbid",
    );

    // THE INVERSE MISTAKE. A control offered where nothing can answer is the
    // defect returning, and it is asserted as a count so it cannot pass
    // vacuously.
    j.expect(
      shownHere.originControls === 0,
      "NO-SOURCE: and it offers no origin control, because none could answer",
      `${shownHere.originControls} authored control(s) on a recording with no source to classify`,
    );
  } finally {
    await live.page.close();
  }
}
