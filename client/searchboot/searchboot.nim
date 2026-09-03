## searchboot.nim — the half of search that has to be in a browser.
##
##     nim js -d:release -o:searchboot/search.js searchboot/searchboot.nim
##
## ## What was broken, and why nothing caught it
##
## The home page, the nav and `/search` all render a real `<form action="/search"
## method="get">`. Submitting it navigates to `/search/?q=…` and that page
## renders — so every layer reported success, and the feature did nothing. A
## static file server cannot read `?q=`, `pageLayout` ships no `<script>` by
## design, and `createSearchVM` had exactly one caller in the repository: a unit
## test. `SearchVM` is a correct, spec-derived implementation of
## Search-And-Routing §2–§4 that was never once constructed by the product.
##
## This module is the missing caller. It is the smallest thing that closes the
## chain: `?q=` in, a rendered answer out.
##
## ## It is a SEPARATE bundle from `client/hydrate/`, deliberately
##
## `hydrate.js` is 1.3 MB and links the CodeTracer Embed SDK, because it drives
## a replay session. Search needs none of that, and AGENTS.md §1a's property —
## everything outside `client/hydrate/` compiles with no debugger on the Nim
## path — is worth more than one fewer build step. Putting search in the
## debugger bundle would also have made every `/search` visit pay for a
## debugger, and made this module's gate depend on the Embed SDK being
## available to run at all.
##
## ## The mechanism it implements is §5.4's, and that is not a shortcut
##
## Search-And-Routing §5 wants two requests via `/idx/hash/{version}/{prefix}.bin`.
## That index IS published in this tree, and it is unreadable from here:
## `search_vm.nim`'s module doc records why (the `@blocktracer/client` facade
## exports no index reader, and reaching `blocktracer/contract/searchidx`
## directly is what `ci/test/client-sdk-boundary.sh` exists to prevent).
##
## §5.4 answers exactly this situation, and answers it as policy rather than as
## a degradation:
##
##   > If the index is unavailable or a version is stale, the client falls back
##   > to probing configured chains directly. Slower and noisier, never wrong.
##   > **Search must never fail because an index did not load.**
##
## So the fan-out below is the specified behaviour for a client that cannot read
## the index, not an approximation of the behaviour that would be. With three
## published chains it costs six conditional requests and resolves a hash on any
## of them.
##
## ## The split with `SearchVM`
##
## Every RULE is Nim, and every rule is the same code the VM uses:
## `canonicalHash` and `shapesOf` come from `viewmodel/search_shapes`, and the
## object paths from `blocktracer_client_paths` — the module whose whole purpose
## is that the layout lives in one place. What is JavaScript here is I/O and the
## DOM, because `ObjectStore.fetchProc` is synchronous and §4's fan-out has to be
## concurrent in a tab.
##
## `candidatesFor` below is therefore the honest seam: Nim decides what would be
## requested and where each answer lands, and returns it as data. A test can read
## that list without a browser, and the browser cannot invent a path Nim did not
## produce.

import std/strutils

import viewmodel/search_shapes
import blocktracer_client_paths
import blocktracer/contract/hashshard

type
  IndexMeta* = object
    ## `/idx/hash/meta.json`, as the browser needs it.
    ##
    ## `prefixLen` is read, never assumed. §5.3 requires shard depth to be
    ## recomputed as the corpus grows — "more chains or more history means a
    ## deeper prefix" — so a client that compiled in a depth would compute
    ## wrong shard paths the first time the index deepened, and would report
    ## every hash as absent while doing it.
    version*: string
    prefixLen*: int
    shards*: seq[string]
      ## Every OCCUPIED prefix. A query whose shard is not in this list is
      ## answered with zero further requests, and answered definitively: §5's
      ## index is exact, so an absent shard is an absent object rather than an
      ## unknown one.

  IndexHit* = object
    chain*: string
    kind*: int
    hexHash*: string
    route*: string

func parseMeta*(packed: string): IndexMeta =
  ## `version|prefixLen|shard,shard,…` from the JS boundary, or a zero
  ## `prefixLen` meaning "no index" — which is §5.4's trigger, not an error.
  let parts = packed.split('|')
  if parts.len != 3: return
  var n = 0
  try: n = parseInt(parts[1])
  except ValueError: return
  if n <= 0: return
  result.version = parts[0]
  result.prefixLen = n
  for s in parts[2].split(','):
    if s.len > 0: result.shards.add s

