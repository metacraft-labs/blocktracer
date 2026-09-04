## Static site generator for the BlockTracer IsoNim client.
##
## One command produces a servable `dist/` that combines the demo DATA plane and
## the rendered CLIENT:
##
##   1. Wire the demo generator (blocktracer-demo-gen) straight into dist: call
##      `generate` in-process so the `/d`, `/idx`, `/t`, `/registry` object tree
##      and the pre-rendered per-entity entry pages land under dist/. This is the
##      exact tree the real pipeline will emit (the M5b contract) — the client
##      never learns which producer wrote it.
##   2. Render the explorer views (home, chain overview, block list, block
##      detail, transaction detail) from that same tree via the isonim SSR
##      string renderer + the codetracer-design-system token layer, and write
##      them at their clean URLs — OVERWRITING the generator's minimal entry
##      pages with the full client render (the M5/M9 render, not §4.3's minimal
##      per-entity page).
##   3. Copy the vendored brand fonts and emit sitemap.xml + robots.txt.
##
## Usage:
##   nim c -r --mm:orc -d:isServer -d:release src/static_export.nim
##   # or via the Justfile:  just export

import std/[os, strutils, times, algorithm, sets, tables, json]
import blocktracer/contract/hashshard   # §5's shard codec + its published depth
import blocktracer/demo/generator
import blocktracer/chain/ingest
import ssr
import reader
import debugger/replay_engine
import components/layout   # `SearchBundle`/`SettingsBundle` — the URLs those <script>s name

const
  OutputDir = "dist"
  DefaultSeed = "blocktracer-demo-0"

proc repoRoot(): string =
  ## <repo>/client/src/static_export.nim → <repo>.
  currentSourcePath().parentDir.parentDir.parentDir

proc ensureDir(path: string) =
  if not dirExists(path): createDir(path)

proc writeCleanUrl(path, html: string) =
  ## dist/path/index.html (clean URLs); "/" → dist/index.html.
  let outputPath = if path == "/": OutputDir / "index.html"
                   else: OutputDir / path.strip(chars = {'/'}) / "index.html"
  ensureDir(parentDir(outputPath))
  writeFile(outputPath, html)

proc copyFonts() =
  let src = repoRoot() / "client" / "src" / "assets" / "fonts"
  if dirExists(src):
    let dest = OutputDir / "assets" / "fonts"
    ensureDir(OutputDir / "assets")
    ensureDir(dest)
    for kind, path in walkDir(src):
      if kind == pcFile:
        copyFile(path, dest / extractFilename(path))

const MtimeFloor = 315_532_800'i64
  ## 1980-01-01T00:00:00Z. Nix writes every file in the store with mtime 1, on
  ## purpose, so an mtime read off a store path is not OLD — it is ABSENT, and
  ## reporting "stale" about it would be a confident wrong answer. Same constant
  ## and same sentence as `tools/capture/lib/build-freshness.mjs`'s
  ## `MTIME_FLOOR_MS`, which asks this question on the CONSUMER side.

proc newestSourceIn(dirs: openArray[string]): tuple[path: string, at: Time] =
  ## The most recently modified compilable input under `dirs`.
  ##
  ## `.nim`/`.nims`/`.cfg` only. The three bundles this file installs are `.js`
  ## written INTO two of these directories, so a walk that counted them would
  ## compare a build against itself and could never report stale. `nimcache*`
  ## is skipped for the same reason.
  result = ("", fromUnix(0))
  for d in dirs:
    if not dirExists(d): continue
    for path in walkDirRec(d):
      let (dir, _, ext) = splitFile(path)
      if ext notin [".nim", ".nims", ".cfg"]: continue
      if "nimcache" in dir: continue
      let at = try: getLastModificationTime(path) except CatchableError: continue
      if at > result.at: result = (path, at)

