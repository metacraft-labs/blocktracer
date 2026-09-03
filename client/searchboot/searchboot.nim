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
## `canonicalQuery` and `shapesOf` come from `viewmodel/search_shapes`, and the
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

proc renderNoQuery(slotId, state, message: cstring) {.importjs: """
(function(slotId, state, msg){
  var slot = document.getElementById(slotId);
  if (!slot) return;
  slot.innerHTML = '<div class="stub group" data-search-state="' + state +
    '"><div class="measure">' + msg + '</div></div>';
})(#, #, #)""".}

proc boot(chainsCsv: cstring) =
  let raw = $rawQuery()
  if raw.strip.len == 0:
    # No query is not a miss. The page's own directory of mechanisms and names
    # is the answer here, and overwriting it with "no results" would be the
    # blank page §14 forbids.
    return

  let canonical = canonicalQuery(raw)
  let shapes = shapesOf(canonical)

  if not isHashLike(shapes):
    # §2's remaining rows — decimal, base58, bech32, plain text — resolve
    # through local inference over live head pointers, the hash index or the
    # name shards. Saying so is not the same as saying "not found", and
    # `SearchVM.mechanism` reports `smUnsupportedShape` for precisely this
    # reason: "we cannot look this up yet" must never render as "it does not
    # exist".
    renderNoQuery(cstring(ResultSlotId), "unsupported",
      cstring("This deployment resolves an identifier by computing its " &
              "object path, which needs a <span class=\"mono\">0x</span> " &
              "hash. Block numbers and names resolve through the index " &
              "shards below, which are published but not yet read from the " &
              "browser."))
    return

  var chains: seq[string]
  for c in ($chainsCsv).split(','):
    if c.len > 0: chains.add c
  if chains.len == 0:
    renderNoQuery(cstring(ResultSlotId), "degraded",
      cstring("The chain registry could not be read, so nothing was " &
              "checked. That is a different answer from “not found”."))
    return

  runCandidates(cstring(ResultSlotId),
                cstring(encodeCandidates(candidatesFor(canonical, chains))),
                cstring(canonical))

when isMainModule:
  registryChains(cstring("/" & registryPath()),
                 proc(slugs: cstring) = boot(slugs))