func bytesFromHex*(hex: string): string =
  ## The shard's bytes, from the hex the boundary hands over. "" on anything
  ## malformed, which the caller reads as "the index did not load" (§5.4).
  if hex.len == 0 or hex.len mod 2 == 1: return ""
  for i in countup(0, hex.len - 2, 2):
    try: result.add chr(parseHexInt(hex[i .. i + 1]))
    except ValueError: return ""

func minPrefixLen*(m: IndexMeta): int =
  ## The shortest query this index can answer, which is its shard depth: a
  ## shorter prefix selects no shard, so there is nothing to fetch.
  ##
  ## Derived, and surfaced to the reader rather than swallowed. A query below
  ## it is NOT a miss, and rendering it as one would be the false-absence
  ## defect this route has already shipped once.
  m.prefixLen

func shardFor*(m: IndexMeta; hexBody: string): string =
  ## The shard a query falls in — §5's "the client computes the shard path
  ## directly". "" when the query is too short to select one.
  if hexBody.len < m.prefixLen: "" else: hexBody[0 ..< m.prefixLen]

func shardIsPublished*(m: IndexMeta; shard: string): bool =
  for s in m.shards:
    if s == shard: return true
  false

func hitsFor*(shardBytes, hexBody: string): seq[IndexHit] =
  ## Every entry in a decoded shard whose hash begins with `hexBody`.
  ##
  ## THIS IS THE WHOLE OF PREFIX SEARCH, and it is four lines because §5's
  ## shard is already the right shape for it: "sharded by a leading slice of
  ## the hash" means every hash sharing a prefix is in one file, and "an exact
  ## map from hash to (chain, entity kind)" means the keys are there to scan.
  ##
  ## Be clear about what this is, though: Search-And-Routing does NOT specify
  ## prefix search. §7's suggestion table is explicit in the other direction —
  ## "Hash, chain pinned | No suggestion" and "Hash, no chain | No suggestion;
  ## resolves on submit via the index" — so this EXTENDS the spec rather than
  ## implementing it. What it does not do is bend the spec's guarantees: an
  ## exact query still resolves exactly, and a prefix answer is presented as
  ## candidates rather than as a resolution.
  let dec = decodeHashShard(shardBytes)
  if dec.err.len > 0: return
  for e in dec.entries:
    if e.hexHash.startsWith(hexBody):
      result.add IndexHit(chain: e.chain, kind: e.kind, hexHash: e.hexHash,
                          route: routeFor(e.chain, e.kind, "0x" & e.hexHash))

func encodeHits(hs: seq[IndexHit]): string =
  result = "["
  for i, h in hs:
    if i > 0: result.add ","
    result.add "{\"chain\":\"" & h.chain & "\",\"kind\":\"" & hkName(h.kind) &
      "\",\"hash\":\"0x" & h.hexHash & "\",\"route\":\"" & h.route & "\"}"
  result.add "]"

type
  Candidate* = object
    ## One (chain, meaning) pair the direct path would try: the object to read,
    ## and the route to land on if it is there.
    chain*, kind*, objectPath*, route*: string

func candidatesFor*(canonical: string; chains: openArray[string]):
    seq[Candidate] =
  ## §4's direct path, enumerated. One entry per candidate MEANING per chain —
  ## §2's "a 64-hex string is both a plausible transaction hash and a plausible
  ## block hash, and both are resolved concurrently; exactly one answers".
  ##
  ## Pure, and that is the point: the browser fetches this list and nothing else,
  ## so "which requests does a search make" is answerable without running one.
  if not isHashLike(shapesOf(canonical)): return
  for chain in chains:
    result.add Candidate(
      chain: chain, kind: "transaction",
      objectPath: "/" & txFactsPath(chain, canonical),
      route: "/" & chain & "/tx/" & canonical & "/")
    result.add Candidate(
      chain: chain, kind: "block",
      objectPath: "/" & blockPath(chain, canonical),
      route: "/" & chain & "/block/" & canonical & "/")

func encodeCandidates(cs: seq[Candidate]): string =
  ## The candidate list as JSON, for the one `importjs` boundary below.
  ##
  ## Hand-built rather than `std/json`: every field here is a slug or a path
  ## this module computed from hex, so there is nothing to escape, and pulling
  ## the JSON module into a `nim js` bundle for four flat strings would be the
  ## larger risk.
  result = "["
  for i, c in cs:
    if i > 0: result.add ","
    result.add "{\"chain\":\"" & c.chain & "\",\"kind\":\"" & c.kind &
      "\",\"objectPath\":\"" & c.objectPath & "\",\"route\":\"" & c.route & "\"}"
  result.add "]"