proc requireFreshBundle(built: string; sourceDirs: openArray[string];
                        what, remedy: string) =
  ## The half `fileExists` could not ask: is this bundle OF THIS SOURCE?
  ##
  ## ## Why the three call sites needed more than an existence test
  ##
  ## Each of them reasons, correctly and at length, about a `<script>` that
  ## 404s — the affordance-that-lies defect with a build error's cause — and
  ## each answers it with `fileExists` and the message "Build it first". That
  ## remedy names EXACTLY the condition the guard cannot detect: once the
  ## bundle has been built once, `fileExists` is true forever. All three are
  ## gitignored outputs written in place by `nim js`, and nothing cleans them.
  ##
  ## So a bundle compiled from an older `hydrate.nim` is copied into the
  ## published site under the current name, and every downstream gate then
  ## passes — `check-assets.mjs` because the reference resolves and the file is
  ## non-empty, `check-freshness.mjs` because the staged byte IS the built byte
  ## (the build step faithfully copied a stale input), the capture corpus
  ## because it photographs whatever the page does. The page does not 404. It
  ## hydrates into last week's behaviour, silently, which is worse: a 404 is
  ## visible in a console and this is not.
  ##
  ## THE ASYMMETRY THIS CLOSES. `tools/capture/lib/build-freshness.mjs`'s
  ## `SITE_ARTEFACTS` lists these three paths by name as the artefacts a rebuild
  ## must have rewritten — the CONSUMERS have asked this question since the
  ## capture sweep. The PRODUCER, which is the last place the bundle can still
  ## be refused before it is published, did not.
  ##
  ## ## The three answers that are not "stale"
  ##
  ## Refuses only when it can say so. A store-epoch mtime means the question
  ## cannot be asked (`nix build` is hermetic and its inputs carry mtime 1), and
  ## an empty source walk means the same; both continue, and say which sentence
  ## they mean, because a gate that cried wolf on the ordinary hermetic build
  ## would be deleted within a day and then absent for the real case.
  let builtAt = getLastModificationTime(built)
  if builtAt.toUnix < MtimeFloor:
    echo "  ~ ", what, ": mtime ", $builtAt, " is the epoch stamp Nix gives store files, ",
         "so freshness cannot be judged here. Copying it."
    return
  let newest = newestSourceIn(sourceDirs)
  if newest.path.len == 0:
    echo "  ~ ", what, ": no .nim/.nims/.cfg found under ", sourceDirs.join(", "),
         " — freshness cannot be judged here. Copying it."
    return
  if newest.at <= builtAt: return
  stderr.writeLine what & " is stale: " & built
  stderr.writeLine "  built   " & $builtAt
  stderr.writeLine "  but     " & newest.path & " changed " & $newest.at
  stderr.writeLine "  Publishing it would ship a page that hydrates into the behaviour of an"
  stderr.writeLine "  older source, under the current name. Nothing downstream can see that:"
  stderr.writeLine "  the reference resolves, the file is not empty, and the staged byte IS the"
  stderr.writeLine "  built byte. A 404 would at least be visible."
  stderr.writeLine "  " & remedy
  quit 2

proc installHydrationBundle() =
  ## Put the built hydration bundle where the pages say it is — or fail.
  ##
  ## `HydrationBundle` is a build-time URL (`replay_engine.nim`) and its
  ## default is empty, which is a build that ships no script and produces the
  ## page this route has always produced. That case does nothing here, and it
  ## must not warn: it is the ordinary shape of a build without the CodeTracer
  ## Embed SDK on its Nim path.
  ##
  ## When it is NOT empty, the page carries a `<script src=…>`, and a `<script>`
  ## pointing at a 404 is the one outcome this must never produce quietly. It is
  ## not merely a dead script tag — it is the page CLAIMING to hydrate while its
  ## controls sit inert forever, saying they are waiting for an engine nothing
  ## will ever ask for. That is the affordance-that-lies defect with a build
  ## error's cause, so it is made a build error: `quit 2`, at the point where a
  ## missing file is still cheap to notice.
  if HydrationBundle.len == 0: return
  let built = repoRoot() / "client" / "hydrate" / "hydrate.js"
  if not fileExists(built):
    stderr.writeLine "hydration bundle not built: " & built
    stderr.writeLine "  This build declares -d:hydrationBundle=" & HydrationBundle &
                     ", so every debug page carries a <script> for it."
    stderr.writeLine "  Build it first (cd client && just hydrate) or drop the define."
    quit 2
  requireFreshBundle(built,
                     [repoRoot() / "client" / "hydrate",
                      repoRoot() / "client" / "src",
                      repoRoot() / "src"],
                     "hydration bundle",
                     "Build it first (cd client && just hydrate) or drop the define.")
  let dest = OutputDir / HydrationBundle.strip(chars = {'/'})
  ensureDir(parentDir(dest))
  copyFile(built, dest)
  echo "  + hydration bundle: " & HydrationBundle & " (" &
    $(getFileSize(built) div 1024) & " KB)"

