## The recording's own source, into the engine's VFS.
##
## ## What this is for
##
## The value-origin classifier works by parsing the right-hand side of the
## source assignment that produced a value (Value-Origin-Tracking.md §6.1:
## `parse_assignment` over the line the write happened on). In a browser it
## could never get one. `ExprLoader` read source with `fs::read_to_string`,
## which is `Unsupported` on `wasm32-unknown-unknown`, so every value of every
## transaction answered `ct/originChain` with a **successful** reply carrying
## one hop of `kind: "unknown"`, `confidence: 0`,
## `classificationProvenance: "built-in: source unavailable"`. That is
## `docs/NOIR-RECORDER-DEFECTS.md`'s NR-05, and it is why that entry says
## wiring an origin control ahead of it "would ship a control that answers
## 'unknown source' on every value of every transaction".
##
## CodeTracer's `b9cd4157` gave `ExprLoader::file_source_code` a VFS fallback,
## so the engine can now read source a host put in memory. This module is the
## host putting it there.
##
## ## Why BlockTracer already has the bytes
##
## It publishes them. Every session page carries a source island
## (`source_island.nim`, element id `bt-session-source`) holding the whole of
## each source file the recording covers — that is what the Code pane renders
## from, and it is served with the page whether or not any script runs. So
## there is no new artefact, no new fetch and no new publishing step here: the
## source the engine needs is already in the document, and this module hands
## the same text to the engine that the pane is already drawing.
##
## A recording that published no source (every chain capture — `sourceBundles`
## is empty and `execution.sourceLevel` is false on all eight in the corpus)
## has an empty island, and this module writes nothing. That is the honest
## outcome: those recordings are rung 3, they carry neither source nor variable
## names, and no amount of wiring makes a chain over them meaningful.
##
## ## WHICH PATH, and why it is the RELATIVE one
##
## This is the whole subtlety, and getting it wrong looks like success.
##
## Position resolution and origin classification do NOT probe the same path.
## `Location.missing_path` — what `editor_service.nim` reads to choose between
## the editor pane and NO SOURCE — is computed from the ABSOLUTE recorded path.
## The classifier's probe is built separately, in `db.rs:3186-3192`:
##
##     let path_str = self.reader.path(step_record.path_id)...;  // "src/main.nr"
##     let workdir_path = self.reader.workdir().join(&path_str); // absolute
##     let probe_path = if workdir_path.exists() { workdir_path }
##                      else { PathBuf::from(&path_str) };       // RELATIVE
##
## `Path::exists()` is hardwired `false` on `wasm32-unknown-unknown` — the very
## defect the VFS work removed from `missing_path` — so in a browser that
## `if` can only ever take the else-branch, and the classifier looks for the
## bare `src/main.nr`.
##
## Measured on `demo/tx/0x5c67…` (the `noir_space_ship` recording) with
## `tools/journeys/origin-probe.mjs`: writing ONLY the absolute path flips
## `missing_path` to false — the VFS read demonstrably works — while the engine
## logs 105 failed reads of `src/main.nr` and every hop still answers
## "source unavailable". Writing the path the island already carries, which IS
## the relative one, is what makes the hops classify.
##
## So this module writes each document at the island's own path and nothing
## else. It needs no knowledge of the recording machine's directory layout,
## which it could not have anyway: the island is written by the exporter and
## the absolute path exists only inside the container.
##
## ## WHAT THIS COSTS, MEASURED — the flow window pays for it
##
## The relative-only write is what makes the origin chain classify, and it is
## also what starves the omniscience flow window. `find_function_location`
## (`db-backend/src/expr_loader.rs`), which fills `FlowUpdate.location`'s
## `function_name`, `first` and `last`, is gated on
## `processed_files.contains_key(&location.path)` — and `location.path` is the
## JOINED spelling, `workdir().join(recorded)` (`trace_reader.rs`). The key is
## absent, the body is skipped, and the incoming location passes through
## unchanged.
##
## Measured on the wire over the built site with the published engine staged
## (`tools/journeys/journeys/18-the-flow-window-follows-the-position.journey
## .mjs`, which is RED and ledgered with this reason): eight distinct request
## ticks, sixteen answers, EVERY one carrying `location.rrTicks = 0` and
## `functionFirst = 0` for a function whose body begins on line 12. The engine
## answers every position with the same window, so the values overlay shows one
## function's window for the life of the session — the second half of the
## user report this pair of defects was found from.
##
## Two features, one key, opposite spellings. The fix is to write BOTH, which
## is what CodeTracer's own host helper does — `vfsKeysFor(recordedPath,
## workdir)` in `platform/replay_engine_vfs.nim`: "writing both spellings costs
## one extra map entry per source file and makes the probe order stop
## mattering". It is not done here because the second key needs the recording's
## workdir, which lives inside the container and which nothing in this
## repository reads; surfacing it is a change to the PUBLISHER, not to this
## module. The engine-side fix on codetracer's `fix/wasm-source-probe` makes
## `source_probe_path` consult the filesystem and THEN the VFS, which removes
## the need for the work-around entirely — and writing both keys is correct
## either side of it, which is why the ledger entry names both.