# ---------------------------------------------------------------------------
# The JavaScript boundary: I/O and the DOM, and no rules.
# ---------------------------------------------------------------------------

proc rawQuery(): cstring {.importjs: """
(function(){
  try { return new URLSearchParams(window.location.search).get('q') || ''; }
  catch (e) { return ''; }
})()""".}

proc registryChains(path: cstring; cb: proc(slugs: cstring)) {.importjs: """
(function(path, cb){
  // Static-Site-Architecture §2.9: the registry names every published chain,
  // and its path carries the contract version. Read it rather than trusting
  // the chain cards already in the DOM: those are a rendering of this file,
  // and a search that silently skipped a chain would still print a confident
  // "chains checked" list naming it.
  fetch(path, { credentials: 'omit' })
    .then(function(r){ return r.ok ? r.json() : null; })
    .then(function(j){
      var out = [];
      if (j && j.chains) { for (var k in j.chains) out.push(k); }
      cb(out.join(','));
    })
    .catch(function(){ cb(''); });
})(#, #)""".}

proc indexMeta(path: cstring; cb: proc(packed: cstring)) {.importjs: """
(function(path, cb){
  // `version|prefixLen|shard,shard,…`, or "" when the index is unreadable.
  // Packed rather than handed over as an object because the RULES are Nim: this
  // boundary carries bytes, and every decision about them is made on the other
  // side of it.
  fetch(path, { credentials: 'omit' })
    .then(function(r){ return r.ok ? r.json() : null; })
    .then(function(j){
      if (!j || !j.prefixLen) { cb(''); return; }
      cb([j.indexVersion || '1', j.prefixLen, (j.shards || []).join(',')].join('|'));
    })
    .catch(function(){ cb(''); });
})(#, #)""".}

proc fetchShardHex(path: cstring; cb: proc(hex: cstring)) {.importjs: """
(function(path, cb){
  // The shard as HEX, not as a binary string.
  //
  // The decoder is Nim (`decodeHashShard`), so the bytes have to cross this
  // boundary, and a latin1 JS string would have made that crossing depend on
  // how the JS backend represents `string` — a thing that is true today and is
  // nobody's documented contract. Hex is unambiguous in both directions and
  // costs a doubling of an artefact the exporter reports as 372 bytes at its
  // largest.
  fetch(path, { credentials: 'omit' })
    .then(function(r){ return r.ok ? r.arrayBuffer() : null; })
    .then(function(b){
      if (!b) { cb(''); return; }
      var u = new Uint8Array(b), s = '';
      for (var i = 0; i < u.length; i++) s += ('0' + u[i].toString(16)).slice(-2);
      cb(s);
    })
    .catch(function(){ cb(''); });
})(#, #)""".}

proc renderHits(slotId, hitsJson, query: cstring; navigate: bool) {.importjs: """
(function(slotId, hits, q, navigate){
  var slot = document.getElementById(slotId);
  if (!slot) return;
  function esc(s){
    return String(s).replace(/[&<>"]/g, function(c){
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c];
    });
  }
  function short(h){ return h.length > 20 ? h.slice(0,10) + '…' + h.slice(-6) : h; }
  function LABEL_OF(k){
    return { tx: 'transaction', block: 'block', address: 'address' }[k] || k;
  }

  if (hits.length === 1 && navigate) {
    // Page-Descriptions §11, first bullet: "Unambiguous input navigates
    // immediately, without an intermediate results page." The index is exact,
    // so this is a navigation to an object the index just confirmed — §5's
    // "the subsequent data fetch is guaranteed to succeed".
    slot.innerHTML =
      '<div class="stub group" data-search-state="resolved">' +
      '<div class="measure">Resolved <span class="mono">' + esc(q) +
      '</span> to a ' + esc(LABEL_OF(hits[0].kind)) + ' on ' +
      esc(hits[0].chain) +
      '. <a class="addr" data-search-hit href="' + esc(hits[0].route) +
      '">Open it</a>.</div></div>';
    window.location.replace(hits[0].route);
    return;
  }

  // §11: "Ambiguous input shows grouped candidates (transaction · block ·
  // address · name), keyboard-navigable, with the active chain's results first
  // and other configured chains below." Grouped BY KIND here, in §11's own
  // order; there is no active chain on /search, so chains keep the registry's
  // order within a group rather than being ranked by a rule nobody stated.
  //
  // THE KEYS ARE THE WIRE'S, NOT THE PROSE'S. `hkName` emits `tx`/`block`/
  // `address`; §11 writes the groups as "transaction · block · address". The
  // first version of this list used §11's words as lookup keys, so the
  // transaction group matched nothing and EVERY TRANSACTION WAS DROPPED from
  // the candidates — a list that rendered, looked right, and silently omitted
  // the one entity kind this whole feature exists to find. Caught by reading a
  // multi-hit result, not by any type: both sides are strings.
  var order = ['tx', 'block', 'address'];
  var groups = {};
  hits.forEach(function(h){ (groups[h.kind] = groups[h.kind] || []).push(h); });
  var html = '';
  order.forEach(function(kind){
    var g = groups[kind];
    if (!g || !g.length) return;
    html += '<h3 class="sec-title next">' + esc(LABEL_OF(kind)) +
            (g.length > 1 ? 's' : '') + '</h3><ul class="hitlist">' +
      g.map(function(h){
        return '<li><a class="addr" data-search-hit href="' + esc(h.route) +
               '"><span class="mono">' + esc(short(h.hash)) + '</span> · ' +
               esc(h.chain) + '</a></li>';
      }).join('') + '</ul>';
  });
  slot.innerHTML =
    '<div class="stub group" data-search-state="candidates">' +
    '<div class="measure">' +
    (hits.length === 1
      ? 'One published entity begins with <span class="mono">' + esc(q) +
        '</span>.'
      : hits.length + ' published entities begin with <span class="mono">' +
        esc(q) + '</span>. Every one is real; pick one.') +
    '</div>' + html + '</div>';
})(#, JSON.parse(#), #, #)""".}