proc buildGlobalHashIndex(routes: seq[string]) =
  ## §5's global hash index — "which chains hold this hash, and as what kind of
  ## entity?" — built over EVERY published chain, from the same route
  ## enumeration that decides which pages exist.
  ##
  ## ## Why this is here and not in a producer
  ##
  ## Because the artifact is GLOBAL and the producers are not. The demo
  ## generator already emitted `/idx/hash/{version}/{prefix}.bin`, and it
  ## emitted it from inside a per-chain generation — so it indexed `demo` and
  ## nothing else, and `chain/ingest.nim` writes `idx: nil` for a captured
  ## chain, so the two real Aztec chains were in no index at all. Measured on a
  ## hydrated build of 37afe34: 52 shards, 56 entries, every one of them
  ## `demo`; `/aztec`'s own generation root carried no `idx` descriptor.
  ##
  ## That is worse than an index that does not exist, because §5's contract is
  ## that "a hit is definite" and therefore a MISS is definite too. A prefix
  ## search served from a demo-only index would have answered "no chain holds
  ## this" for every real transaction on the site — a confident false absence,
  ## which is the exact defect class this route has already been through once.
  ##
  ## Two per-chain producers writing one global path would also have raced:
  ## `/idx/hash/{v}/{prefix}.bin` has no chain segment, so the second writer
  ## wins and the first chain silently vanishes from the index. One global
  ## artifact needs one writer, and this is the only place that has seen every
  ## chain.
  ##
  ## `routes` is that place's evidence. It is the enumeration `staticRoutes`
  ## already produced to decide which pages to render, so the index covers
  ## exactly what the site publishes, by construction rather than by a second
  ## walk that could disagree with the first.
  var entries: seq[HashEntry]
  var seen = initHashSet[string]()
  for route in routes:
    # `/{chain}/{kind}/{id}` — and nothing longer. `/tx/{h}/debug` is the same
    # transaction at a second address, and a second entry for it would make the
    # index claim two objects where there is one.
    let parts = route.strip(chars = {'/'}).split('/')
    if parts.len != 3: continue
    let (chain, kindSeg, id) = (parts[0], parts[1], parts[2])
    let kind = kindOfRouteSegment(kindSeg)
    if kind == 0: continue
    let key = chain & "/" & $kind & "/" & id
    if key in seen: continue
    seen.incl key
    entries.add HashEntry(hexHash: id, chain: chain, kind: kind)

  if entries.len == 0:
    # Nothing published has a hash. Emitting an empty index would publish a
    # descriptor asserting that the index is authoritative over a corpus it
    # does not contain, and the browser would read a definite "no" from it.
    echo "  ! global hash index: no hash-addressable routes; not published"
    return

  var byPrefix = initTable[string, seq[HashEntry]]()
  for e in entries:
    byPrefix.mgetOrPut(hashPrefix(e.hexHash, HashShardPrefixLen), @[]).add e
  var prefixes: seq[string]
  for p in byPrefix.keys: prefixes.add p
  prefixes.sort()

  var largest = 0
  for p in prefixes:
    let bytes = encodeHashShard(byPrefix[p], HashShardPrefixLen)
    if bytes.len > largest: largest = bytes.len
    let rel = "idx" / "hash" / HashIndexVersion / p & ".bin"
    ensureDir(parentDir(OutputDir / rel))
    writeFile(OutputDir / rel, bytes)

  # THE DESCRIPTOR, which the spec does not define and the client cannot work
  # without.
  #
  # Search-And-Routing §5 requires the client to "compute the shard path
  # directly" AND requires shard depth to vary — §5.3: "shard depth follows
  # arithmetically from the total entry count across all chains, and should be
  # recomputed rather than fixed: more chains or more history means a deeper
  # prefix". Those two are only compatible if the depth is discoverable, and §5
  # names no carrier for it: the `meta.json` in that spec belongs to §6's name
  # index, and the `{version}` in the path is given no source either.
  #
  # So this file closes the gap, deliberately mirroring §6's meta.json rather
  # than inventing a shape — same directory position, same "shard count, hash
  # function, entry count" role. `prefixLen` is what makes the depth a
  # published fact instead of a constant compiled into a client, which is what
  # `client/searchboot/` reads it as: it derives the minimum usable prefix
  # length from this number and never hardcodes one. `shards` lets a query for
  # an unoccupied prefix be answered definitively with ZERO requests.
  var shardsJson = newJArray()
  for p in prefixes: shardsJson.add %p
  writeFile(OutputDir / "idx" / "hash" / "meta.json", pretty(%*{
    "indexVersion": HashIndexVersion,
    "prefixLen": HashShardPrefixLen,
    "shardCount": prefixes.len,
    "entryCount": entries.len,
    "largestShardBytes": largest,
    "shards": shardsJson}))
  echo "  + global hash index: " & $entries.len & " entries over " &
    $prefixes.len & " shards (prefixLen " & $HashShardPrefixLen &
    ", largest " & $largest & " B)"

