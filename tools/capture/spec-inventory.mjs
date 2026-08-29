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
  { id: "blocks-list", route: "/{chain}/blocks", anchor: "§5.1" },
  { id: "blocks-list.row-expanded", route: "/{chain}/blocks", anchor: "§5.1 row expansion" },
  { id: "block-detail", route: "/{chain}/block/{id}", anchor: "§5.2" },
  { id: "txs-list", route: "/{chain}/txs", anchor: "§6" },
  { id: "txs-list.cards", route: "/{chain}/txs", anchor: "§6 mobile stacked cards" },
  { id: "tx-detail", route: "/{chain}/tx/{hash}", anchor: "§7.2" },
  { id: "tx-detail.hydrated", route: "/{chain}/tx/{hash}", anchor: "§7.0 trace ready → hydrates" },
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
  { id: "debugger.loading-phases", route: "/{chain}/tx/{hash}/debug", anchor: "§8 phased loading" },
  { id: "debugger.narrow", route: "/{chain}/tx/{hash}/debug", anchor: "§13 reduced narrow session" },
  { id: "address", route: "/{chain}/address/{address}", anchor: "§9" },
  { id: "contract-source", route: "/{chain}/address/{address}/code", anchor: "§10" },
  { id: "search", route: "/search?q=", anchor: "§11" },
  { id: "search.ambiguous", route: "/search?q=", anchor: "§11 grouped candidates" },
  { id: "search.cross-chain", route: "/search?q=", anchor: "§11 found on other chains" },
  { id: "search.not-found", route: "/search?q=", anchor: "§11 / Search-And-Routing §8" },
  { id: "settings", route: "/settings", anchor: "§12" },
  { id: "static-content", route: "/about, /docs/*", anchor: "§1 route map" },
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