proc runCandidates(slotId, candidatesJson, canonical: cstring) {.importjs: """
(function(slotId, cands, q){
  var slot = document.getElementById(slotId);
  if (!slot) return;

  function esc(s){
    return String(s).replace(/[&<>"]/g, function(c){
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c];
    });
  }

  // Every candidate is probed concurrently — §2's "both are resolved
  // concurrently; exactly one answers". A candidate that 404s is an answer,
  // not an error: §4 computes the path and the read decides.
  var probes = cands.map(function(c){
    return fetch(c.objectPath, { credentials: 'omit' })
      .then(function(r){ return r.ok ? c : null; })
      .catch(function(){ return null; });
  });

  Promise.all(probes).then(function(settled){
    var hits = settled.filter(function(c){ return c !== null; });
    var checked = [];
    cands.forEach(function(c){
      if (checked.indexOf(c.chain) < 0) checked.push(c.chain);
    });

    if (hits.length === 1) {
      // Page-Descriptions §11, first bullet: "Unambiguous input navigates
      // immediately, without an intermediate results page." The object was
      // just read, so this is a navigation to something known to be there —
      // never a guess. The slot is written FIRST so the answer exists as
      // rendered markup even if the navigation is blocked or slow.
      slot.innerHTML =
        '<div class="stub group" data-search-state="resolved">' +
        '<div class="measure">Resolved <span class="mono">' + esc(q) +
        '</span> to a ' + esc(hits[0].kind) + ' on ' + esc(hits[0].chain) +
        '. <a class="addr" data-search-hit href="' + esc(hits[0].route) +
        '">Open it</a>.</div></div>';
      window.location.replace(hits[0].route);
      return;
    }

    if (hits.length > 1) {
      // §11: "Ambiguous input shows grouped candidates". Two chains claiming
      // one hash is exactly the §5.1 collision case, and guessing between them
      // is the one thing that must not happen.
      var rows = hits.map(function(c){
        return '<li><a class="addr" data-search-hit href="' + esc(c.route) +
               '">' + esc(c.chain) + ' · ' + esc(c.kind) + '</a></li>';
      }).join('');
      slot.innerHTML =
        '<div class="stub group" data-search-state="ambiguous">' +
        '<div class="measure">More than one chain holds <span class="mono">' +
        esc(q) + '</span>. Both are real; pick one.</div><ul>' + rows +
        '</ul></div>';
      return;
    }

    // §8: "Not-found messaging names what was tried, because a miss is usually
    // a scoping problem rather than an absence." Page-Descriptions §14 states
    // the same row as a hard requirement: "'Not on this chain' with the chains
    // checked, not a blank page."
    slot.innerHTML =
      '<div class="stub group" data-search-state="notfound">' +
      '<div class="measure">No result for <span class="mono">' + esc(q) +
      '</span>. Checked the published object path on ' +
      esc(checked.join(' · ')) +
      ' — no transaction and no block at the computed address. ' +
      'If this is from a chain BlockTracer does not cover yet, it will not ' +
      'be here.</div></div>';
  });
})(#, JSON.parse(#), #)""".}

