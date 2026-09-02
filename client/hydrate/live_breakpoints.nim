## The visitor's breakpoints: the set, where it is kept, and how it reaches
## the engine.
##
## ## This is wiring, and the measurements that say so
##
## Every part of "continue to the next breakpoint" except the breakpoint
## already existed when this file was written, and it was measured rather than
## assumed. Driving the deployed bundle with `Worker.postMessage` wrapped:
##
##   * `setBreakpoints` was sent ZERO times by the whole product.
##   * The Continue button sends `continue`, the Reverse-continue button sends
##     `reverseContinue`, both reach the engine and both move the session —
##     with no breakpoints set they run to the end (step 0 -> 1314 of 1315) and
##     back to the start (1314 -> 0).
##   * A `setBreakpoints` frame injected onto that same wire came back
##     `success: true` with every breakpoint `verified: true`, and Continue
##     then stopped at them.
##
## So the engine, the toolbar, the command spellings and the stop-event path
## were all already in place. What was missing was a gesture that names a line
## and a request that tells the engine about it. That is this module.
##
## ## WHICH PATH, and why it is the RELATIVE one
##
## The same subtlety `live_source.nim` documents at length, and it bites here
## for the same reason. The engine REPORTS positions at the recording
## machine's absolute path — measured, on the `noir_space_ship` fixture:
##
##     /private/tmp/blocktracer-fixture-rec/noir_space_ship/src/main.nr
##
## while the island — and therefore this pane, and therefore every line a
## visitor can click — carries the interned relative path `src/main.nr`.
##
## `setBreakpoints` is resolved by `db.rs`'s `load_path_id`, which is
## `reader.fuzzy_path_id_for(path)`: a FUZZY match against the trace's own
## path table. Measured on that fixture, sending the relative `src/main.nr`
## returns `verified: true` for all 38 lines and Continue then stops at them.
##
## So this module sends the path the DOCUMENT carries and never the one the
## engine reports. Do not "correct" it to the absolute path to make the two
## agree — that is the change `live_source.nim` warns silently removes the
## feature, and the same warning applies verbatim here.
##
## ## Replace semantics, and why the whole per-path set is always sent
##
## DAP `setBreakpoints` REPLACES every breakpoint for the source it names —
## `dap_handler.rs` calls `clear_breakpoints_for_source` before registering
## the request's lines. So a request carrying one line does not add a
## breakpoint, it makes that line the ONLY breakpoint in the file. Every send
## from here therefore carries the complete set for that path, and toggling a
## line off is the same request with one fewer line rather than a delete.

import std/[algorithm, json, sequtils, sets, strutils, tables]

type
  BreakpointSet* = object
    ## Which lines of which files the visitor has marked.
    ##
    ## Keyed by the DOCUMENT's path — the interned, relative spelling the
    ## island publishes and the pane renders — for the reason the header
    ## gives: that is the spelling the engine's fuzzy path lookup resolves,
    ## and it is the only one a click on a rendered line can name.
    byPath: Table[string, HashSet[int]]

proc initBreakpointSet*(): BreakpointSet =
  BreakpointSet(byPath: initTable[string, HashSet[int]]())

proc contains*(s: BreakpointSet; path: string; line: int): bool =
  ## Is there a breakpoint on this line of this file?
  path in s.byPath and line in s.byPath[path]

proc linesFor*(s: BreakpointSet; path: string): seq[int] =
  ## The marked lines of one file, ascending.
  ##
  ## Sorted rather than in insertion order: this is what goes on the wire and
  ## what is written to storage, and an unordered set would make two equal
  ## sets serialise differently on different runs — which turns "did the
  ## breakpoints change" into a question about hash iteration order.
  if path notin s.byPath: return @[]
  result = toSeq(s.byPath[path].items)
  result.sort()

proc paths*(s: BreakpointSet): seq[string] =
  ## Every file that currently has at least one breakpoint, sorted.
  ##
  ## A path whose last breakpoint was toggled off is KEPT here with an empty
  ## set, deliberately — see `toggle`. It has to be, or clearing the last
  ## breakpoint in a file would send no request for that file and the engine
  ## would keep the breakpoint it was never told about.
  result = toSeq(s.byPath.keys)
  result.sort()

proc isEmpty*(s: BreakpointSet): bool =
  ## Are there no breakpoints anywhere?
  ##
  ## Not `byPath.len == 0`: a path emptied by `toggle` is retained, so the
  ## table can be non-empty while the visitor has no breakpoints at all.
  for _, lines in s.byPath:
    if lines.len > 0: return false
  true