proc installSearchBundle() =
  ## Put the built search bundle where `/search` says it is — or fail.
  ##
  ## Exactly the shape of `installHydrationBundle` above, and for a reason that
  ## is sharper here rather than weaker. `/search` is the route whose entire
  ## defect was an affordance that rendered and could not act: the form
  ## submitted, the page loaded, every layer reported success and nothing
  ## resolved. A `<script>` pointing at a 404 would restore precisely that
  ## state, with the page now also claiming — in its own copy — that resolution
  ## runs in the browser. So a missing bundle is `quit 2` at build time, not a
  ## silent 404 at visit time.
  if SearchBundle.len == 0: return
  let built = repoRoot() / "client" / "searchboot" / "search.js"
  if not fileExists(built):
    stderr.writeLine "search bundle not built: " & built
    stderr.writeLine "  This build declares -d:searchBundle=" & SearchBundle &
                     ", so /search carries a <script> for it."
    stderr.writeLine "  Build it first (cd client && just search-bundle) or drop the define."
    quit 2
  requireFreshBundle(built,
                     [repoRoot() / "client" / "searchboot",
                      repoRoot() / "client" / "src",
                      repoRoot() / "src"],
                     "search bundle",
                     "Build it first (cd client && just search-bundle) or drop the define.")
  let dest = OutputDir / SearchBundle.strip(chars = {'/'})
  ensureDir(parentDir(dest))
  copyFile(built, dest)
  echo "  + search bundle: " & SearchBundle & " (" &
    $(getFileSize(built) div 1024) & " KB)"

proc installSettingsBundle() =
  ## Put the built settings bundle where `/settings` says it is — or fail.
  ##
  ## The same `quit 2` as the two above, and the reason it is not merely
  ## consistency: a page at this address was DELETED for having controls-worth
  ## of prose and no controls. The page that replaced it serves a preset
  ## chooser `hidden`, to be unhidden by this bundle. A build that shipped the
  ## page without the bundle would serve a settings page whose only control is
  ## invisible — which is the deleted page again, arriving by a build accident
  ## rather than by a decision, and looking from the outside exactly like the
  ## thing that was just fixed.
  if SettingsBundle.len == 0: return
  let built = repoRoot() / "client" / "settingsboot" / "settings.js"
  if not fileExists(built):
    stderr.writeLine "settings bundle not built: " & built
    stderr.writeLine "  This build declares -d:settingsBundle=" & SettingsBundle &
                     ", so /settings carries a <script> for it."
    stderr.writeLine "  Build it first (cd client && just settings-bundle) or drop the define."
    quit 2
  requireFreshBundle(built,
                     [repoRoot() / "client" / "settingsboot",
                      repoRoot() / "client" / "src",
                      repoRoot() / "src"],
                     "settings bundle",
                     "Build it first (cd client && just settings-bundle) or drop the define.")
  let dest = OutputDir / SettingsBundle.strip(chars = {'/'})
  ensureDir(parentDir(dest))
  copyFile(built, dest)
  echo "  + settings bundle: " & SettingsBundle & " (" &
    $(getFileSize(built) div 1024) & " KB)"

