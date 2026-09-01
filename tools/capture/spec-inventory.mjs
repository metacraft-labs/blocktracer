// The BlockTracer surface inventory, transcribed from the functional spec.
//
// This file is the machine-readable half of VD.0's
// `verify_capture_covers_named_view_list`. `views.mjs` must name at least one
// view for every entry below; `check-coverage.mjs` fails when it does not.
//
// It is a TRANSCRIPTION, not a source of truth. The source of truth is
// Page-Descriptions.md in the codetracer-specs repo, which is not vendored
// here. `SPEC_SOURCE` records exactly which revision of that document this
// list was transcribed from — when Page-Descriptions.md's "Last updated"
// moves, this file has to be re-read against it, and the coverage check
// prints the recorded revision on every run so the drift is visible rather
// than silent.

export const SPEC_SOURCE = {
  document: "codetracer-specs/BlockTracer/Page-Descriptions.md",
  lastUpdated: "2026-08-29",
  transcribedOn: "2026-08-29",
};

// ── Pages (Page-Descriptions §1 route map, expanded by §2–§13) ──────────────
//
// `id`     — stable key referenced by views.mjs `covers:`
// `route`  — the route template from §1, for orientation only
// `anchor` — the section of Page-Descriptions that specifies it

export const PAGES = [
  { id: "home", route: "/", anchor: "§2" },
  { id: "home.live-demo", route: "/", anchor: "§2 Live demo" },
  { id: "chains-index", route: "/chains", anchor: "§3" },
  { id: "chain-overview", route: "/{chain}", anchor: "§4" },
  // The demo chain's capability tour. A surface of its own rather than a
  // bullet of `chain-overview`, because it is the only region on the site
  // whose subject is the PRODUCT rather than a chain, and because it exists
  // on exactly one chain — an inventory entry is how that asymmetry stays
  // stated instead of being noticed as a diff.
  { id: "chain.capability-tour", route: "/{chain}", anchor: "§4 — the demo chain's tour of what the debugger can show" },
  { id: "blocks-list", route: "/{chain}/blocks", anchor: "§5.1" },
  { id: "blocks-list.row-expanded", route: "/{chain}/blocks", anchor: "§5.1 row expansion" },
  { id: "block-detail", route: "/{chain}/block/{id}", anchor: "§5.2" },
  { id: "txs-list", route: "/{chain}/txs", anchor: "§6" },
  { id: "txs-list.cards", route: "/{chain}/txs", anchor: "§6 mobile stacked cards" },
  { id: "tx-detail", route: "/{chain}/tx/{hash}", anchor: "§7.2" },
  { id: "tx-detail.hydrated", route: "/{chain}/tx/{hash}", anchor: "§7.0 trace ready → hydrates" },
  // §7.0's THIRD row, as two entries rather than one. "`absent`, `unsupported`
  // → the metadata, with the reason stated. No debugger, and no pretence of
  // one" names two facts about the world — there is nothing to record, and we
  // cannot record it — and §14.1a's rule is that presenting either as the other
  // is the failure the catalogue exists to prevent. One entry could be answered
  // by one image, which would make the pair gradeable only against itself. The
  // omniscience/loop-rail pair below is split for the same reason.
  { id: "tx-detail.absent", route: "/{chain}/tx/{hash}", anchor: "§7.0 absent — structurally unobservable" },
  { id: "tx-detail.unsupported", route: "/{chain}/tx/{hash}", anchor: "§7.0 unsupported — no recorder for the VM" },
  { id: "tx-detail.decoded-input", route: "/{chain}/tx/{hash}", anchor: "§7.2.3" },
  { id: "tx-detail.events", route: "/{chain}/tx/{hash}", anchor: "§7.2.4" },
  { id: "tx-detail.internal-calls", route: "/{chain}/tx/{hash}", anchor: "§7.2.5" },
  { id: "tx-detail.state-changes", route: "/{chain}/tx/{hash}", anchor: "§7.2.6" },
  { id: "tx-detail.raw", route: "/{chain}/tx/{hash}", anchor: "§7.2.8" },
  { id: "debugger", route: "/{chain}/tx/{hash}/debug", anchor: "§8" },
  { id: "debugger.metadata-pane", route: "/{chain}/tx/{hash}/debug", anchor: "§7.1" },
  { id: "debugger.call-trace", route: "/{chain}/tx/{hash}/debug", anchor: "§8 / Debugger-Integration" },
  { id: "debugger.event-log", route: "/{chain}/tx/{hash}/debug", anchor: "§8 / Debugger-Integration" },
  // Renamed from `debugger.state-pane` on 2026-08-29, following the pane's own
  // rename. `State` is Etherscan's and Blockscout's word for a transaction's
  // aggregate state DIFF; this pane shows variable values at step N. Keeping a
  // slug that says `state` for a pane titled `Values` is how a reviewer comes
  // to look for a surface the product does not have. The DOM id it is captured
  // through is still `#pane-state`, because that comes from CodeTracer's
  // `PaneKind` enum and is a wire format — see `views.mjs`.
  { id: "debugger.values-pane", route: "/{chain}/tx/{hash}/debug", anchor: "§8 / Debugger-Integration" },
  { id: "debugger.source-pane", route: "/{chain}/tx/{hash}/debug", anchor: "§8 / Debugger-Integration" },
  // Omniscience — the product's stated differentiator, and the one thing in
  // this inventory that no competitor ships: `Debugger-UX-Research.md` records
  // Pernosco, the most sophisticated omniscient debugger extant, listing inline
  // value display as a ROADMAP item. Two entries, because they are two claims a
  // reviewer can judge separately and one can be right while the other is
  // wrong: that the values are legible beside the code, and that the loop
  // control says which pass they belong to and can move between passes.
  { id: "debugger.omniscience", route: "/{chain}/tx/{hash}/debug", anchor: "§8 / Omniscience-Flow" },
  { id: "debugger.loop-rail", route: "/{chain}/tx/{hash}/debug", anchor: "§8 / Omniscience-Flow loop slider" },
  { id: "debugger.loading-phases", route: "/{chain}/tx/{hash}/debug", anchor: "§8 phased loading" },
  { id: "debugger.narrow", route: "/{chain}/tx/{hash}/debug", anchor: "§13 reduced narrow session" },
  // §13's OTHER half, and the one no image has ever carried. The section says
  // "every hash, address and identifier is copyable with one click", and —
  // revised 2026-08-29 — that "a true one-click copy button arrives with
  // hydration, because writing to the clipboard needs script and this route
  // ships none". The pre-hydration affordance (`user-select:all`, hover, cursor)
  // is captured incidentally by every debugger view. The BUTTON is not captured
  // anywhere, because it exists only on a build the corpus does not photograph,
  // and Q23 is what was found there when something finally looked.
  { id: "debugger.copy-affordance", route: "/{chain}/tx/{hash}/debug", anchor: "§13 copyable with one click — the hydrated button" },
  // The `/debug` ADDRESS of a transaction that has no session. It is served —
  // `ssr.staticRoutes` emits `/debug` for every transaction, and
  // `pages/debug.noSession` renders the region the panes would have occupied —
  // and it had no named view, so the one surface in the debugger register whose
  // whole job is to NOT be a debugger had never been photographed. Two states,
  // because `spAwaitingGeneration` offers an action and `spUnavailable` must
  // offer none.
  { id: "debugger.no-session", route: "/{chain}/tx/{hash}/debug", anchor: "§7.0 / §8 — the debug address with no session" },
  // Where a shared link put the session, and what the visitor was told about
  // it. ONE entry for five branches, because they are five outcomes of one
  // decision made in one place (`resolvePosition`) and a reviewer judges them
  // as a family: whether the four visible ones are distinguishable from each
  // other, whether the benign one reads as benign, and whether the silent one
  // is silent. The five views that cover it are what make that comparison
  // possible; a five-entry inventory would only have restated the view list.
  //
  // It is a debugger-register PAGE state and not a §14 degraded state on
  // purpose. Nothing has gone wrong in four of the five: §6.0a's notice is
  // `role="status"` and its own renderer says so — "nothing is wrong. A
  // recovered position is the product working as designed."
  { id: "debugger.link-landing", route: "/{chain}/tx/{hash}/debug?v=1&t=…&c=…&a=…", anchor: "Debugger-Integration §6.0a — the five-step resolution precedence" },
  { id: "address", route: "/{chain}/address/{address}", anchor: "§9" },
  { id: "contract-source", route: "/{chain}/address/{address}/code", anchor: "§10" },
  { id: "search", route: "/search?q=", anchor: "§11" },
  { id: "search.ambiguous", route: "/search?q=", anchor: "§11 grouped candidates" },
  { id: "search.cross-chain", route: "/search?q=", anchor: "§11 found on other chains" },
  { id: "search.not-found", route: "/search?q=", anchor: "§11 / Search-And-Routing §8" },
  { id: "settings", route: "/settings", anchor: "§12" },
  { id: "static-content", route: "/about, /docs/*", anchor: "§1 route map" },

  // ── The provenance banner, as TWO entries ────────────────────────────────
  //
  // `components/provenance.nim` renders a statement of whose data the reader is
  // looking at, on every chain-scoped route — 813 of the 819 pages this tree
  // exports. (It was documented here as 814; that number counted the home
  // page's chain strip, which carries `data-provenance` on its cards and is a
  // different surface. The six pages without a marker are the site-level ones:
  // /about, /settings, /search, /chains and the 404.)
  //
  // Since 2026-08-31 the FORM varies and the id does not: a band where the
  // provenance is abnormal and the page has no facts grid, a chip where it is
  // ordinary, a `Data` row on any page that has a grid. These two ids name the
  // CLAIM, not the element, which is why the change did not move them. It is split in two for the reason `tx-detail.absent`
  // and `tx-detail.unsupported` are split: they are two different claims, a
  // reviewer can judge them separately, and one can be right while the other
  // is wrong. They are also the pair whose CONFUSION is the failure the
  // component exists to prevent — `provenanceTone` says so directly ("calling
  // synthetic data real is worse than declining to vouch for real data"), and
  // a single entry could be satisfied by an image of either one.
  //
  // Before these existed the inventory had no per-chain dimension at all, and
  // that is exactly how a 280-image corpus came to contain zero images of
  // either real chain while this file reported 67/67 covered.
  { id: "provenance.synthetic", route: "/{chain}/**", anchor: "§2, §4 — 'Synthetic demo data', neutral tone" },
  { id: "provenance.live-capture", route: "/{chain}/**", anchor: "§2, §4 — 'Real Aztec … data', affirmative tone" },
];