import std/[json, strutils]

import ./engine_transport

type
  SourceFile* = object
    ## One file of the recording's source, as the island published it.
    path*: string
      ## The path the CLASSIFIER probes — see this module's header. It is the
      ## recorded path as the trace interned it, which is what the island
      ## carries and what `db.rs`'s else-branch reconstructs.
    text*: string

proc sourceFilesOf*(island: string): seq[SourceFile] =
  ## The island's documents as `{path, text}`, for writing into the VFS.
  ##
  ## Total: a malformed, empty or absent island yields no files rather than
  ## raising. A session whose island did not parse is one that shows no code
  ## either, and taking down hydration over it would replace a pane that says
  ## "no source" with a page that says nothing at all.
  ##
  ## Documents with an empty path or empty text are dropped. A zero-length
  ## entry in the VFS is worse than no entry: `file_source_code` would return
  ## `Ok("")`, the classifier's `line_text.is_empty()` guard would fire, and
  ## the hop would come back "source unavailable" — the same verdict as the
  ## absence, reached through a path that looks like it worked.
  if island.len == 0: return
  var parsed: JsonNode
  try:
    parsed = parseJson(island)
  except CatchableError:
    return
  if parsed.isNil or parsed.kind != JObject: return
  let documents = parsed{"documents"}
  if documents == nil or documents.kind != JArray: return
  for d in documents:
    if d.kind != JObject: continue
    let path = d{"path"}.getStr("").strip()
    let text = d{"text"}.getStr("")
    if path.len == 0 or text.len == 0: continue
    result.add SourceFile(path: path, text: text)

proc writeSourceToEngine*(island: string): int =
  ## Put the island's files into the engine's VFS. Returns how many were sent.
  ##
  ## The count is returned rather than discarded so the caller can say, in the
  ## one place a reader looks, whether this session gave the engine anything to
  ## classify with. Zero is a legitimate answer — a chain capture publishes no
  ## source — and it is the difference between "the origin chain found nothing"
  ## and "the origin chain was never given a chance", which are not the same
  ## sentence to put in front of a visitor.
  ##
  ## Must be called BEFORE the worker's `start`: `vfs-write` is handled by the
  ## pre-start dispatcher and is dropped without a word afterwards. See
  ## `engine_transport.postVfsWrite`.
  let files = sourceFilesOf(island)
  for f in files:
    # `f.path` IS THE ISLAND'S PATH, WHICH IS RELATIVE, AND THAT IS THE POINT.
    #
    # Do not "correct" this to an absolute path. It looks wrong — the engine
    # reports positions at `/private/tmp/blocktracer-fixture-rec/…/src/main.nr`
    # and this writes `src/main.nr` — and making the two agree is exactly the
    # change that silently removes the feature.
    #
    # The classifier does not probe the path the engine REPORTS. It builds its
    # own, at `db.rs:3186-3192`:
    #
    #     let path_str = self.reader.path(step_record.path_id)...;  // relative
    #     let workdir_path = self.reader.workdir().join(&path_str); // absolute
    #     let probe_path = if workdir_path.exists() { workdir_path }
    #                      else { PathBuf::from(&path_str) };       // RELATIVE
    #
    # `Path::exists()` is hardwired `false` on `wasm32-unknown-unknown`, so in
    # a browser that `if` can only ever take the else-branch. Measured: with
    # only the absolute path in the VFS, `Location.missing_path` flips to false
    # — proving the VFS read works — while the engine logs 105 failed reads of
    # `src/main.nr` and every hop still answers "built-in: source unavailable".
    # `tools/journeys/origin-probe.mjs --write-source --relative-only`
    # reproduces both halves.
    #
    # This is a WORK-AROUND for an engine defect and is deliberately shaped to
    # outlive its fix: if that `exists()` probe is later made VFS-aware
    # upstream, the absolute path starts resolving too and this write stays
    # correct either way, because the relative path is what the recording
    # interned and the engine keeps reconstructing it from the same table.
    postVfsWrite(f.path, f.text)
  files.len