proc fillQuery(q: cstring) {.importjs: """
(function(q){
  // Put the query back in the box. The form is a plain GET, so the server
  // renders `/search/` with an EMPTY input no matter what was asked for — a
  // visitor who mistyped a hash could not see what they had typed, on the one
  // page whose entire job is to answer it.
  //
  // It is also what makes the non-collapse rule observable: the value is set
  // from the raw query, so a normalisation that corrupted a case-carrying
  // identifier would be visible on screen rather than only in a fetch nobody
  // watches.
  var boxes = document.querySelectorAll('input[name="q"]');
  for (var i = 0; i < boxes.length; i++) boxes[i].value = q;
})(#)""".}

proc renderNoQuery(slotId, state, message: cstring) {.importjs: """
(function(slotId, state, msg){
  var slot = document.getElementById(slotId);
  if (!slot) return;
  slot.innerHTML = '<div class="stub group" data-search-state="' + state +
    '"><div class="measure">' + msg + '</div></div>';
})(#, #, #)""".}

proc directPathFallback(canonical: string; chains: seq[string]) =
  ## §5.4, unchanged and still here on purpose: "If the index is unavailable or
  ## a version is stale, the client falls back to probing configured chains
  ## directly. Slower and noisier, never wrong. **Search must never fail
  ## because an index did not load.**"
  ##
  ## It resolves EXACT hashes only, and that is inherent rather than a gap: a
  ## probe is a lookup of one computed path, so there is no such thing as
  ## probing for a prefix. A build with no index therefore keeps exact search
  ## and loses prefix search, which is the correct degradation — the one thing
  ## it must not do is answer a prefix query with "not found".
  runCandidates(cstring(ResultSlotId),
                cstring(encodeCandidates(candidatesFor(canonical, chains))),
                cstring(canonical))

