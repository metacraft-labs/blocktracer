## viewmodel/source_bundle_vm.nim
##
## `SourceBundleVM` — Front-End-Architecture §3: "Provider chain, validation
## state, per-code-hash bundle cache".
##
## It establishes §14's "No verified source" row for the panes, writing
## `SourceAvailability` through the seam. §14's treatment is
## "instruction-level stepping, with the supply-sources action prominent", and
## the two things that make that treatment correct rather than decorative are
## both decisions this VM owns:
##
##   * **Which of the three answers applies.** `svAbsent` and `svUnverified`
##     are different states — there is nothing to supply sources *for* in the
##     first — and a supply-sources action on a transaction that executed no
##     contract code is an affordance with no subject.
##   * **A mismatched bundle is refused, not displayed.** The Client SDK
##     returns `boMismatched` for a bundle filed under the wrong code hash, and
##     this VM keeps it out of the cache. Displaying it would attribute source
##     to code that never ran, which is a correctness failure wearing the
##     costume of a nicer page.
##
## ## Per-code-hash, not per-address, and why the cache is worth having
##
## Source-Resolution.md §5 keys bundles by **code hash**, so every deployment of
## the same contract shares one bundle — a popular router or token
## implementation costs one fetch rather than one per transaction. The cache
## here is what realises that: `codeHashes(facts)` is already deduplicated, and
## `loadFor` skips a hash it has already resolved. `fetchCount` is exposed so
## the property is measurable in a test rather than assumed.
##
## ## The provider chain is the Client SDK's, in the Client SDK's order
##
## Manifest recommendation first, then the chain-wide pointer
## (Trace-Artifacts.md §4: `sourceBundles` "names the recommended
## interpretation per code hash — the interpretation the page should use").
## This VM does not re-decide that order; `resolveSourceBundle` owns it, and a
## second copy here would be a second thing to keep in sync.

import std/tables

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./replay_status

type
  SourceBundleVM* = ref object of ViewModel
    store*: ObjectStore

    # -- State --
    chain*: Signal[string]
    codeHashes*: Signal[seq[string]]
      ## The hashes this page needs source for — `codeHashes(facts)`, already
      ## deduplicated by the Client SDK.
    bundles*: Signal[Table[string, BundleResult]]
      ## The per-code-hash cache. A `boMismatched` result is cached too: it is
      ## a settled answer, and re-fetching a bundle that was refused once would
      ## refuse it again at the cost of a request.
    fetchCount*: Signal[int]
      ## How many bundle objects were actually fetched this session. Exposed so
      ## the caching claim above is checkable.

    # -- Derived --
    resolved*: Memo[int]
    verified*: Memo[int]
      ## Code hashes with a loaded, full-match bundle.
    unresolved*: Memo[seq[string]]
      ## The hashes a supply-sources action would be for. §14 calls that action
      ## "prominent", and this is its subject.
    verification*: Memo[SourceVerification]
      ## The value the seam writes.
    anyMismatched*: Memo[bool]
      ## At least one bundle was refused for naming a different code hash. Not
      ## folded into `unresolved`, because "nobody has published source" and
      ## "someone published the wrong source" are different things to tell a
      ## user and only the second is a signal about the tree.

proc setSubject*(vm: SourceBundleVM; chain: string; hashes: seq[string]) =
  ## Point the VM at a new transaction's code hashes.
  ##
  ## The cache survives a change of subject *within a chain* — that is the
  ## whole point of keying by code hash — and is dropped when the chain
  ## changes, because a code hash is only unique within one chain's namespace
  ## (`/src/{chain}/{codeHash}/`).
  if vm.chain.val != chain:
    vm.bundles.val = initTable[string, BundleResult]()
    vm.chain.val = chain
  vm.codeHashes.val = hashes

proc loadFor*(vm: SourceBundleVM; hash: string;
              manifest: TraceManifest; hasManifest: bool) =
  ## Resolve and fetch one code hash's bundle, unless it is already cached.
  if hash.len == 0: return
  var cache = vm.bundles.val
  if cache.hasKey(hash): return
  let reference = resolveSourceBundle(vm.store, vm.chain.val, manifest,
                                      hasManifest, hash)
  let res =
    if reference.origin == bsNone:
      # `fetchSourceBundle` would return `boNotPublished` without a read, but
      # short-circuiting here makes the "no request is issued for an
      # unpublished bundle" property local and visible rather than inherited.
      BundleResult(reference: reference, outcome: boNotPublished,
                   reason: reference.reason)
    else:
      vm.fetchCount.val = vm.fetchCount.val + 1
      fetchSourceBundle(vm.store, reference)
  cache[hash] = res
  vm.bundles.val = cache

proc loadAll*(vm: SourceBundleVM; manifest: TraceManifest; hasManifest: bool) =
  ## Every code hash the current subject touched.
  for h in vm.codeHashes.val:
    vm.loadFor(h, manifest, hasManifest)

proc results*(vm: SourceBundleVM): seq[BundleResult] =
  ## The cached results for the current subject, in `codeHashes` order. The
  ## input `replay_status.verificationFor` takes.
  let cache = vm.bundles.val
  for h in vm.codeHashes.val:
    if cache.hasKey(h): result.add cache[h]

proc bundleFor*(vm: SourceBundleVM; hash: string): BundleResult =
  let cache = vm.bundles.val
  if cache.hasKey(hash): cache[hash] else: BundleResult(outcome: boNotPublished,
    reason: "not resolved yet")

proc createSourceBundleVM*(store: ObjectStore): SourceBundleVM =
  withViewModel proc(dispose: proc()): SourceBundleVM =
    let vm = SourceBundleVM(
      store: store,
      chain: createSignal(""),
      codeHashes: createSignal(newSeq[string]()),
      bundles: createSignal(initTable[string, BundleResult]()),
      fetchCount: createSignal(0),
    )

    vm.resolved = createMemo(proc(): int =
      let cache = vm.bundles.val
      for h in vm.codeHashes.val:
        if cache.hasKey(h): inc result)

    vm.verified = createMemo(proc(): int =
      let cache = vm.bundles.val
      for h in vm.codeHashes.val:
        if cache.hasKey(h) and cache[h].outcome == boLoaded and
           cache[h].bundle.match == mqFull:
          inc result)

    vm.unresolved = createMemo(proc(): seq[string] =
      let cache = vm.bundles.val
      for h in vm.codeHashes.val:
        if not cache.hasKey(h) or cache[h].outcome != boLoaded or
           cache[h].bundle.match != mqFull:
          result.add h)

    vm.anyMismatched = createMemo(proc(): bool =
      let cache = vm.bundles.val
      for h in vm.codeHashes.val:
        if cache.hasKey(h) and cache[h].outcome == boMismatched: return true
      false)

    vm.verification = createMemo(proc(): SourceVerification =
      verificationFor(vm.results, vm.codeHashes.val.len))

    vm