// ── Degraded-state catalogue (Page-Descriptions §14, §14.1, §14.1a, §14.2) ──
//
// Every row of the §14 table, plus the job states of §14.1 and the replay
// window states of §14.1a and the capability ladder of §14.2, since the
// milestone says "every state in its degraded-state catalogue".

export const DEGRADED_STATES = [
  { id: "degraded.pipeline-behind", anchor: "§14", label: "Pipeline behind the chain tip — staleness notice" },
  { id: "degraded.not-found", anchor: "§14", label: "Object not found — 'not on this chain', with chains checked" },
  { id: "degraded.trace-awaiting-generation", anchor: "§14 / §14.1", label: "Trace awaiting generation — a job with observable phases" },
  { id: "degraded.replay-window-expired", anchor: "§14 / §14.1a", label: "Replay window expired — renewable behind sign-in" },
  { id: "degraded.permanently-unreplayable", anchor: "§14 / §14.1a", label: "Permanently unreplayable — terminal, with a reason" },
  { id: "degraded.browser-cannot-debug", anchor: "§14 / §14.2", label: "Browser cannot run the debugger — the capability ladder" },
  { id: "degraded.recorder-unavailable", anchor: "§14", label: "Recorder unavailable for the VM — Debug absent with status" },
  { id: "degraded.below-history-floor", anchor: "§14", label: "Transaction below the history floor" },
  { id: "degraded.trace-truncated", anchor: "§14", label: "Trace truncated — banner, offer a deeper profile" },
  { id: "degraded.divergence", anchor: "§14", label: "Divergence detected — non-dismissible banner" },
  { id: "degraded.no-verified-source", anchor: "§14", label: "No verified source — instruction-level stepping" },
  { id: "degraded.reorganised", anchor: "§14", label: "Reorganised away — reorg explanation, new location" },
  { id: "degraded.cdn-unreachable", anchor: "§14", label: "CDN unreachable — service worker serves the shell" },
  // The replay engine will not run, and the page says which of three faults it
  // is. §14's "terminal state with a reason, never a retry that cannot
  // succeed", applied to the one dependency this route cannot do without.
  //
  // Distinct from `degraded.browser-cannot-debug` below, which is §14.2's
  // capability ladder: that row is about what the BROWSER cannot do (no wasm,
  // no workers) and is decided before a request is made. This row is about an
  // engine the browser could have run and that did not arrive, did not answer,
  // or would not open this container. The two share a treatment and are not
  // the same fact, which is exactly the confusion the three sentences were
  // separated to prevent.
  { id: "degraded.engine-unavailable", anchor: "§8 / §14 / §14.2", label: "Replay engine unavailable — which of three faults, said on the page" },

  // §14.1 — on-demand generation is a job, not a spinner. Every state below is
  // reachable in the UI with its own treatment, so every one is a named view.
  { id: "degraded.job.accepted", anchor: "§14.1", label: "Generation accepted — quota consumed, cancellable" },
  { id: "degraded.job.queued", anchor: "§14.1", label: "Generation queued — position known, cancellable" },
  { id: "degraded.job.recording", anchor: "§14.1", label: "Recording — not cancellable" },
  { id: "degraded.job.validating", anchor: "§14.1", label: "Validating recorder output" },
  { id: "degraded.job.publishing", anchor: "§14.1", label: "Publishing the artifact" },
  { id: "degraded.job.refused", anchor: "§14.1", label: "Refused — will not be attempted, with the reason" },
  { id: "degraded.job.failed", anchor: "§14.1", label: "Failed — retry only if the pipeline says retryable" },
  { id: "degraded.job.timed-out", anchor: "§14.1", label: "Timed out — exceeded the job budget" },

  // §14.1a — replay is windowed, and the window is renewable.
  { id: "degraded.replay.windowed-live", anchor: "§14.1a", label: "Windowed but live — debugger opens immediately" },
  { id: "degraded.replay.never-generated", anchor: "§14.1a", label: "Never generated — Generate, behind sign-in" },

  // §7.2 §1 — the sign-in / quota paths of the Debug affordance.
  { id: "degraded.quota-exhausted", anchor: "§7.2 Hero", label: "Quota exhausted — distinct from not-signed-in, says when it resets" },
  { id: "degraded.sign-in-required", anchor: "§7.2 Hero", label: "Sign-in prompt, stating what it is for" },

  // §14.2 — the capability ladder, whose floor must be a useful page.
  { id: "degraded.ladder.download-trace", anchor: "§14.2", label: "Ladder 1 — offer the trace download" },
  { id: "degraded.ladder.open-in-desktop", anchor: "§14.2", label: "Ladder 2 — open in CodeTracer desktop" },
  { id: "degraded.ladder.static-summary", anchor: "§14.2", label: "Ladder 3 — static call and event summary, the floor" },
];

export const INVENTORY = [...PAGES, ...DEGRADED_STATES];

export const INVENTORY_IDS = new Set(INVENTORY.map((e) => e.id));