proc count*(s: BreakpointSet): int =
  ## How many breakpoints there are, across every file.
  for _, lines in s.byPath:
    result += lines.len

proc toggle*(s: var BreakpointSet; path: string; line: int): bool =
  ## Add or remove one breakpoint. Returns whether it is now SET.
  ##
  ## The path's entry is created on the first toggle and never removed, even
  ## when its set becomes empty. That is what makes "the visitor cleared the
  ## last breakpoint in this file" expressible on the wire at all: the engine
  ## clears a source's breakpoints only when it receives a `setBreakpoints`
  ## naming that source, so a path that vanished from this table would leave
  ## its breakpoints registered in the engine with nothing left in the UI to
  ## explain why Continue kept stopping.
  if path notin s.byPath:
    s.byPath[path] = initHashSet[int]()
  if line in s.byPath[path]:
    s.byPath[path].excl(line)
    false
  else:
    s.byPath[path].incl(line)
    true

proc requestFor*(s: BreakpointSet; path: string): JsonNode =
  ## The `setBreakpoints` arguments for one file.
  ##
  ## Both `breakpoints` and `lines` are sent. They are the structured and the
  ## legacy spelling of the same fact, and `dap_handler.rs` prefers the first
  ## and falls back to the second — sending both costs a few bytes and means
  ## this request is understood by either arm.
  let lines = s.linesFor(path)
  let name = if path.contains('/'): path.rsplit('/', 1)[1] else: path
  %*{
    "source": {"name": name, "path": path},
    "breakpoints": lines.mapIt(%*{"line": it}),
    "lines": lines,
  }

# ---------------------------------------------------------------------------
# PERSISTENCE: NOT DECIDED HERE, AND DELIBERATELY NOT IMPLEMENTED
# ---------------------------------------------------------------------------
#
# Breakpoints live for the lifetime of the document and are gone on reload.
# That is not an omission; it is the only answer this module is entitled to
# give, and `Debugger-Integration.md` §10.8 says so in as many words:
#
#     **Open: do breakpoints survive a reload?** Not decided here, and the
#     arguments run both ways. … That is a privacy-surface decision wearing a
#     debugger feature's clothes, and it needs answering **before**
#     breakpoints ship, not after.
#
# The sharpness is in what it would COST rather than in the storage API. This
# product persists NOTHING today: the Settings page names the two things that
# would — the keybinding set and the pane layout — and renders them as a stub,
# on the honest ground that per-browser storage needs script the pre-hydration
# page does not ship. So the first `localStorage.setItem` in this repository is
# not a convenience, it is the moment §12's claim that a visitor "chooses
# nothing that affects where a byte comes from" acquires an exception, and it
# would be settled by a debugger feature rather than by anyone weighing it.
#
# An earlier draft of this file DID persist, keyed by the trace content hash,
# and it was removed rather than kept behind a flag — a flag would have been
# the same decision made quietly, with a default someone would ship.
#
# The three candidates, recorded so the decision does not have to be
# rediscovered when it is taken:
#
#   * The DEEP LINK (§6.0a's payload). Makes a breakpoint set SHARED rather
#     than KEPT, which §10.8 flags as a different feature — and the query is
#     written by `positionQuery(contentHash, step, anchor)`, one function whose
#     four call sites all build the href of a ROW. A copied row link would
#     carry the visitor's breakpoints into whoever opened it.
#   * `localStorage`, keyed by the content hash. Keys on the ARTEFACT rather
#     than the URL, so one recording reached by two links has one set. This is
#     the cheapest and is what the removed draft did.
#   * OPFS. `client/` has no OPFS layer; the only one in reach is the Embed
#     SDK's `host/opfs_volume.nim`, which is async and permissioned and built
#     for file VOLUMES — a large dependency for a set of integers, and its
#     asynchrony would put an `await` in front of a pane that has none.
#
# Until that is answered, `loadBreakpoints` returns an empty set. It exists as
# a named seam rather than as an inlined `initBreakpointSet()` so that the
# decision, when it is taken, has exactly one place to land — and so that a
# reader of `hydrate.nim` sees a question that was asked rather than a
# behaviour that was never considered.

proc loadBreakpoints*(contentHash: string): BreakpointSet =
  ## This recording's breakpoints at page load: none, pending §10.8.
  ##
  ## Takes the content hash it would key on, and ignores it. The parameter is
  ## kept because every candidate above keys on exactly this value, so the
  ## signature is the one the decision needs and the call site will not move.
  discard contentHash
  initBreakpointSet()