proc generateSitemap(routes: seq[string]) =
  var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  xml.add "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
  for route in routes:
    xml.add "  <url><loc>" & SiteDomain & route & "</loc></url>\n"
  xml.add "</urlset>\n"
  writeFile(OutputDir / "sitemap.xml", xml)

proc generateRobots() =
  writeFile(OutputDir / "robots.txt",
    "User-agent: *\nAllow: /\nSitemap: " & SiteDomain & "/sitemap.xml\n")

proc exportSite() =
  let startTime = epochTime()

  # Fresh output tree.
  if dirExists(OutputDir): removeDir(OutputDir)
  ensureDir(OutputDir)

  # Step 1: ingest every captured live-chain snapshot. Two producers, one tree, one
  # contract — everything below (route enumeration, reader, the five §7.0 views, the
  # validator) is shared, because a second chain is data rather than a second explorer.
  #
  # THE REAL CHAINS GO FIRST, AND THE ORDER IS THE POINT. They used to go second, behind
  # the demo, which was harmless while the demo owned a slug of its own. It is not
  # harmless now that the Aztec mainnet IS `/aztec`: whoever writes second is the one
  # able to overwrite, so the producer that must never overwrite a real chain is the one
  # that has to run last and check. The real chains are the site's subject; the fixture
  # is a guest.
  #
  # ITS ABSENCE IS A VALID BUILD, and deliberately so: a checkout without a
  # capture serves exactly the synthetic demo it always did. What must never
  # happen is the opposite — a snapshot present and silently half-ingested — so
  # `ingestSnapshot` raises rather than skipping a transaction it cannot publish.
  # EVERY capture in the tree, in a stable order. A second real chain is a
  # directory, not a code change — which is the whole claim the two-producer
  # split makes, and this loop is where it is either true or it is not.
  let chainFixtures = repoRoot() / "client" / "fixtures" / "chain"
  var snapshotDirs: seq[string]
  if dirExists(chainFixtures):
    for kind, path in walkDir(chainFixtures):
      if kind == pcDir and fileExists(path / "snapshot.json"):
        snapshotDirs.add path
  sort(snapshotDirs)
  if snapshotDirs.len == 0:
    echo "  + live-chain snapshots: none in this checkout (synthetic demo only)"
  for snapshotDir in snapshotDirs:
    # `isCurated`, and the choice is here rather than defaulted in the ingest —
    # see `IngestScope`. The deployed site's promise about a real chain is that
    # every transaction on it opens a container that steps, and the shape of the
    # data made the uncurated tree unable to keep it: the mainnet capture is 994
    # blocks and 27 transactions with no trace on any of them, because Aztec
    # prunes a body at the finalized tip and the arrivals are further apart than
    # the replay window is wide. Publishing all of it put ~30 pages of honest
    # paragraph where the product should be. The transactions that are left out
    # are still IN the snapshot, still counted in the banner, and still published
    # in full by an `isFull` ingest — which is the scope their pages are graded
    # in (`test_chain_provenance`).
    let ing = ingestSnapshot(IngestConfig(outDir: OutputDir,
                                          snapshotDir: snapshotDir,
                                          scope: isCurated))
    # A chain with NO traces is reported as such rather than omitted. It is the
    # expected outcome on a chain whose transactions arrive further apart than
    # the replay window is wide, and a build log that quietly said nothing about
    # it would be the first place the fact went missing.
    let traceNote =
      if ing.withTrace == 0: "NO replayable transaction in the window"
      else: $ing.withTrace & " with a published trace (" & $ing.divergent &
            " divergent, " & $ing.containerBytes & " bytes)"
    echo "  + live-chain snapshot: /" & ing.chain & " — published " &
      $ing.blocks & " blocks (" & $ing.windowFrom & "–" & $ing.windowTo &
      "), " & $ing.transactions & " transactions, " & traceNote &
      "; watched " & $ing.observedBlocks & " blocks / " &
      $ing.observedTransactions & " transactions"

  # Step 1b: the SYNTHETIC demo tree — published again, and the reason is the front page.
  #
  # IT WAS TURNED OFF ONE COMMIT AGO, ON A PREMISE THAT WAS TRUE AND INCOMPLETE. The
  # premise: "the deployed site carries real chains only", because the fixture is the
  # subject of the review corpus and of the exporter-driven suites, and those are reasons
  # to keep GENERATING it rather than to SERVE it. What that missed is that the fixture is
  # also the only SOURCE-LEVEL recording this tree can publish, and the home page's
  # exhibit needs one.
  #
  # Every real chain in TODAY'S FROZEN CAPTURES is rung 3, and the sentence that used to
  # sit here said something stronger and wrong: that `ingest.nim` "will go on doing so for
  # every Aztec transaction this site ever records". It will not, and the correction
  # matters because this file is where the consequence is spent.
  #
  # WHAT IS TRUE: an Aztec `ContractClassPublic` carries bytecode and no `debug_symbols`,
  # no `file_map` and no source text, so a NODE can never position a step against a line.
  # WHAT WAS MISSING: upstream's own doc comment says `artifactHash` exists so a client can
  # "verify that an OFFCHAIN FETCHED ARTIFACT matches a registered class" — the chain holds
  # a commitment, not the artifact — and `aztec-avm-runtime` now performs that fetch and
  # that verification. A contract whose artifact is proved against its class's
  # `artifactHash`, its `packedBytecode` and its class id records at RUNG 1 with real Noir
  # positions, and `ingest.nim` publishes `execution.sourceLevel: true` with a source
  # bundle for it.
  #
  # WHY THE CONCLUSION BELOW SURVIVES THE CORRECTION UNCHANGED. It is a fact about the
  # captures this site actually carries, and that fact is measured: of the six frozen
  # testnet containers exactly one executes a class anybody publishes (FeeJuice at
  # `0x…03`), and neither mainnet container does — their third-party classes have no
  # artifact on npm and none verified on any explorer. So a tree of today's real chains
  # still contains nothing that can show a line of source, and the home page's
  # `canHeadline` rule still finds nothing to feature. It featured a rung-3 recording
  # instead, which is how three sentences about what cannot be shown ended up under
  # "the deepest view into every transaction".
  #
  # THE DAY A SOURCE-LEVEL CAPTURE IS FROZEN INTO THIS TREE, THIS BLOCK IS WRONG AGAIN —
  # `canHeadline` will have a real chain to feature and the fixture's role as the site's
  # only source-level exhibit ends. That is a change to make deliberately, with the
  # capture, rather than something to discover.
  #
  # So both halves are kept rather than traded: the real chains are the site's SUBJECT and
  # lead the chain strip (`home.stripOrder`, keyed off published provenance), and the
  # fixture is the site's EXHIBIT and is labelled as one everywhere it appears — the strip
  # badges it `synthetic`, the chain banner does, and the home page's embed carries the
  # same badge (`home.liveDemo`). A reader is never asked to tell them apart by the slug.
  #
  # `-d:noDemoChain` builds the real-chains-only tree, which is what the previous default
  # produced; nothing in this repository sets it, and it exists so the question can be
  # asked of a build rather than argued about again.
  #
  # The trace fixture is still required: the real `noir_space_ship` container carries no
  # source text, so without the Noir sources the exported site would step through code it
  # cannot show.
  when not defined(noDemoChain):
    let fixtureDir = repoRoot() / "fixtures" / "trace" / "noir_space_ship"
    let fixture = fixtureDir / "zk_shields.ct"
    let sources = fixtureDir / "sources"
    if not fileExists(fixture):
      stderr.writeLine "trace fixture not found: " & fixture
      quit 2
    if not dirExists(sources):
      stderr.writeLine "trace sources not found: " & sources
      quit 2
    # The guard, at the composition root — the one place both producers meet. It refuses
    # rather than trusting the slugs not to have collided, which is what the rule it
    # replaced did in the other direction.
    # The capability tour's corpus: eight small Noir programs, each with its own
    # recording. It is what makes this chain worth visiting rather than a
    # fixture with a URL — before it, the same container stood behind every
    # transaction here, so "open a transaction" and "open the fixture" were one
    # act. Required, not optional: a demo chain that silently lost its tour
    # would look exactly like one that never had it.
    let tourDir = repoRoot() / "fixtures" / "trace" / "tour"
    if not fileExists(tourDir / "manifest.json"):
      stderr.writeLine "capability tour manifest not found: " &
                       (tourDir / "manifest.json")
      quit 2
    assertSlugAvailable(OutputDir, DemoChainSlug, "synthetic")
    let n = generate(DemoConfig(outDir: OutputDir, seed: DefaultSeed,
                                chain: DemoChainSlug,
                                traceFixturePath: fixture,
                                traceSourcesDir: sources,
                                tourDir: tourDir))
    echo "  + synthetic demo chain: /" & DemoChainSlug & " (" & $n & " transactions) " &
      "— published, badged `synthetic`; build -d:noDemoChain to leave it out"
  else:
    echo "  + synthetic demo chain: not published (this build set -d:noDemoChain)"

  # Step 2: render the explorer views over that tree, at clean URLs.
  let root = newDataRoot(OutputDir)
  let routes = staticRoutes(root)
  var rendered = 0
  for route in routes:
    let (status, body, _) = renderRoute(root, route)
    if status == 200:
      writeCleanUrl(route, body)
      inc rendered
    else:
      echo "  ! " & route & " (status " & $status & ")"
  echo "  + client views: " & $rendered &
    " pages (home, chains, chain, blocks, block, txs, tx, debug, address, code, search, about)"

  # §5's global hash index, over the routes just rendered. After the render
  # loop because it is built from the same enumeration: whatever got a page is
  # what the index claims to cover, and neither can drift from the other.
  buildGlobalHashIndex(routes)

  # The not-found body, at the file a static host serves for an unmatched path.
  #
  # SEO-And-Crawl-Budget.md §6 class G0: "Real `404`, never a successful
  # generic shell", and "unknown paths must produce genuine `404` responses
  # rather than mapping every path to `index.html`". The BYTES are the same
  # ones `renderRoute` returns with a 404 status, taken from `renderRoute`
  # itself rather than re-rendered here: a 404 file that differs from the 404
  # body is two answers to one question, and only one of them would be tested.
  let (notFoundStatus, notFoundBody, _) = renderRoute(root, "/__not_found__")
  doAssert notFoundStatus == 404, "renderRoute stopped 404ing an unknown path"
  writeFile(OutputDir / "404.html", notFoundBody)
  echo "  + 404.html (Page-Descriptions §14 'not on this chain')"

  # Step 3: assets + crawl files.
  copyFonts()
  installHydrationBundle()
  installSearchBundle()
  installSettingsBundle()
  # `sitemapRoutes`, not `routes`: every route is RENDERED, and a `noindex`
  # route is not SUBMITTED (SEO-And-Crawl-Budget.md §5). The debug route is the
  # transaction's content at a second address, so a sitemap entry for it would
  # invite a crawler to fetch a duplicate and be told not to index it.
  generateSitemap(sitemapRoutes(root))
  generateRobots()

  let elapsed = epochTime() - startTime
  echo "\nExported " & $rendered & " client pages over the demo data tree in " &
    formatFloat(elapsed, ffDecimal, 2) & "s -> " & OutputDir & "/"

when isMainModule:
  echo "Building BlockTracer static site -> " & OutputDir & "/"
  exportSite()