proc boot(chainsCsv, packedMeta: cstring) =
  let raw = $rawQuery()
  fillQuery(cstring(raw))
  if raw.strip.len == 0:
    # No query is not a miss. The page's own directory of mechanisms and names
    # is the answer here, and overwriting it with "no results" would be the
    # blank page §14 forbids.
    return

  # The RAW query classifies; only the hash branch canonicalises. See
  # `canonicalHash`: doing it the other way round rewrites a block height into
  # a hex string and loses §3's zero-request answer.
  let shapes = shapesOf(raw)
  let canonical = canonicalHash(raw)
  let meta = parseMeta($packedMeta)

  if not isHashLike(shapes):
    # §2's remaining rows — decimal, base58, bech32, plain text — resolve
    # through local inference over live head pointers, the hash index or the
    # name shards. Saying so is not the same as saying "not found", and
    # `SearchVM.mechanism` reports `smUnsupportedShape` for precisely this
    # reason: "we cannot look this up yet" must never render as "it does not
    # exist".
    # THREE DIFFERENT REASONS, THREE DIFFERENT SENTENCES. They were one, and
    # it told a visitor searching block 68231 that their query was "too short",
    # which is false — it is five digits, well over the bare-hex floor. It was
    # rejected for being a NUMBER, and a message that names the wrong cause
    # sends the reader to fix the wrong thing.
    let q = raw.strip
    let why =
      if isAllDigits(q):
        "Read as a block number rather than a hash. §3's local inference " &
        "resolves a height from live head pointers, which this page does " &
        "not hold. To search it as a hex identifier instead, write it with " &
        "a <span class=\"mono\">0x</span>. "
      elif isHexDigits(q):
        "Too short to read as a hash. Without a <span class=\"mono\">0x" &
        "</span> prefix, a hex string is only taken for an identifier at " &
        $BareHexFloor & " digits or more, because shorter ones are usually " &
        "words. Add the prefix to search it anyway. "
      else:
        "This deployment resolves an identifier by computing its object " &
        "path, which needs a hash — with or without the <span class=" &
        "\"mono\">0x</span>. "
    renderNoQuery(cstring(ResultSlotId), "unsupported",
      cstring(why & "Names resolve through the index shards below, which " &
              "this deployment does not read from the browser yet. Nothing " &
              "was looked in — which is not the same as nothing being there."))
    return

  var chains: seq[string]
  for c in ($chainsCsv).split(','):
    if c.len > 0: chains.add c

  let body = canonicalHexBody(raw)

  # §14 requires a miss to name what was tried. A query that is ALSO a decimal
  # was resolved only as hex, and saying "no result" without saying that would
  # be a false absence claim about a block height nobody looked for: `68231` is
  # a real aztec height and a valid hex string at the same time, and §3's local
  # inference — the mechanism that would answer it — needs live head pointers
  # this page does not hold.
  # §14: "'Not on this chain' WITH THE CHAINS CHECKED", and §8 renders it by
  # naming them. The index answers for every chain at once, which is a stronger
  # statement than a per-chain probe makes — but "every chain this deployment
  # publishes" is only checkable by a reader who is told which those are, so the
  # list is stated rather than alluded to.
  var covered = ""
  for i, c in chains:
    if i > 0: covered.add " · "
    covered.add c
  let coveredNote =
    if covered.len > 0: " Chains covered: " & covered & "."
    else: ""

  let decimalNote =
    if qsDecimal in shapes:
      " This was not looked up as a block number: §3's local inference needs " &
      "live head pointers, which this page does not hold."
    else: ""

  # ---- §5: the index first -------------------------------------------------
  if meta.prefixLen > 0:
    if body.len < meta.minPrefixLen:
      # NOT a miss, and the difference is the whole point. Nothing was looked
      # in, because a prefix shorter than the shard depth selects no shard.
      # Rendering this as "no result" would be a false absence claim about
      # every object that does begin with it — the defect this route already
      # shipped once, at a different layer.
      #
      # The number comes from the published descriptor, so it stays right when
      # §5.3's arithmetic deepens the index.
      renderNoQuery(cstring(ResultSlotId), "tooshort",
        cstring("Too short to look up. The published index is sharded on " &
                "the first <b>" & $meta.minPrefixLen & "</b> hex digits, " &
                "so a search needs at least that many — you typed " &
                $body.len & ". Nothing was checked, which is not the same " &
                "as nothing being there."))
      return

    let shard = meta.shardFor(body)
    if not meta.shardIsPublished(shard):
      # Zero further requests, and a DEFINITE answer: §5's index is exact over
      # every published chain, so a prefix whose shard was never written is a
      # prefix nothing begins with.
      renderNoQuery(cstring(ResultSlotId), "notfound",
        cstring("No published entity begins with <span class=\"mono\">0x" &
                body & "</span>. The hash index covers every chain this " &
                "deployment publishes, and has no shard for that prefix — " &
                "so this is an answer, not a gap." & coveredNote & decimalNote))
      return

    fetchShardHex(cstring("/idx/hash/" & meta.version & "/" & shard & ".bin"),
                  proc(hex: cstring) =
      let bytes = bytesFromHex($hex)
      if bytes.len == 0:
        # §5.4: "Search must never fail because an index did not load." The
        # shard was named by the descriptor and did not arrive, so fall back to
        # probing — slower and noisier, never wrong.
        directPathFallback(canonical, chains)
        return
      let hits = hitsFor(bytes, body)
      if hits.len == 0:
        renderNoQuery(cstring(ResultSlotId), "notfound",
          cstring("No result for <span class=\"mono\">0x" & body &
                  "</span>. Checked the hash index shard for that prefix, " &
                  "which covers every chain this deployment publishes. If " &
                  "this is from a chain BlockTracer does not cover yet, it " &
                  "will not be here." & coveredNote & decimalNote))
        return
      # An EXACT query that resolves navigates (§11). A PREFIX query never
      # auto-navigates even when it happens to match one entity: the user typed
      # a fragment, and taking them somewhere on the strength of a partial
      # match is a guess dressed as a resolution. One hit is shown as one
      # candidate — one click, and no surprise.
      let exact = body.len == 64 or body.len == 40
      renderHits(cstring(ResultSlotId), cstring(encodeHits(hits)),
                 cstring("0x" & body), exact))
    return

  # ---- §5.4: no index; probe the chains directly ---------------------------
  if chains.len == 0:
    renderNoQuery(cstring(ResultSlotId), "degraded",
      cstring("Neither the hash index nor the chain registry could be read, " &
              "so nothing was checked. That is a different answer from " &
              "“not found”."))
    return
  directPathFallback(canonical, chains)

when isMainModule:
  registryChains(cstring("/" & registryPath()),
                 proc(slugs: cstring) =
    indexMeta(cstring("/idx/hash/meta.json"),
              proc(packed: cstring) = boot(slugs, packed)))
