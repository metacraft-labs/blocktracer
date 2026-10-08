# BlockTracer workspace commands.
# `just` recipes wrap the nimble tasks so the workspace has one entry point.

# Run the conformance + publisher + Client SDK + chain-snapshot + registry
# identifier-encoding test suites, and the SDK's bidirectional import lint.
#
# `tests/tidentifierencoding.nim` is the registry's per-chain identifier-encoding
# declaration (Configuration.md §2.1, §2.2). It is HERE and not under `client/`
# for the same reason the snapshot suite is: it drives both registry producers and
# needs no explorer. Its subject is a member that **shard derivation reads**: the
# encoding is declared as data and `contract/shards.nim` takes it as a parameter,
# so the producers, the validator and the browser derive one way from one
# declaration. Two sites still derive from the string and are later steps — the
# hash index (a published wire format, so a migration plus a compatibility window)
# and the capture tooling (which enumerates the tree the index keys, so it follows
# the index).
#
# It still measures §2.2's additive rule, which did not stop mattering when a
# consumer arrived: a reader built against the schema WITHOUT the member behaves
# identically with it, proven against three controls that change a member the same
# reader does know. It also measures the derivation end to end — the published hex
# layout against the algorithm it replaced, a non-hex chain round-tripping from
# producer to client, and the validator reading the tree's own declaration rather
# than its own opinion. Its last suite asserts the boundary as an EQUALITY between
# an enumerated set of consumers and a swept one, and asserts that the two
# string-deriving sites are unchanged; it used to assert that nothing read the
# member at all, went red when the derivation landed, and was replaced rather than
# widened.
#
# `tests/tchainsnapshot.nim` is the reader's side of the producer seam: what
# `ingestSnapshot` accepts, what it refuses BY NAME, and what it must not crash on.
# It is here rather than under `client/` because it needs no explorer, and it is in
# THIS recipe because the defect it pins was found by running the real follower and
# not by any test: a mainnet capture whose `provenance` carries no `l1ChainId`, which
# the reader read by unguarded `prov["…"]` and raised `KeyError` on. Every committed
# fixture and all eight hand-written provenance literals in
# `client/tests/test_chain_provenance.nim` carry the member, so the whole suite was
# blind to it; the fixture here is the follower's own output, byte for byte.
#
# ── `test-searchboot`, WHICH IS THE ONLY GATE THE BROWSER'S RULES HAVE ─────
#
# `client/searchboot/searchboot.nim` computes the object path a search fetches,
# in a tab. It had NO test of any kind — the bundle-freshness gate checks that
# `search.js` is newer than its sources and the SDK boundary lint checks which
# modules it may import, and neither runs one of its rules — because its
# `importjs` boundary makes it uncompilable on the C backend, so every suite here
# had to skip it. `nim js -r` is how it is testable at all, and it takes seconds.
#
# It reaches this gate through the delegation below, for the reason
# Search-And-Routing.md §5 gives: "two requests to resolve any hash on any chain"
# is only true if the client recomputes the SAME object path the producer wrote,
# and since that path is derived from the chain's declared identifier encoding, a
# browser that could not read the declaration would make §5 false for every
# non-hex chain — silently, and only in a tab.
#
# ── AND EVERY CLIENT SUITE, BY DELEGATION AND NOT BY A SECOND LIST ─────────
#
# THE HOLE THIS CLOSES, AND IT IS THE HOLE THIS CAMPAIGN KEEPS FINDING. This
# recipe used to name THREE client suites — `test-searchboot`,
# `test-debug-route` and `test-chain-provenance` — out of the FIFTEEN that
# `client/Justfile`'s `test:` aggregate runs. The twelve it left out included
# `test-instruction-listing`, which carries the strongest landing assertions in
# the repository: a planted `steps + 7` coordinate asserted CLAMPED across all 31
# instruction-level recordings this tree publishes, per subject. A gate that omits
# its own strongest assertions is worse than a gate that omits weak ones, because
# what it certifies is precisely the part nobody checked.
#
# It had happened twice before by the same mechanism, and the two paragraphs this
# replaces are the evidence: `test-debug-route` was added to this recipe with the
# note "the suite is in `client/Justfile`'s `test:` aggregate and CI runs that
# aggregate, so it was never dark — but it was not in THIS recipe", and
# `test-chain-provenance` was added with the same sentence. Three times is not
# three oversights; it is a membership list maintained in two places, which will
# diverge again as surely as it diverged three times already.
#
# SO THE LIST IS GONE. `cd client && just test` is ONE line that runs whatever
# `client/Justfile` declares, in the order it declares it. A suite added there is
# in the operator's gate the moment it is added, and this file cannot be the
# reason it is dark. That is the only shape that makes "all of them" a property of
# the gate rather than a fact about the last person who edited it.
#
# WHAT THE ORDER COSTS, STATED. `just` runs a recipe's dependencies in the order
# they are listed, and `client/Justfile`'s order puts `test-chain-provenance`
# (~37 min) and `test-debug-route` (~9 min) in the middle rather than at the end,
# so a failure in one of the cheap suites after them is learned late. That is a
# real regression against the fail-fast property this recipe's own comments prize,
# and it is accepted rather than fixed HERE, because fixing it here means
# re-listing the fifteen and reintroducing the divergence this change exists to
# remove. If the order is worth changing, change it in `client/Justfile`, where
# the one list lives.
#
# ── THE SLOW SUITES, WHICH ARE STILL IN. LEAVE THEM IN. ────────────────────
#
# `test-chain-provenance` takes ~37 minutes and is worth it: 141 assertions driven
# through the REAL producers — `generate` and `ingestSnapshot` — over the committed
# corpus. It is the only end-to-end check in this repository that grades what the
# shipping path actually publishes rather than a lookalike built by the test, and
# that is not a theoretical advantage: it is what caught the `captures`
# misattribution, and its suite-16 arm is what keeps a synthetic Noir program from
# rendering under a real transaction's hash.
#
# `test-explorer-breadth` is `-d:release` and walks a synthetic address with a
# hundred thousand transactions from its first page to its last, so it is slow for
# a reason nothing cheaper can replace.
#
# DO NOT REMOVE ANY OF THEM FOR SPEED, and do not re-list a subset here to get
# one. If this recipe needs to be fast for some new purpose, add a `just
# test-quick` that stops ABOVE the `cd client` line and leave this one whole — the
# thing that makes a gate worth having is that nobody had to decide to run the
# expensive part. A fast gate that OMITS the landing assertions is the defect
# above with a friendlier name.
test:
    # WHICH TOOLCHAIN THIS RAN ON, printed FIRST and on purpose. Every suite below
    # is `--hints:off`, so without this line a full log contains no evidence of the
    # compiler that produced it — and the distinction is not academic: an ambient
    # Nim 2.2.4 is on `PATH` outside the devshell while the devshell pins 2.2.10,
    # the two compile different trees, and a green log from the wrong one proves
    # nothing about what ships. `Chain-*` milestone notes define their OK-line
    # totals — the per-assertion lines a Nim `unittest` suite prints — as "counted
    # in a log that also states the compiler version"; before this line that
    # definition named evidence this recipe could not produce, and a verification
    # step nobody can perform is a definition that defeats itself.
    #
    # AND THAT TOKEN IS DESCRIBED RATHER THAN SPELLED, ON PURPOSE. `just` echoes a
    # recipe's comment lines as it runs them, so a comment in this body containing
    # the bracketed OK token VERBATIM adds itself to any total taken by grepping a
    # run's output: the comment written to make the figure verifiable would inflate
    # the figure by one. It happened — this block is the one that did it. The echo
    # goes to stderr rather than stdout, so the inflation appears only when the
    # streams are merged, which is exactly how a `2>&1 | grep -c` measurement is
    # taken. Do not write the literal token anywhere in this recipe.
    #
    # NOT PIPED THROUGH `head`: the pipeline's status would be `head`'s, so a
    # missing or broken `nim` would read as a pass on the one line whose whole job
    # is to say which `nim` this is. The extra banner lines are the cost of that.
    nim --version
    nim c -r --hints:off tests/tcontract.nim
    nim c -r --hints:off tests/tpublish.nim
    nim c -r --hints:off tests/tclientsdk.nim
    nim c -r --hints:off tests/tchainsnapshot.nim
    nim c -r --hints:off tests/tidentifierencoding.nim
    nim c -r --hints:off tests/tchainprofile.nim
    # THE TRANSPORT ENCODING OF A PUBLISHED CONTAINER (CCP-6). Its own suite because
    # the property is a RELATION across five modules — the pure policy, the brotli
    # codec, the publication, the producer-side kit and the consumer-side kit — and a
    # per-module suite would have each half agreeing with its own idea of what the
    # other does. That is the shape the campaign behind it spent two weeks undoing,
    # with three byte figures that had become one.
    nim c -r --hints:off tests/tcontainerencoding.nim
    ci/test/client-sdk-boundary.sh
    ci/test/client-sdk-boundary-test.sh
    # ALL FIFTEEN CLIENT SUITES, BY DELEGATION. See the block above this recipe
    # for why this is one line and not fifteen: a membership list kept in two
    # files diverged three separate times, and the third time it cost the gate
    # the strongest landing assertions in the repository.
    cd client && just test

# ── the chain capture tooling's own selftests ──────────────────────────────
#
# FOURTEEN suites — 98 + 19 + 24 + 24 + 57 + 233 + 33 + 162 + 53 + 118 + 219 + 83 + 6 + 30 = 1159 counted assertions —
# over the twelve decisions the capture path makes that nothing else can check
# afterwards:
# which outcome a driver run is (`replay-selftest`), whether a snapshot may be
# called frozen (`freeze-snapshot-selftest`), when a supervised watch is
# allowed to stop (`watch-chain-selftest`), which call frames a container's
# event stream folds (`calltrace-fold-selftest`), whether a payload the
# transaction file store returned is the body that was asked for
# (`backfill-bodies-selftest`), WHY a transaction this pipeline did not
# trace was declined (`refusal-selftest`), whether a range ledger's coverage
# is actually contiguous (`coverage-contiguity-selftest`), which encodings a
# chain may DECLARE its identifiers in (`identifier-encoding-selftest`),
# WHAT WAS ACTUALLY PUBLISHED, as a set of keys rather than as a total
# (`object-set-selftest`), whether the SNAPSHOT READER and the document a
# producer writes against name the same members (`snapshot-contract-selftest`),
# whether a prepared tree's RECORDINGS are in a state worth publishing
# (`chain-health-selftest`), and HOW A YIELD FIGURE IS COUNTED — which fraction of a
# chain's transactions actually trace, over which denominator, against which pinned
# windows (`yield-method-selftest`), and WHETHER THE COMMITTED ETHEREUM INPUT SET
# IS THE INPUT SET IT CLAIMS TO BE — every file hashed against its manifest, the
# three independent block answers cross-checked against each other, and the
# replay endpoint held to never reaching a network even when handed one
# (`eth-rpc-transcript-selftest`).
#
# `snapshot-contract-selftest` IS THE ONE THAT READS A NIM FILE FROM JAVASCRIPT,
# and it is a suite rather than a review because the alternative is a person
# reading `ingest.nim` and `Data-Contract.md` §5 and agreeing with themselves. The
# measured result of that was §5 naming NINE member paths against a reader that
# consumed 117 over 22 containers — so 108 unnamed, 19 of them by unguarded bracket
# access, which RAISES in Nim rather than answering null. Those are the figures of the
# GAP, measured on 2026-09-17 when it closed, and not of the census, which has grown
# since; the suite PRINTS its current size, which is where a current figure belongs.
# One of the 19's siblings,
# `provenance.l1ChainId`, was omitted by this repository's own live follower, so the
# producer wrote a snapshot the reader crashed on.
#
# THE NINE are the member paths §5 stated as REQUIREMENTS — §5.2's six-row table plus
# `provenance.chain`, `reason` and `refusalReason`, which its prose makes mandatory. The
# reading is spelled out because §5 admits three and only one makes 108 follow: §5.2's
# table alone is six (gap 111), and every member §5 mentions at all is twelve (adding
# `container`, `counts.accountedFor` and `outcome`, none of them stated as a requirement).
# `lib/reader-contract.mjs`, `snapshot-contract-selftest.mjs` and `ci.yml` state the same
# reading. It EXTRACTS
# the consumed set from the reader (`lib/reader-contract.mjs` walks the binding
# stack; `std/json` gives a reader exactly two subscripts and the choice between
# them IS the statement of whether a member is required) and compares it to
# `snapshot-contract.json` for equality in BOTH directions. Its §6 mutates each
# side in turn — including the control the milestone names, a member deleted from
# the SPEC — so a green is a measurement rather than a check that has never been
# shown to fail.
#
# `object-set-selftest` GUARDS A BASELINE THAT IS A COUNT, and a count is the one
# statistic a refactor can hold still while changing what it publishes. The
# zero-regression acceptance criterion is 138,287 objects, and its own control
# says a tree with one object renamed has the same count and must fail. So
# `object-set.mjs` publishes two digests beside the count — over the key set,
# and over the key set bound to its
# content — and this suite is where each of them is watched moving: a rename (same
# count, same bytes), a rewrite (same keys), and two objects SWAPPING contents,
# where the count, the byte total and the key set are all three identical and only
# a path-bound digest can see it. It also refuses the empty-set pass in both
# disguises, unaimed and aimed at an empty tree.
#
# `identifier-encoding-selftest` IS THE JAVASCRIPT HALF OF A FILE WHOSE OTHER HALF
# IS NIM, and that is the whole reason it is a suite rather than a comment.
# `tools/chain/identifier-encodings.json` is a closed set (Configuration.md §2.1,
# §2.2, over Search-And-Routing.md §2's shape table) read on the Nim side with
# `staticRead`, so that side fails the BUILD on a malformed file. The JavaScript
# side has no such backstop, and a shared file whose JavaScript side nothing opens
# drifts there undetected, so the JavaScript read happens now, as a test. The file
# also carries, per member, the TWO rules that member's declaration implies —
# `shardKey`, where a path segment's payload starts, and `case`, how case is
# handled — so the set and the behaviour of its members cannot disagree. Each
# field of both rules has a mutation arm here, including the two CROSS-FIELD case
# constraints: a member may not declare that its case carries identity and then
# fold it away, and may not say its display form is its key form beside a key form
# that preserves.
#
# It is a test and NOT a consumer, and that is now settled rather than pending.
# Derivation and case handling are Nim, compiled to both C and the JS backend from
# one source, so the browser needs no JavaScript reader. The capture tooling looked
# like the one site that would — it open-coded the hex shard rule at three sites —
# and it does not: it ENUMERATES the published shard directories rather than
# recomputing them, which needs no reader of the set at all.
#
# ITS BOUNDARY ARM IS AN EQUALITY, SWEPT AND FLOORED, and it is here rather than
# only in `just test` because THIS is the fast gate. It used to assert that nothing
# read the declaration, resting on five named files; a consumer planted one file
# over from two of them passed every arm while that sentence printed. It now walks
# `src/`, `client/` and `tools/` whole, over TWO sweeps — who reads the registry
# member and who reads the case rule — and compares what it finds for EQUALITY
# against enumerated sets of expected consumers, so an unexpected one fails it and
# so does an expected one that stopped.
#
# THE RULE IT SWEEPS WITH IS NO LONGER WRITTEN TWICE. The extensions, the pruned
# directories, the floors and the allowlists are
# `tools/chain/identifier-encoding-boundary.json`, read by this half AND by
# `tests/tidentifierencoding.nim`. They used to be spelled out in both and compared
# to nothing — they agreed because two independently-maintained copies happened to,
# and one divergence (`redist/`) had already been found and fixed by hand. A shared
# rule is still not enough, because that divergence was about what `dist/` MEANS in
# two sweep implementations rather than about the words: so the Nim half also runs
# this one with `--emit-population` and requires the two swept file lists to be
# identical.
#
# The floors are named in that file and the POPULATION is not, on purpose: both
# halves take their population from git — tracked plus untracked-and-not-ignored —
# so it moves with the working tree, and a number pinned in a comment would go
# stale for anyone holding a scratch file. (This one used to say "80 of 101, 100 of
# 122", and was stale by one within a day.) The floors are what stop an emptied
# sweep reading as a green; the asserted set SIZES are what stop an expected list
# growing one entry at a time.
#
# `coverage-contiguity-selftest` was added to a tool that had a `just` recipe,
# NO test and NO caller. It is kept rather than dropped because a planned
# zero-regression check requires contiguity asserted from the ledger rather
# than inferred from a total — so it has a named future consumer, and a tool with a
# named future consumer and no proof of bite is the shape §4 warns about: its
# entire output is `CONTIGUOUS WITH ZERO GAPS: YES` and an exit code, and
# nothing had ever seen it print NO. Its suite drives all five refusal
# conditions the tool enumerates, each against a control that differs in one
# field, matching the standard the contiguity measurement itself was held to
# (five synthetic failing ledgers).
#
# `refusal-selftest` is ING-3's, and it is here for the same reason the body
# verifier is: the refusal path has never fired in a real run. A 400-block mainnet
# backfill exited 0 with "0 divergent, 0 refused", so every universal claim
# about refusals is vacuously true and a suite that only ran the pipeline
# against a live chain would report green having executed none of it. Every
# member of the closed set is reached there, offline, on every run — including
# the one the milestone singles out, `not-first-in-block`, whose production
# count is zero and whose branch is therefore exercised against a synthetic
# index-3 subject rather than waited for.
#
# `backfill-bodies-selftest` guards a source with NO SECOND OPINION. Aztec transaction bodies
# come from one publisher with no failover, and the only thing between it and
# the corpus is that a correct payload serialises its own hash first — so the
# leading 32 bytes are the key that was requested. That check is the whole of
# the trust model, and a check never observed refusing is indistinguishable
# from `return true`. The suite drives a mismatched payload, a truncated one, a
# 404 and a rate limit against a mock store, and asserts they stay FOUR
# different counts: a hole in the corpus, a corpus that lied, and a run that
# could not ask are three different facts.
#
# THIS COUNT HAS NOW BEEN WRONG THREE TIMES, IN THE SAME WAY EACH TIME, and the
# pattern is worth stating because the next person to add a suite will be in it.
# It said "three suites, 124" while the recipe ran four: the fold suite was wired
# in with the folded Call Trace and the sentence above it was not moved. It was
# wrong again when ING-3 added the sixth — the body verifier printed 57 while
# this sentence said 31, its own CI step having said 57 for as long as the
# enumeration split. And it was wrong a third time at the pre-landing review:
# `87 + 19 + 24 + 24 + 57 + 102 = 313` against a real total of **334**, because
# `replay-selftest` had grown to 93 and `refusal-selftest` to 117 while both
# terms stayed at the value they had when somebody last read them. The failure
# mode is always the same: the suites DECLARE their own counts and this sentence
# is a copy, so it goes stale silently and nothing compares the two.
#
# SO THE SENTENCE IS NOW CHECKED, which is the only thing that makes a fourth
# time impossible. `refusal-selftest` reads each term out of the suite that
# declares it, in recipe order, and checks this arithmetic as arithmetic — and it
# caught this very line stale on the run that introduced it. `calltrace-fold-selftest`
# gained a declared count for the same reason: it was the only one that
# printed its total and asserted nothing about it, so its term here was a
# number nobody could check.
#
# AND THE RECIPE BODY BELOW IS CHECKED AGAINST BOTH. The sentence and the
# checker's list were, for a while, compared only to EACH OTHER — two
# descriptions agreeing, with nothing holding either to the lines that run. A
# ninth invocation added below, with this sentence and that list left alone,
# kept all three mutually consistent at eight while nine suites executed, and
# the ninth's declared count was verified by nobody. `refusal-selftest` now
# parses these invocation lines and requires them to be the checker's list, in
# this order; a body it cannot parse, or one that parses to nothing, is a
# failure rather than a silent pass.
#
# Every term below was re-read off a run on 2026-09-12, after the review's
# fixes: `replay-selftest` 93 -> 98 (case 12's interpreter stubs) and
# `refusal-selftest` 117 -> 170 (the eighth closed-set member, the shared tally,
# the version policy, the store-outcome split, the committed captures'
# `counts` / token / `captures` shape, the three producers' argument guards, and
# this header). Then 170 -> 213 at the pre-landing fixes: the two clauses of
# `body-unavailable` (a corpus sweep for a permanent claim with no store answer
# behind it, the producer that now refuses to write one, and the legacy
# classifier that decides `pruned` from evidence instead of from the outcome's
# name), the three `@1` subjects the migration tool holds out, and
# `counts.captureSessions` — which appeared at ONE site tree-wide and was
# covered by nothing, so a review's revert of it passed every suite.
#
# `yield-method-selftest` IS THE ONE WHOSE SUBJECT IS A COMMITTED READING, and it
# was added because the two readings in `tools/chain/measurements/` were read by
# NOTHING. `git grep -l` for either artifact token found only the files
# themselves. A yield figure — what fraction of a chain's transactions actually
# trace — is the number that decides whether a chain ships, which makes it the
# number most exposed to being chosen after the fact, and the two ways of
# choosing it both produce a figure that looks fine: a sample of transactions
# measures the sampler, and a single aggregate hides two windows moving in
# opposite directions. So the method is `tools/chain/yield-method.json` and
# `tools/chain/lib/yield.mjs` applies it, with the outcome partition IMPORTED
# rather than restated — a second classifier is a second place for the
# denominator to drift.
#
# Four things it watches go red, each against the committed data rather than a
# constructed subject. THE DENOMINATOR IS AN ENUMERATION: driven over a real
# capture, cross-checked against that producer's own tally, and refused when a
# reading's `transactions` is its `traced`. TWO WINDOWS MOVED IN OPPOSITE
# DIRECTIONS BY THE SAME AMOUNT leave every total untouched and are caught by
# the per-window arm alone. BOTH DENOMINATORS, with the distinction MEASURED:
# the corpus supplies committed trees on both sides — four where a population
# the chain never published an execution for makes the two differ, four where
# there is none and they are equal — and both sides are floored, so a check that
# merely printed two numbers could not pass. And A RE-RUN'S VERDICT, which has
# FOUR values and not two, because the measured case needs a third: a re-run of
# the five pinned windows read 208 traced where the reading has 211, three
# transactions moved, all three named, and the driver was observed dying on a
# signal after the VM had already simulated them. `reproduced` would be a lie
# about the figure and `not-reproduced` a lie about the producer. The mechanical
# separator is that a re-run's columns are two kinds: what the chain published
# cannot move between two runs over the same absolute range, and what this run
# achieved can — so a moved CHAIN column is `not-reproduced` however well
# attributed, and that arm is planted.
#
# TWO THINGS ABOUT THAT VERDICT WERE MEASURED AS HOLES AND CLOSED, and they are
# named here because the shape recurs. The attribution reconciled against the
# total movement in `traced` ALONE, and `traced` is a SUM over the traced
# columns — so five rows moving from `replayed` to `divergent` left it untouched
# in that window and were accepted as `differs-environmentally` with the note
# "all attributed", five unexplained divergences and all. It now reconciles PER
# WINDOW over every run column, which is the same cancellation the per-window
# rule already refuses one level up. And `bodyUnavailable`/`notAttempted` were in
# neither column list, so a re-run in which the body store served forty fewer
# bodies compared as identical; they are run columns now. Both arms are planted.
# `yield-method.json`'s `chainColumnsNote` records what the chain/run split does
# NOT establish: `privateOnly` — and `withPublicHalf`, derived from it — is
# decided off a body an off-chain store served and the installed decoder parsed,
# so it has moved for the same chain over the same ranges before; and nothing in
# either artifact anchors the chain's IDENTITY, so a reset testnet reads as a
# producer regression. Three of the five chain columns are sound; those two are
# recorded rather than trusted.
#
# THEY WERE REFERENCED BY NOTHING. Not by `just test`, not by any CI job, not
# by `ci-coverage.sh` — whose enumeration covers `ci/test/*.sh` and
# `client/Justfile`'s aggregate and reaches nothing under `tools/`. That is the
# same hole `deploy-gates` was created for after `check-assets-selftest.mjs`
# was found dead, and all of them were in it: the only evidence they could go
# red was that someone had once watched them.
#
# All TWELVE are OFFLINE and toolchain-free — plain node plus bash, a mock node
# for the freeze gate, a mock node AND a mock file store for the body verifier,
# recorded driver output for the replay rule, for the
# fold suite an event stream reconstructed from the committed sidecars rather
# than read out of a `.ct` with `ct-print`, for the health sweep a STAND-IN
# reader so the figure that counts opened recordings can be shown non-zero,
# for the yield method the two committed readings and the committed captures,
# and for the encoding suite nothing
# but files already in this repository — so they run
# on a stock runner and are wired into CI's `deploy-gates` job for exactly the
# reason its header gives: a gate that needs the busy Nix runner to prove it
# can fail is a gate that gets skipped.
chain-selftest:
    node tools/chain/replay-selftest.mjs
    node tools/chain/freeze-snapshot-selftest.mjs
    bash tools/chain/watch-chain-selftest.sh
    node tools/chain/calltrace-fold-selftest.mjs
    node tools/chain/backfill-bodies-selftest.mjs
    node tools/chain/refusal-selftest.mjs
    node tools/chain/coverage-contiguity-selftest.mjs
    node tools/chain/identifier-encoding-selftest.mjs
    node tools/chain/object-set-selftest.mjs
    node tools/chain/snapshot-contract-selftest.mjs
    node tools/chain/chain-health-selftest.mjs
    node tools/chain/yield-method-selftest.mjs
    # Needs nothing but files already in this repository: the perturbations are
    # applied to the committed READING and not to the corpus, so no container is
    # written. Without a `ct-print` two of its eight arms SKIP, are reported as
    # SKIP and are NOT counted as passed, and the version census still runs —
    # it is read from the bytes.
    node tools/chain/ct-corpus-census-selftest.mjs
    # Offline and toolchain-free like the rest: the committed input set under
    # fixtures/chain-inputs/ is read off disk, and the twenty mechanism arms
    # stand up `http.Server`s in-process rather than reaching an endpoint. It
    # does NOT run the capture — that needs the recorder binary from the
    # codetracer-evm-recorder sibling, which is why `just eth-capture` is a
    # separate recipe and not an arm here.
    node tools/chain/eth-rpc-transcript-selftest.mjs

# ── RECORD the one container a current reader can open ─────────────────────
#
# `fixtures/chain-health/readable-container/ct/*.ct` is NOT committed. It is
# produced from the sibling `codetracer-trace-format-nim`'s own fixture
# generator, so it follows that writer rather than lagging it, and
# `chain-health-selftest.mjs` runs this itself before probing the reader — this
# recipe is the same act by hand, for `just conformance
# fixtures/chain-health/readable-container` on a fresh checkout.
#
# `metacraft-dev-guidelines/policies/repo-requirements.md` §4.3 is the policy:
# `*.ct` is committed in `codetracer-example-recordings` and nowhere else,
# because a derived artefact committed beside its producer is a clock. This one
# went off — 151,552 bytes of container-version-4 CTFS that no reader at the
# 2026-10 revision opens, which took all 31 reader-dependent arms out of
# service. The tree's OTHER files stay committed and were measured to be
# unchanged by the writer move; `MAKING.md` carries that table.
#
# THREE EXIT CODES, because two would hide the one that matters: 0 recorded,
# 2 the sibling is not checked out (SKIP, and the state CI is in), 1 it IS
# checked out and would not produce a container (FAIL — a break, not an absence).
readable-container:
    node tools/chain/make-readable-container.mjs

# ── is the recording layer healthy? ────────────────────────────────────────
#
# `just chain-health <snapshot-dir>` sweeps one prepared tree;
# `just chain-health-corpus` sweeps every snapshot tree in this repository and
# rewrites `tools/chain/measurements/chain-health.json`. Both print a
# `blocktracer/chain-health@1` artifact on stdout and a short verdict on stderr.
#
# WHY IT IS NOT PART OF `just conformance`. Conformance is a statement about a
# tree's SHAPE and it is the right shape of statement: a tree either satisfies
# the contract or it does not, and the answer is a verdict. This is a statement
# about the tree's CONTENTS — how many of its recordings reach source level, how
# many of its recordings can be pinned to a build — and the answer is a set of
# figures that get better or worse. Folding a gradient into a gate produces
# either a gate nobody can pass or a threshold nobody can defend.
#
# IT REPORTS WHAT IT DID NOT MEASURE AS LOUDLY AS WHAT IT DID. `containersOpened`
# is 0 unless `--container-reader` names a program, and a finding that could not
# be answered is printed under NOT MEASURED rather than folded into the health
# verdict.
#
# ── OPENING THE CONTAINERS, AND WHAT IT FINDS ──────────────────────────────
#
#     just chain-health-corpus --container-reader ../codetracer-trace-format-nim/ct-print
#
# THE FLAG NAMES THE PROGRAM AND NOT A MODE. The reader's modes are a fact about
# the reader's own interface, so they live in `tools/chain/health-checks.json`
# under `containerReader.probes`; a mode flag in the caller's argv is refused by
# name, because `--meta-json --events <path>` leaves the reader printing one
# shape and the tool parsing another while every other clause looks right.
#
# The reader is `codetracer-trace-format-nim`'s `ct-print`, which is not a
# dependency of this repository and is not built in CI — the same seam
# `just chain-instructions` and `just chain-positions` already use. Build it in
# a sibling checkout with `nimble buildCtPrint`, inside that repository's own
# devshell: a plain `nim c` outside it fails on `zstd.h`.
#
# WHAT IT REPORTS OVER THIS REPOSITORY'S CORPUS IS THAT ALMOST NOTHING OPENS, and
# that is a true finding rather than a broken tool. Measured 2026-09-28 with a
# reader built from a current checkout: of the 46 containers named by a committed
# snapshot row, 45 are REFUSED and the one that opens is
# `fixtures/chain-health/readable-container`, which this repository added for the
# purpose because nothing else here could be opened at all. Of the 45: 42 because
# they declare `meta.dat` schema version 3
# and the reader accepts [4, 5], refusing 3 BY NAME rather than decoding it under
# a rule that would put every source position one line high; and 3 because they
# are the shipped conformance template's 229-byte ASCII placeholders, which carry
# no container magic at all. Every finding therefore names the CONTAINER'S
# declared version as the defect, keeps the reader's own sentence as the
# evidence, and carries the reader's build id — its own sha256, because the
# reader states no version of its own and two of its builds refuse the same
# container with different exit statuses.
#
# RE-MEASURED 2026-10-04 (CRR-4). The three figures above — 46 named, 45 refused,
# 1 opened, and the 42 / 3 split of the 45 — all still hold exactly, and the
# schema census the tool reports is `{3: 42, unstated: 4}`. Two sentences do NOT:
#
#   * `the reader accepts [4, 5]` is stale. It reads `meta.dat` schema 6 ONLY, and
#     container version 5 only, as of the 2026-10 trace-format revision. The
#     refusal is still BY NAME and still for the one-line-high reason; the set it
#     is a refusal against moved.
#   * `which this repository added for the purpose` is stale in the other
#     direction. That subject's container was committed, and on 2026-10-01 the
#     writer moved past it, so from then until this re-measurement the figure was
#     46 named, 46 REFUSED, 0 opened — and all 31 reader-dependent arms of
#     `chain-health-selftest.mjs` did not run. The container is no longer
#     committed: `tools/chain/make-readable-container.mjs` RECORDS it, at test
#     time, from the sibling writer's own fixture generator. `just
#     readable-container` is the same act by hand. That is why 1 opens again, and
#     it is why 1 will keep opening the next time the writer moves.
#
# The schema skew is reported PER CONSUMER and never as one verdict, because the
# two consumers of these containers accept disjoint sets: the pinned reader above
# accepts schema 6 (it accepted [4, 5] when this paragraph was written) and the
# replay engine this repository ships to a visitor — pinned by sha256 in
# `client/hydrate/engine-pin.txt` — accepts [3]. So the same corpus is unreadable
# to one and readable to the other, and picking which one matters is not a
# decision a sweep gets to make.
#
# ── WHAT AN OPENED CONTAINER IS COMPARED AGAINST ───────────────────────────
#
# Five more questions are answered once a recording opens, and every one of them
# is in the hole the contract cannot reach. `snapshot-contract.json`'s member
# census declares the container OPAQUE — its entry has zero members — so every
# `S5-*-AGREE` rule compares a DERIVED FILE to the producer's claim and takes the
# claim as the truth. A producer that mis-measured its own recording and derived
# every sidecar from the mis-measurement conforms in every direction.
#
# Three compare the container's own counts to the row's claim, one finding per
# claim member so a drifting second copy of a number can be told from the first:
# the step count, the call count (where the container holds the claim PLUS the
# synthetic top-level frame — a relation two producers here state, not an
# arithmetic convenience), and `recording.events`, which is measurably a second
# copy of the step count: 42 of 42 committed rows carrying both have them equal.
#
# Two compare the container to what is published beside it: every source path the
# recording INTERNED must be a file in the bundle (`S5-BUNDLE-REQUIRED` asks for a
# bundle to be present and says nothing about what is in it), and the positions
# sidecar's coordinates must be the container's VALUE BY VALUE. Only the counts
# are checked anywhere else — `S5-POSITIONS-AGREE` and `S5-POSITIONS-COLUMNS` are
# both about length — and a full-length stream with the wrong values puts the
# caret on lines the execution never touched exactly as badly as a short one.
# That is also the likeliest way to get it wrong: one producer here deliberately
# re-indexes the container's path ids, and an off-by-one in that remap produces a
# correctly-counted stream in which every step points at the wrong file.
#
# One needs no container at all, which is why it has a population over the real
# corpus where its siblings do not: a bundle's declared `language` against the
# extensions of its own files, against the extensions the positions stream names,
# and that stream's schema token against the closed set of tokens this repository
# writes. `S5-POSITIONS-SCHEMA` refuses a stream that states NO token and
# republishes whatever it is handed, so a token nothing defines passes it.
#
# THE ONE SUBJECT THESE HAVE is `fixtures/chain-health/readable-container` — the
# only recording here a current reader can open. Its MAKING.md states what it is,
# what it is NOT, and every command that produced it. Read that before quoting
# anything these five checks report.
#
# ── THE RATCHET, AND WHY A THRESHOLD COULD NOT BE ONE ──────────────────────
#
# One more finding needs no container and no reader: has any chain published FEWER
# source-level recordings than the committed reading says it had?
#
# The source-absence check is a THRESHOLD AT ZERO, measured rather than read off
# its own description: driven over one chain at 40 of 40, 20 of 40, 5 of 40 and 1
# of 40 source-level rows it stays GREEN, and reddens only at 0 of 40. So a chain
# that went from forty source-level recordings to one is silent in the one check
# aimed at the operator's primary symptom. A threshold cannot fix that, because
# there is no defensible absolute number — the right count for a chain is whatever
# it has already reached. What CAN be stated is that it must not go backwards, and
# the committed reading is where the previous position is recorded. Same shape as
# the object-set baseline and the byte-identity manifest.
#
# The baseline is read by DEFAULT, because a ratchet nobody remembers to pass a
# flag for is a ratchet that never fires. `--no-baseline` says so deliberately and
# makes the check report NOT RUN with that as its reason, which is the difference
# between a check that was switched off and a check that passed. A `--baseline`
# naming a file that cannot be read is REFUSED rather than replaced by the
# default: a typo must not quietly switch off the one check that watches a chain
# going backwards. A RISE is not a finding — refreshing the reading is a separate
# reviewable act.
#
# THE EXIT CODE IS THE VERDICT AND THE CORPUS RECIPE CURRENTLY EXITS 1, which is
# the tool working rather than the recipe failing: 0 is nothing found, 1 is at
# least one finding about the recordings, 3 is only findings about what could not
# be measured, 2 is usage. The committed reading is written before the exit, so
# `just chain-health-corpus` refreshes the measurement and then reports what it
# found. Six of the seven findings it reports today are the source-level absence
# the tool was written to put a number on.
#
# Offline: it reads snapshot trees, reaches no network, and writes nothing unless
# asked. `--out` is what the corpus recipe passes.
chain-health SNAPSHOT *ARGS:
    node tools/chain/chain-health.mjs {{SNAPSHOT}} {{ARGS}}

# ── THE REFRESH CANNOT LOWER THE FLOOR IT JUST RATCHETED AGAINST ───────────
#
# This recipe writes the committed reading AND that same file is the default
# baseline the source ratchet reads. So the sequence inside one command is: read
# the old reading, ratchet against it, report any slip, overwrite the file. A run
# in which a chain went BACKWARDS would therefore report the slip and then move
# the floor down to where it slipped to, in the same command, with nothing to
# stop it. That is a record of drift where a check against drift was — the exact
# substitution `client/hydrate/engine-pin.txt` exists because of, and which that
# file says went unnoticed "for as long as it existed".
#
# So the write is REFUSED BY NAME, exit 5, naming every chain and both figures.
# Lowering a floor deliberately stays possible and costs a sentence:
#
#     just chain-health-corpus --accept-ratchet-slip "why this is right"
#
# The reason is required, is checked for being a sentence rather than a word, and
# is WRITTEN INTO the reading under `ratchetSlipAccepted` together with every
# figure it lowered. A bare flag would be a flag somebody adds to a recipe once
# and never removes, and then the ratchet is gone with no trace of when; a reason
# in the file justifies the lowered floor in the reviewable diff instead of in
# somebody's shell history.
#
# A RISE NEEDS NOTHING. A reading whose floors are below the tree is rewritten
# freely and the new floors are higher — a ratchet that refused every write would
# be a ratchet nobody could advance, which is the same uselessness from the other
# side.
chain-health-corpus *ARGS:
    node tools/chain/chain-health.mjs --corpus \
      --out tools/chain/measurements/chain-health.json {{ARGS}}

# ── does the committed reading still describe this tree? ────────────────────
#
# `just chain-health-check` sweeps the corpus and asserts the roll-up against
# `tools/chain/measurements/chain-health.json` — the reading
# `just chain-health-corpus` writes. Exit 4 means the reading no longer describes
# the tree; that is a different failure from an unhealthy tree and has its own
# status so the two cannot be confused.
#
# WHEN A READING IS BEING ASSERTED, THE READING'S VERDICT IS THE EXIT STATUS. The
# findings are printed and not folded in, because this repository's corpus carries
# real ones — 45 containers no current reader can open is the measurement the tool
# exists to report — so a gate that also failed on those would be permanently red
# and nobody would run it. Hiding them would be worse, so the count is on the
# verdict line and `just chain-health-corpus` is where they ARE the verdict.
#
# THE FLAG IS `--expect` AND NOT `--check`, because `--check <id>` already selects
# which findings to run and one word meaning two things on one command line is a
# defect waiting for a hurried reader. `tools/chain/object-set.mjs` calls the same
# operation `--expect` too, which is the closer precedent.
#
# THREE DIRECTIONS, and the difference is load-bearing. Figures about the TREE are
# compared for EQUALITY, so a change in either direction lands in a reviewable
# diff. Figures that measure how far the recording layer has got are FLOORS — the
# right number of source-level recordings for a chain is whatever it has already
# reached, so a rise is not a failure and a check that reddened on improvement
# would have stasis as its only stable state. And figures that exist only when a
# container reader was named are compared ONLY between like and like: the
# committed reading is taken WITHOUT one, deliberately, so a host that has no
# `ct-print` can still run this gate.
#
# IT FAILS ON AN EMPTY CORPUS, and that is the control worth knowing about. Every
# equality over a reading with no snapshots is satisfied; every floor against a
# zero baseline is satisfied; so a checker pointed at nothing prints that the
# reading still describes the tree, having compared nothing at all. Both sides are
# floored — the reading and the run each need a minimum number of trees and rows —
# and a side below its floor is a FAILURE with the figure quoted. A glob that
# expanded to nothing is refused by name rather than by printing the flags again.
chain-health-check *ARGS:
    node tools/chain/chain-health.mjs --corpus --quiet \
      --expect tools/chain/measurements/chain-health.json {{ARGS}} > /dev/null

# ── the committed `.ct` corpus, by population and by producer ──────────────
#
# `chain-health-check` above covers the chain SNAPSHOT directories, selected by
# `corpusSnapshotDirs()`. It does not cover `fixtures/trace/`, which carries no
# `snapshot.json` — measured, not assumed: the ten containers there were
# re-recorded from container version 4 to version 5 and `chain-health-check`
# reported "unchanged from it", correctly, because they are not its subject.
#
# WHY THIS IS A GATE AND NOT A PARAGRAPH. The committed `.ct` corpus has been
# censused by hand three times and the hand census was wrong twice — once on the
# population (a `find` counted generated copies under `client/dist/` as
# "committed", giving 78 where there are 55 tracked paths) and once on the
# PRODUCER (all 52 containers were described as chain recordings needing a node
# and a replay driver, when ten are `nargo trace` recordings of local Noir
# packages whose sources are vendored beside them and whose re-record command is
# committed). Grouping by producer is what makes that split visible, and the
# producer is the field that decides the remedy.
#
# `tools/chain/ct-corpus.json` declares the populations, their producers and the
# remedy for each. `tools/chain/measurements/ct-corpus.json` is the committed
# READING. A corpus change is allowed; a corpus change that leaves the reading
# stale is a red gate naming every delta.
#
# THREE-STATE ON THE READER, like every other optional-reader gate here: no
# `ct-print` is exit 2 and reports readability as NOT MEASURED while still
# measuring the version census from the bytes; a reading that disagrees is
# exit 1; agreement is 0. A REFUSAL IS NOT A FAILURE — the 42 chain containers
# are expected to be refused at `meta.dat` schema 3, the reading says so by
# name, and one of them suddenly opening is as much a skew as one of the ten
# that stopped.
ct-corpus-check *ARGS:
    node tools/chain/ct-corpus-census.mjs \
      --expect tools/chain/measurements/ct-corpus.json {{ARGS}}

# Re-read the census into the committed reading. Run this deliberately, after a
# corpus change, and say in the commit WHY each delta moved.
ct-corpus-read:
    node tools/chain/ct-corpus-census.mjs --json > tools/chain/measurements/ct-corpus.json

# Does the census gate decide? One perturbation per field, plus a base case so
# the others are not vacuous.
ct-corpus-selftest:
    node tools/chain/ct-corpus-census.mjs --selftest

# ── §5's member census, as the spec's own tables ───────────────────────────
#
# `tools/chain/snapshot-contract.json` is Data-Contract.md §5 in machine-readable
# form: every container the reader opens, every member it consumes, whether the
# CONTRACT requires it, and which subscript the reader reaches it with. It is what
# `snapshot-contract-selftest.mjs` checks `ingest.nim` against, and what
# `contract_rules.nim` reads at compile time so a refusal cannot cite a rule the
# contract does not state.
#
# This prints §5.2b's and §5.4's markdown tables from it. The spec still has to read
# as prose, so its tables are RENDERED rather than typed beside the census — one
# command, pasted in, so the two copies are a transcription with a reproducible
# source. It is NOT a gate and cannot be: the check runs in CI, where
# `codetracer-specs` is not checked out, so nothing holds the spec's copy to this
# one. That residual is recorded in §5.2b itself rather than papered over.
#
# Writes to stdout and touches nothing.
snapshot-contract-tables:
    node tools/chain/render-snapshot-contract.mjs

# ── reading a published tree as a SET of objects ───────────────────────────
#
# `just object-set <tree-dir>` prints `blocktracer/published-object-set@1`: the
# count, the byte total, a per-class breakdown and two digests. It is how the
# zero-regression baseline is taken and how a later tree is compared
# against it (`--expect tools/chain/measurements/published-object-set.json`).
# It reads one directory, reaches no network and writes nothing unless asked.
object-set TREE *ARGS:
    node tools/chain/object-set.mjs {{TREE}} {{ARGS}}

# ── bringing a pre-ING-3 capture into the closed set ───────────────────────
#
# The committed captures were written before `refusalReason` existed and the
# gate that now runs in every producer's write path would refuse to re-save
# them. The cheap fix would be a legacy exemption in the gate; the exempt set
# would be 929 rows, which is most of the untraced transactions this repository
# has ever published, and a gate with an exemption that large is not a gate.
# So the snapshots move instead. `--check` reports and writes nothing.
#
# ── THREE SUBJECTS ARE HELD AT `@1` AND THE TOOL REFUSES TO PROMOTE THEM ───
#
# `@1` is not only a legacy token, it is a SHAPE THE READER HAS TO BE TESTED
# AGAINST: Data-Contract.md §3.1 rule 2 obliges a reader that accepts a token
# to consume every member that token defines, and the only way to check that
# obligation is to hold an artifact in that shape and read it. This repository
# has exactly three, and a glob run over the corpus would promote all three in
# one command — it did, in a review rehearsal — leaving the reader's `@1` path
# with no population at all.
#
# They are named in `HELD_OUT_AT_V1` in the tool, each says so in its own
# `_comment` or in a `HELD-AT-V1.md` beside it, and `refusal-selftest` asserts
# both halves. `--include-held-out` is the deliberate override, for the day
# `@1` support is actually retired.
migrate-refusal-reasons *PATHS='client/fixtures/chain/*/snapshot.json':
    node tools/chain/migrate-refusal-reasons.mjs {{PATHS}}

# ── the index-0 constraint, re-taken rather than quoted ────────────────────
#
# The pipeline refuses every transaction that is not first in its block, and the
# standing justification for that costing nothing is a SENTENCE — "a sample of
# sixty-one mainnet transactions were all at index 0" — with no date, no stated
# range and no way to check it. This recipe re-takes the measurement against a
# live node and writes it where a reader can see when it was last taken.
#
# NOT IN `chain-selftest`, deliberately: it needs a node, and a suite that needs
# a network is a suite that gets skipped. The committed result at
# `tools/chain/measurements/tx-index-distribution.json` is what the offline
# suite asserts against, so the CHECK runs everywhere and only the MEASUREMENT
# needs the chain.
scan-tx-index URL='https://aztec-testnet.drpc.org' DEPTH='4000':
    node tools/chain/scan-tx-index.mjs --url {{URL}} --depth {{DEPTH}} \
      --control-sample 40 --quiet \
      --out tools/chain/measurements/tx-index-distribution.json

# ── what a frozen capture would have measured ──────────────────────────────
#
# Every transaction in `client/fixtures/chain/` reads `declaredRung: 3` and
# carries NO `artifacts` key, because its runtime predates off-chain artifact
# resolution. That is an absence of measurement and not a measured ceiling, and
# the difference cannot be settled by re-capturing: all eight bodies are pruned
# (CHAIN-CAPTURE.md §1), permanently.
#
# So it is settled without the transaction — from the container's interned
# addresses plus the instance and class the node still serves — by the resolver
# the driver itself uses. READ-ONLY over the freeze. See CHAIN-CAPTURE.md §6.1,
# including the paragraph on what a `resolved: true` here does NOT mean.
#
# Needs a runtime checkout carrying `replay/src/artifact_resolution.ts`, and
# reaches the chain, npm and a block explorer — so it is by hand and in no
# build, the same standing as `chain-instructions`.
#
#     just chain-frozen-artifacts ../aztec-avm-runtime
chain-frozen-artifacts runtime:
    node --experimental-strip-types tools/chain/resolve-frozen-artifacts.mjs \
      --runtime {{runtime}}

# ── the chain captures' instruction streams ────────────────────────────────
#
# Derive `instructions/<tx>.json` beside a committed capture's containers: the
# per-step program counter, opcode number and gas reading the recording carries.
# `ingest.nim` publishes whatever is there and the Code pane renders it as an
# instruction listing, which is the honest floor for a recording no source
# resolved for.
#
# DELIBERATELY NOT PART OF ANY BUILD, and not part of `just test`. Reading a
# `.ct` needs `ct-print` from a `codetracer-trace-format-nim` checkout, and this
# repository does not depend on that one: nothing here imports it, `flake.nix`
# does not name it, and adding it would put a Nim library on the site build's
# source-dependency graph for the sake of an offline derivation. Same standing
# as `fixtures/trace/tour/record.sh` and
# `client/fixtures/demo-session/extract-flow.mjs`: run by hand, output
# committed, and a snapshot with none is a valid tree that renders the state it
# always did.
#
# THIS COMMENT USED TO SAY THE DEPENDENCY "CANNOT BE ONE — the site build is
# hermetic", and that overstatement is worth correcting where it stood, because
# it was cited. `CHAIN-CAPTURE.md` §6.6 rested the empty Call Trace pane on it
# and concluded the frames could only ever be listed by a live session.
#
# `nix build` REALLY IS HERMETIC — sandboxed, no network — and that is not what
# was wrong. What was wrong was reasoning from it to what the SITE MAY CONTAIN.
# This derivation does not run in the build at all: it runs here, by hand, and
# commits a JSON file that is then an ordinary source input, exactly like the
# vendored `.ct` containers beside it. Hermeticity constrains what the build may
# REACH FOR; it says nothing about what a committed input may hold.
#
# The deploy makes the same distinction and states it: the workflow adds the
# replay engine to the staged site by `curl` AFTER `nix build`, precisely
# because the build cannot reach the network
# (`.github/workflows/deploy-cloudflare-pages.yml`, `fetch-engine.sh`). So the
# line between "the build is sealed" and "the product may only contain what the
# build could compute" was already drawn correctly elsewhere in this repository,
# and only §6.6 crossed it.
#
# The rule that IS real here is source-dependency hygiene, stated in the
# paragraph above. `chain-calltrace` below is the same argument taken to its
# conclusion.
#
#     CT_PRINT=../codetracer-trace-format-nim/ct-print just chain-instructions
chain-instructions:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in client/fixtures/chain/*/; do
      [ -f "$d/snapshot.json" ] || continue
      node tools/chain/derive-instructions.mjs "$d"
    done

# ── ingest ONE NAMED RANGE of historic blocks, end to end ───────────────────
#
# The unit an incremental-coverage pipeline is made of: fetch a range from the
# archive, ingest it into the published tree shape, upload it, and write down
# that it is covered and at what code version. Idempotent — a second run over a
# range uploads zero content objects.
#
# `blocktracer-chain-ingest` is a NEW binary and it exists because there was no
# way to run the real-chain producer over a range. `ingest.nim` had two callers:
# `static_export.nim`, which runs it at `isCurated` inside a whole-site build,
# and a diff harness. Neither takes a range and neither reports what it produced.
#
# THE DEFAULT BACKEND IS LOCAL AND THE DEFAULT STORE IS A DIRECTORY. Pointing
# `--backend s3` at a production bucket is an operator action with a production
# credential (DEPLOY.md §3); a local S3-compatible endpoint — `minio server`,
# `rclone serve s3` — is what this is developed against, and the object-store
# probe below is how that endpoint is shown to behave like R2 before anything
# is aimed at R2.
#
#     just chain-range 74000 74099
#     just chain-range 74100 74399 --backend s3 --bucket b --endpoint http://127.0.0.1:9099
chain-range from to *ARGS:
    nim c --hints:off -d:release -o:blocktracer-chain-ingest src/blocktracer_chain_ingest.nim
    nim c --hints:off -d:release -o:blocktracer-publish src/blocktracer_publish.nim
    node tools/chain/ingest-range.mjs --from {{from}} --to {{to}} \
      --ingest-bin ./blocktracer-chain-ingest --publish-bin ./blocktracer-publish {{ARGS}}

# ── the same range, with traces ─────────────────────────────────────────────
#
# `chain-range` produces metadata; this produces metadata AND containers, by
# giving the replay driver a body the node no longer serves. See
# `tools/chain/lib/body-proxy.mjs` for why that is a proxy and not a flag.
#
# THE FOUR PATHS ARE OPERATOR-SET AND NONE OF THEM HAS A DEFAULT WORTH GUESSING.
# This repository carries no AVM, no ct-writer and no Node with
# `--experimental-wasm-exnref`; `preflightToolchain` refuses before a single
# transaction is attempted rather than letting a run record hundreds of false
# refusals, which is what a wrong `--node` cost this campaign on 2026-09-09.
#
# RESUMABLE, and that is the point of it on a rate-limited endpoint. Re-running
# the same range never redoes a traced transaction, so a run cut short by a ban
# is continued by repeating the command — and if you were banned, GO SILENT
# FIRST. The measured cost of a `retry-after` on this endpoint is 41 minutes and
# polling it makes that longer.
#
#     just chain-replay-range 45000 45199 \
#       ../aztec-avm-runtime /path/to/node /path/to/avm.wasm /path/to/aztec_ct_writer.wasm
chain-replay-range from to runtime node avm ctwriter *ARGS:
    nim c --hints:off -d:release -o:blocktracer-chain-ingest src/blocktracer_chain_ingest.nim
    nim c --hints:off -d:release -o:blocktracer-publish src/blocktracer_publish.nim
    node tools/chain/ingest-range.mjs --from {{from}} --to {{to}} \
      --replay --runtime {{runtime}} --node {{node}} \
      --avm {{avm}} --ct-writer {{ctwriter}} \
      --rps 5 --replay-rps 5 --batch-headers 50 \
      --ingest-bin ./blocktracer-chain-ingest --publish-bin ./blocktracer-publish {{ARGS}}

# ── the seam's own suite ────────────────────────────────────────────────────
#
# NOT IN `chain-selftest`, and the reason is that recipe's own header: everything
# in it is offline AND toolchain-free, so it runs on a stock CI runner. This one
# is offline — the store and the node are two `http.Server`s it starts itself —
# but it is not toolchain-free, because the thing under test decodes Aztec's wire
# format and that serialisation lives in `aztec-avm-runtime`'s `node_modules`.
# Putting it in the stock suite would make the stock suite need a checkout, which
# is how a suite starts getting skipped.
#
#     just body-proxy-selftest ../aztec-avm-runtime
body-proxy-selftest runtime:
    node tools/chain/body-proxy-selftest.mjs --runtime {{runtime}}

# ── is a range ledger's coverage actually contiguous ────────────────────────
#
# Reads one `coverage.json` written by `ingest-range.mjs` (under its `--state`
# dir) and answers the two separate claims a "contiguous" ledger makes: that the
# ranges tile the span, and that every height inside them was actually SERVED. A
# check of only the first calls a range contiguous while the node declined half
# of it.
#
# It is a recipe rather than a loose script so it is reachable by name. It came
# from a measurement scratch tree (`.probe/`) whose other fourteen scripts were
# dropped with it: six only hammered a shared public endpoint at concurrency 24,
# seven could not run at all without a gitignored `node_modules` symlink, and
# their durable output is already committed under `tools/chain/measurements/`.
# This one is pure, argv-parameterised and reaches no network, so it survived —
# with its gitignored default ledger path replaced by a required argument.
#
#     just coverage-contiguity .chain-state/aztec-testnet/coverage.json 1 75969
coverage-contiguity ledger *SPAN:
    node tools/chain/coverage-contiguity.mjs {{ledger}} {{SPAN}}

# ── does an S3-compatible endpoint behave the way the publisher assumes ─────
#
# Drives every `ObjectStore` method against a real endpoint and prints what each
# one did. It is not part of `just test` — that suite is credential-free by
# design — and it is the check that would have caught the defect it was written
# for: `putIfAbsent` piped its body into `aws s3api put-object --body /dev/stdin`,
# which the CLI rejects during argument parsing because a pipe is not seekable,
# so the only conditional-create in the system returned false on every call and
# `publishTree` reported an EMPTY bucket as "locked by another publisher".
#
#     minio server /tmp/s3 --address 127.0.0.1:9099 &
#     AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
#       just objectstore-probe my-bucket http://127.0.0.1:9099
objectstore-probe bucket endpoint prefix="":
    nim c --hints:off -d:release --path:src -o:objectstore-probe tools/dev/objectstore_probe.nim
    ./objectstore-probe {{bucket}} {{endpoint}} {{prefix}}

# ── is all the data actually on the published instance ─────────────────────
#
# `blocktracer-validate` answers "is this TREE well-formed" about a directory on
# the machine that produced it, and it walks every object. Nobody has ever asked
# the question of PRODUCTION, and nobody could: the tree to walk is 882,639
# objects. This asks it in a bounded number of requests, read-only, and exits
# non-zero naming which of its eight checks found what.
#
# The design and the sampling argument are in
# `src/blocktracer/verify/audit.nim`'s header. In one line: the pointers are
# checked exhaustively, the RANGE LEDGER against the published height map is
# exhaustive too and costs two objects, and only "does the store hold the object
# this height names" is sampled — deterministically at every range boundary plus
# the floor and the tip, then spread over the span, with the run printing the
# omission rate that sample detects at 99% confidence.
#
# IT CANNOT WRITE. `verify/source.nim` has no write operation,
# `tests/tverifypublished.nim` asserts `not compiles(s.put(…))`, and
# `ci/test/verify-published-readonly.sh` refuses a write call being added.
# Pointing it at production is an operator action with an operator credential
# (DEPLOY.md §3) — but unlike `--backend s3` on the publisher, it is a safe one.
#
#     just verify-published --url https://blocktracer.org --tree ./tree \
#       --ledger .chain-state/aztec-mainnet/coverage.json --allow-unrunnable CENSUS
verify-published *ARGS:
    nim c --hints:off -d:release --path:src -o:blocktracer-verify-published \
      src/blocktracer_verify_published.nim
    ./blocktracer-verify-published {{ARGS}}

# The suite, including the nine deliberately-broken trees the verifier must
# refuse. Runs offline: an in-process HTTP fixture on 127.0.0.1 provides the one
# backend that can answer the cache-header question and impersonate a host that
# answers 200 for every path.
verify-published-selftest:
    nim c -r --hints:off --path:src tests/tverifypublished.nim
    bash ci/test/verify-published-readonly.sh
    bash ci/test/verify-published-readonly-test.sh

# ── has the transcribed cache contract drifted from the spec ───────────────
#
# `tools/verify/cache-policy.json` is a transcription of Static-Site-Architecture
# §2.9 (normative) and Publishing-And-Caching §4. This recomputes the sha256 of
# both sections against a `codetracer-specs` checkout and reports what moved.
#
# NOT A CI STEP, AND IT REFUSES RATHER THAN PASSING WHEN IT CANNOT LOOK: CI does
# not check out `codetracer-specs` (the same limitation `snapshot-contract-tables`
# above records), and a guard that exits 0 on an absent subject is the empty-set
# pass in disguise. Absent checkout ⇒ exit 2.
#
#     just cache-policy-drift
#     just cache-policy-drift --specs ../codetracer-specs --ref origin/latest
cache-policy-drift *ARGS:
    node tools/verify/cache-policy-drift.mjs {{ARGS}}

# ── the chain captures' call frames ─────────────────────────────────────────
#
# Derive `calltrace/<tx>.json` beside a committed capture's containers: the
# frames the recording opened, their nesting, the step each began at and the
# arguments the recorder wrote on the call.
#
# WHY IT EXISTS. The Call Trace pane served a paragraph on every real chain
# transaction — "they are listed once the session is live" — while the manifest
# beside it published `execution.frames: 1`. The frames were in the containers
# the whole time; what was missing was a derivation, not a capability. See
# `chain-instructions` above for the correction to the reasoning that had this
# recorded as impossible.
#
# SAME STANDING AS `chain-instructions`, in every respect: not part of any build
# and not part of `just test`, needs `ct-print` from a
# `codetracer-trace-format-nim` checkout, run by hand, output committed. A
# snapshot with no `calltrace/` is a VALID tree — `ingest.nim` publishes
# whatever is there and the pane falls back to the note it always showed.
#
#     CT_PRINT=../codetracer-trace-format-nim/ct-print just chain-calltrace
chain-calltrace:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in client/fixtures/chain/*/; do
      [ -f "$d/snapshot.json" ] || continue
      node tools/chain/derive-calltrace.mjs "$d"
    done

# ── the Noir-frame fixture, and its two derivations ─────────────────────────
#
# `client/fixtures/noir-frames/` is the container the NEW recorder would have
# written for the transaction this repository publishes. It exists because that
# transaction cannot be re-recorded — the node serves bodies out of its active
# pool for about an hour and that hour is long past — and because the view side
# needed a Noir call tree to be built against before one could be published.
#
# Its frame tree is `aztec-avm-runtime`'s own `ContractSourceMap` and
# `NoirFrameTracker`, imported and RUN; its bytes are the real `CtWriter` driving
# the real `aztec_ct_writer.wasm`. Its per-step AVM registers are ZERO and say so
# in `provenance.json`. Read `tools/chain/record-noir-frames-fixture.mjs`'s header
# before trusting any number out of it — the split between what is measured, what
# is reconstructed and what is zero is the whole honesty of the fixture.
#
# NEEDS AN aztec-avm-runtime CHECKOUT at 26cac14 or later with the wasm built
# (`just ct-writer-build` there), a version-matched FeeJuice artifact, and node
# >= 22 for the TypeScript imports. Same standing as `chain-calltrace`: not part
# of any build, not part of `just test`, run by hand, output committed.
#
# BOTH DERIVATIONS ARE COMMITTED and both are asserted. `calltrace/` is the
# default view and `calltrace-unfolded/` is the same container with the policy
# turned off — a default that cannot be turned off is not a default, and the two
# carrying the same forty-six frames is what makes "folded, not elided" a
# measurement rather than a claim.
#
#     just noir-frames-fixture ../aztec-avm-runtime <path>/FeeJuice.json
noir-frames-fixture avm artifact:
    #!/usr/bin/env bash
    set -euo pipefail
    out=client/fixtures/noir-frames
    node tools/chain/record-noir-frames-fixture.mjs \
      --avm-runtime "{{avm}}" --artifact "{{artifact}}" --out "$out"
    node tools/chain/derive-calltrace.mjs "$out"
    rm -rf "$out/calltrace-unfolded"
    tmp="$(mktemp -d)"
    cp "$out/snapshot.json" "$tmp/"; cp -r "$out/ct" "$tmp/"
    node tools/chain/derive-calltrace.mjs --no-fold "$tmp"
    mv "$tmp/calltrace" "$out/calltrace-unfolded"
    rm -rf "$tmp"
    node tools/chain/calltrace-fold-selftest.mjs

# ── @blocktracer/client — the Client SDK (M12a) ─────────────────────────────
# The chain-aware layer above the CodeTracer Embed SDK. See
# codetracer-specs/BlockTracer/Client-SDK.md.

# The consumer-side conformance suite. Deliberately needs NO debugger on the
# Nim path: that the chain half compiles without one is the layering.
sdk-test:
    nim c -r --hints:off tests/tclientsdk.nim

# The bidirectional import lint (Client-SDK.md §1.1), plus its own self-test —
# every rule driven against a synthetic tree carrying a deliberate violation.
# Pass CODETRACER_SRC (or keep a ../codetracer checkout) to scan the REAL Embed
# SDK for chain concepts as well.
sdk-boundary:
    ci/test/client-sdk-boundary.sh
    ci/test/client-sdk-boundary-test.sh

# The handoff: compile and run tests/tembedhandoff.nim against the real Embed
# SDK, so "a TraceSource the Embed SDK accepts" is checked by the Embed SDK.
# Needs CODETRACER_SRC or a ../codetracer checkout (ci/embed-sdk-pin.env).
sdk-test-embed:
    ci/test/embed-handoff-test.sh --require

# ── BlockTracer's own ViewModel layer (M12) ─────────────────────────────────
# Front-End-Architecture.md §3's table. The Tier-1 half runs with no debugger
# on the Nim path (`cd client && just test-viewmodels`); this is the other
# half — the degraded-state seam, compiled against the real Embed SDK, so the
# wire spellings the panes parse cannot drift from the ones this layer emits.
viewmodel-seam:
    ci/test/viewmodel-seam-test.sh --require

# ── The debug route (M8a/M8b) ──────────────────────────────────────────────
# The hermetic half — the route, the arrangement, the pane renderers, the
# source renderer, §7.0's landing rule — is `cd client && just test-debug-route`
# and needs no debugger on the Nim path. These two are the halves that do.

# The five panes rendered over the Embed SDK's OWN five ViewModels, driven
# through MockBackendService. Needs CODETRACER_SRC or a ../codetracer checkout.
debug-panes:
    ci/test/debug-panes-test.sh --require

# The VENDORED copies of CodeTracer modules: their bytes still hash to their
# manifests, and they still agree with upstream on every observable. Each
# self-test drives every failure path, so neither check is one nobody has seen
# say no.
#
# Two manifests over ONE vendor tree, `client/src/debugger/vendor/`, which
# mirrors CodeTracer's `src/` so every copy stays byte-identical to upstream
# rather than needing an edited import path:
#
#   * `headless_app/layout_model.nim` + `common/contributed_pane_id.nim` — the
#     pane arrangement and the contributed-pane grammar it imports.
#   * `viewmodel/viewmodels/flow_layout.nim` + `ui/flow_loop_math.nim` — the
#     Omniscience layout arithmetic.
#
# BOTH manifests are pinned to `ci/embed-sdk-pin.env`'s CODETRACER_REF, and both
# checks assert it. That is not decoration: part B of each check compares the
# copy against `$CODETRACER_SRC`, which IS that pin, so a manifest naming any
# other commit asks a question with no passable answer. The layout model was
# pinned to its own module's mainline until 2026-09-17 and its gate was red by
# construction on every SDK bump for exactly that reason — see the header of
# `ci/test/layout-model-vendor.sh`.
#
# For the flow arithmetic the pin carries a second meaning: the static export
# and the hydration bundle place inline values with this one arithmetic, and
# two commits would be two versions of it laying out one page.
layout-vendor:
    ci/test/layout-model-vendor.sh --require
    ci/test/layout-model-vendor-test.sh
    ci/test/flow-layout-vendor.sh --require
    ci/test/flow-layout-vendor-test.sh

# The vendored CodeTracer COMPONENT STYLESHEETS — the six `.styl` files that
# draw a CodeTracer window, and the reason the debugger stopped looking like a
# different product.
#
# A THIRD manifest over the same vendor tree, and it is here rather than in
# `layout-vendor` because what it protects is different in kind. Those two
# protect a COMPUTATION: where a pane goes, where a label goes. This protects
# the RULES — the tab strip, the connectors, the panel surface, the splitters,
# the buttons, the rows, the empty states. `client/src/design_system/
# ct_styl.nim` compiles these bytes into the stylesheet the site serves, so a
# local edit here is a fork of the product's appearance that no screenshot
# review would attribute to the right cause.
#
# Part B is a BYTE comparison, unlike the two above, and the script's header
# argues why at length: there is no observable short of the compiled CSS, the
# comparison is against a FIXED commit rather than a moving checkout so it has
# no false positive, and upstream's comments are where the reason for a rule
# lives — a copy whose prose has drifted compiles the same and has stopped
# being traceable, which was the whole point.
#
# The self-test drives all six failure paths plus the control, for the reason
# every gate here has one: a check whose failure path has never run is a check
# nobody has reason to believe.
ct-styles-vendor:
    ci/test/ct-styles-vendor.sh --require
    ci/test/ct-styles-vendor-test.sh

# ── The Noir corpus (fixtures/trace/tour) ───────────────────────────────────
# Two sets: `programs` are recordable and are the capability tour the demo chain
# publishes; `toolchainPrograms` exercise the toolchain and cannot produce a
# servable recording. See fixtures/trace/tour/README.md.

# Both sets, checked against what the toolchain actually does — including the
# KNOWN FAILURES, which report loudly when they start passing rather than
# asserting that a broken thing stays broken.
corpus-check args="":
    fixtures/trace/tour/check-corpus.sh {{args}}

# Proof that the known-failure mechanism decides in BOTH directions: an entry
# that stops holding must FAIL the run, the same observation without the flag
# must PASS, and the real corpus must pass so neither arm is vacuous.
corpus-selftest:
    fixtures/trace/tour/check-corpus.sh --selftest

# Re-record every container. DELIBERATELY, not on every build: `nargo trace` is
# not byte-deterministic. Pass an id to re-record one.
corpus-record args="":
    fixtures/trace/tour/record.sh {{args}}

# The tour's coverage of the Noir LANGUAGE, enumerated from the compiler's own
# AST enums rather than from a sample of programs. Every form is either
# demonstrated or carries an explicit reason; a form with neither fails.
corpus-coverage:
    node tools/noir-coverage.mjs

# Regenerate docs/NOIR-COVERAGE.md from the same source of truth.
corpus-coverage-doc:
    node tools/noir-coverage.mjs --markdown

# ── The engine seam (the Noir DAP port) ────────────────────────────────────
# CodeTracer's Noir DAP tests — `noir_flow_dap_test.rs`, `origin_noir_dap_test.rs`
# and the `noir-space-ship` GUI journey — over the engine BlockTracer actually
# ships and the container it actually vendors.
#
# This is the ONE lane in the repository that drives a real replay session: the
# Embed SDK's own `WorkerBackendService` against the published wasm32 engine in
# a Node worker, over `fixtures/trace/noir_space_ship/zk_shields.ct`. Every
# check names an artefact — a stepped position, a frame count, a variable's
# value, a loop iteration — and never a `success: true`.
#
# It needs the Embed SDK ($CODETRACER_SRC or ../codetracer) and an engine
# ($REPLAY_ENGINE_DIR, else client/dist/replay-engine, else it fetches the
# published one). It FAILS rather than skips when either is missing.
#
# **rc 124 means a request the engine never answered.** Not a slow test, not a
# broken one: a dropped request, which is what a pane spinning forever looks
# like from this side.
noir-engine-dap:
    ci/test/noir-engine-dap.sh

# The self-test: every rule above driven against a deliberately broken input,
# each arm asserting that the check written FOR it is the one that reddens —
# plus the control that matters for a suite whose deliverable is failures, that
# each red check goes green on the engine's own reported values and so is not
# stuck red.
noir-engine-dap-test:
    ci/test/noir-engine-dap-test.sh

# Generate a demo static tree into ./demo-site.
demo-gen out="demo-site" seed="blocktracer-demo-0":
    nim c -r --hints:off src/blocktracer_demo_gen.nim --out:{{out}} --seed:{{seed}}

# Validate a static tree against the contract.
validate dir="demo-site":
    nim c -r --hints:off src/blocktracer_validate.nim {{dir}}

# Generate a demo tree and validate it (the M5c end-to-end check).
demo: (demo-gen) (validate)

# ── the publish rehearsal: coverage, not volume ─────────────────────────────
#
# `validate` above asks whether a tree is WELL FORMED and `client-conformance`
# whether a consumer can READ it. Neither asks whether PUBLISHING it works,
# which is a property of the tree and the store together, and which was until
# now measured by publishing the whole thing and watching.
#
# That does not scale. Aztec is the first chain and a small one; a dress
# rehearsal of a large chain's tree is not something anybody runs before a
# deploy. And "run a smaller one" fails for a reason that was MEASURED on
# 2026-09-28: a 290-object rehearsal passed and a 460,589-object one then found
# a data-loss defect — because the small one had ONE CHAIN, and one chain cannot
# overwrite another's registry row. The defect needed cardinality 2, not scale.
#
# So `--mode partial` and `--mode full` are both checked against the same
# coverage contract, and BOTH can fail it. An unexercised object class, a
# missing cardinality, a conditional reached on one side only, or an invariant
# proven in the refusing direction but not the accepting one is a REFUSAL, not
# a percentage.
#
# This recipe runs the gate over the demo tree with the known-findings register,
# which fails in both directions (see `tools/rehearse/known-findings.json`).
rehearse mode="partial": (demo-gen)
    nim c --hints:off -d:release --path:src -o:blocktracer-rehearse src/blocktracer_rehearse.nim
    ./blocktracer-rehearse --tree demo-site --mode {{mode}} \
        --known-findings tools/rehearse/known-findings.json

# The same drill over any corpus, with NO register — `--tree` is repeatable, and
# two chains arriving as two producer trees is the shape the registry defect
# needs, so a real two-tree corpus makes the cross-chain invariant non-vacuous
# where a derived second chain leaves part of it vacuous (see
# `src/blocktracer/rehearse/corpus.nim`).
#
#     just rehearse-tree --tree client/dist             # the bytes about to ship
#     just rehearse-tree --tree a --tree b --mode full  # two real producer trees
#
# No register: an entry there is evidence about a specific measurement over a
# specific corpus, and applying it to a different one would excuse a finding
# nobody has looked at.
rehearse-tree *ARGS:
    nim c --hints:off -d:release --path:src -o:blocktracer-rehearse src/blocktracer_rehearse.nim
    ./blocktracer-rehearse {{ARGS}}

# Does the coverage gate BITE? Asserts both ends: a healthy corpus reaches every
# cell (a gate that can never be green gets turned off) and each deliberately
# broken corpus is refused by name.
rehearse-selftest:
    nim c -r --hints:off --path:src tests/trehearse.nim

# Report what a CONSUMER could not do with a published tree (the other end of M5b's
# seam). `validate` above asks whether the tree is well formed; this asks whether the
# client SDK can render it end to end without knowing who produced it.
client-conformance dir="demo-site":
    nim c -r --hints:off src/blocktracer_client_conformance.nim {{dir}}

# ── the recorder conformance kit ────────────────────────────────────────────
#
# One command over a `blocktracer/chain-snapshot@…` tree: ingest it, then run the
# producer-side validator and the consumer-side conformance report over what that
# produced. Three checks, none of which restates a rule — each is an existing entry
# point, and the §5 rules are `tools/chain/snapshot-contract.json`, read by the
# reader at compile time.
#
# The default subject is the shipped template, so `just conformance` with no
# argument is the kit checking itself.
conformance dir="conformance-kit/template/complete":
    nim c -r --hints:off src/blocktracer_conformance.nim --snapshot {{dir}}

# Build the kit as a RELEASED ARTIFACT: the three binaries, the template and the
# README, in one directory that carries no path back to this checkout.
#
# THIS IS WHAT A RECORDER TEAM GETS, and the three things they must not need are
# a Nim toolchain, a repository checkout and a network. The binaries are built
# HERE, by us — both existing checks are BlockTracer code, so BlockTracer has to be
# built by somebody — and `-d:release` is what makes the result a shipped artifact
# rather than a debug build of a working tree.
#
# `ci/test/conformance-kit-sandbox.sh` is the arm that proves the negatives, by
# running this artifact somewhere they all hold — 19 checks, of which the last
# six are the FOURTH absence: no specification either. A refusal taken inside
# the sandbox has its rule id resolved against `contract/snapshot-contract.json`
# as shipped, which is what a recipient with a tarball and no checkout does.
#
# IT DOES NOT REBUILD ITS SUBJECT, and that is worth knowing before quoting a
# local result. `just conformance-kit-sandbox` runs the script against whatever
# `conformance-kit-release/` currently holds — a gitignored directory that may
# have been staged at another commit — so a local green is a statement about that
# directory and not about this ref. CI runs `just conformance-kit-release`
# immediately before the script, every time, which is what makes the CI arm a
# gate; run the pair locally too if the result is going to be quoted.
#
# STAGING OUTSIDE THE CHECKOUT IS AN OPERATOR PROCEDURE, not a gate: it needs the
# toolchain and a full `-d:release` build of three binaries, so putting it in the
# sandbox script would double that script's cost for a property one command
# demonstrates. `just conformance-kit-release /some/abs/path` is that command, and
# it was measured rc 0 on 2026-09-17 into a directory outside this repository.
#
# `out` MAY BE ANYWHERE, AND UNTIL 2026-09-17 IT COULD NOT BE. Every path here was
# built as `$(pwd)/{{out}}`, so an absolute argument produced `/repo//tmp/kit` and
# a relative one could only land inside the checkout — which means there was no
# invocation of this recipe that staged the artifact OUTSIDE the repository, while
# the artifact's whole claim is that it needs no checkout. `realpath -m` resolves
# either spelling to one absolute path (`-m` because the directory does not exist
# yet), and the `rm -rf` that follows is why the resolution has to happen before
# anything is deleted rather than inside a `cp`.
#
# THE CONTRACT TRAVELS WITH IT. The README told a recorder team that a rule id
# could be resolved against `tools/chain/snapshot-contract.json` "in the
# blocktracer repository" — the one thing the kit exists so that they do not have.
# "Compiled into the binary" is true and is not the same as "travelling with you":
# a recipient holding `S5-COUNTS-ROWS` had no file to look it up in, and
# `prestateStrategy`'s closed set lived in a spec document the release omits. The
# four data files the reader itself reads are copied in beside the binaries.
#
# `identifier-encodings.json` joined them when Data-Contract.md §5.6's declaration
# became reachable: the README now tells a recorder to pick an encoding token out
# of a closed set, and a closed set named in a README that does not travel with
# the README is a set the recipient cannot read.
conformance-kit-release out="conformance-kit-release":
    #!/usr/bin/env bash
    set -euo pipefail
    out="$(realpath -m '{{out}}')"
    rm -rf "$out"
    mkdir -p "$out/bin" "$out/contract"
    nim c -d:release --hints:off --out:"$out/bin/blocktracer-conformance" src/blocktracer_conformance.nim
    nim c -d:release --hints:off --out:"$out/bin/blocktracer-validate" src/blocktracer_validate.nim
    nim c -d:release --hints:off --out:"$out/bin/blocktracer-client-conformance" src/blocktracer_client_conformance.nim
    cp -r conformance-kit/template "$out/template"
    cp conformance-kit/README.md "$out/README.md"
    cp tools/chain/snapshot-contract.json "$out/contract/snapshot-contract.json"
    cp tools/chain/snapshot-format.json "$out/contract/snapshot-format.json"
    cp tools/chain/refusal-reasons.json "$out/contract/refusal-reasons.json"
    cp tools/chain/identifier-encodings.json "$out/contract/identifier-encodings.json"
    echo "conformance kit staged in $out/ — run $out/bin/blocktracer-conformance --snapshot $out/template/complete"

# Prove the released artifact needs no toolchain, no checkout and no network.
conformance-kit-sandbox:
    ci/test/conformance-kit-sandbox.sh

# ── Ethereum mainnet: container + chain data -> a §5 snapshot tree ──────────
#
# `tools/chain/produce-eth-snapshot.mjs` is the SECOND chain-snapshot producer in
# this repository and it shares no abstraction with the first. The Aztec
# producers are `capture-chain.mjs` and `follow-chain.mjs`; this is Ethereum
# mainnet's, written concretely and duplicatively on purpose — Chain-Delivery
# DEL-7 is the milestone allowed to extract a seam from the two, once there are
# two real consumers to measure one against (ING-7's two-consumer rule).
#
# IT TAKES A CAPTURE, AND THE CAPTURE IS NOW REPRODUCIBLE FROM COMMITTED INPUTS
# — see `just eth-capture` below, which is the recipe to reach for. This one is
# the bare producer: it takes a capture directory somebody already has and turns
# it into a tree, with no opinion about where the capture came from.
#
#     # 1. the capture, offline, from the committed input set
#     just eth-capture <recorder-binary> <recorder-commit>
#
#     # 2. or the bare producer over a capture of your own
#     just eth-snapshot <tx> <capture-dir> <run.log> <recorder-commit> <out-dir>
#
#     # 3. verify, from the RELEASED kit rather than from this repository's suite
#     just conformance-kit-release /abs/path/to/kit
#     /abs/path/to/kit/bin/blocktracer-conformance --snapshot <out-dir>
#     just eth-snapshot-control <out-dir> /abs/path/to/kit
#
# `--dry-run` prints the counts, the window and the archive-floor probe without
# writing anything, which is the cheap way to see what a run would publish.
eth-snapshot TX CAPTURE LOG COMMIT OUT *ARGS:
    node tools/chain/produce-eth-snapshot.mjs \
      --tx {{TX}} --capture {{CAPTURE}} --recorder-log {{LOG}} \
      --recorder-commit {{COMMIT}} --out {{OUT}} {{ARGS}}

# ── and the control that makes a green conformance run a VERDICT ────────────
#
# `blocktracer-conformance` printing `VERDICT: this tree conforms` is evidence
# about the tree only if the same command, on the same tree, with ONE member
# changed, refuses AND names the §5 rule that member belongs to. This runs the
# released kit over the tree and then over the same tree one member at a time.
#
# NOT IN `chain-selftest`, deliberately, and for the reason that recipe's own
# header gives about everything in it: every suite there is offline and
# toolchain-free over files already in this repository. This one needs a CAPTURE
# and a RELEASED KIT (gitignored), so wiring it in would buy a suite that reports
# SKIP forever. It is three-state instead: rc 0 every arm held, rc 1 an arm did
# not, rc 2 a subject is missing and NOTHING WAS MEASURED.
#
# THE REASON THE CAPTURE IS A PRECONDITION HAS CHANGED, and the sentence that
# used to be here is corrected rather than left standing. It said the capture was
# "not committable — the `.ct` ban", which was true of the CONTAINER and is still
# true of it. But the capture is no longer unavailable offline: its INPUTS are
# committed under `fixtures/chain-inputs/ethereum-mainnet/`, and `just
# eth-capture` produces the container and the tree from them in about nine
# seconds with no route off the host. What keeps this out of `chain-selftest` is
# now the RECORDER BINARY — a Rust build in the `codetracer-evm-recorder` sibling,
# which this repository does not build. The obstacle is the toolchain, not the
# chain data.
eth-snapshot-control SNAPSHOT KIT *ARGS:
    node tools/chain/produce-eth-snapshot-control.mjs \
      --snapshot {{SNAPSHOT}} --kit {{KIT}} {{ARGS}}

# THE ONE TRANSACTION THE COMMITTED INPUT SET DESCRIBES: a USDT transfer at
# mainnet block 26,083,328 index 8, hardfork PRAGUE, reached by replaying the 8
# preceding transactions in its block. Named once, here, because three recipes
# key a fixtures path from it and a second spelling would point one of them at a
# directory that does not exist.
ETH_CAPTURE_TX := "0xf6998cac9f5d2843729743b866bdc4b09bd119774bbec5e56f69f8819f2b71aa"

# ── the Ethereum capture, from COMMITTED INPUTS, with no network at all ─────
#
# `fixtures/chain-inputs/ethereum-mainnet/<tx>/` is the whole JSON-RPC
# conversation the capture reads: 472 answers, every one of them a fact about a
# finalised mainnet block. `tools/chain/eth-rpc-transcript.mjs --replay` serves
# them from a loopback port and SERVES NOTHING ELSE — there is no fall-through to
# the network, because replay mode never constructs an upstream client — so the
# capture below runs to completion in a namespace with no route off the host.
#
# WHY INPUTS AND NOT THE RECORDING. The `.ct` ban refuses a committed container
# and is right to: a recording pins a recorder version nothing tracks, and
# `fixtures/chain-health/readable-container` measured the cost of the other
# choice (regenerating it moved `containerBytes` 151,552 -> 77,824 across two
# container versions while not one checked fact moved). A transaction body, a
# block header and the account/storage/code state a replay reads cannot churn,
# because the chain they describe cannot change. So the inputs are committed and
# the container is produced.
#
# WHAT IT STILL NEEDS, and what therefore keeps it out of `chain-selftest`: the
# recorder BINARY, which is a Rust build in the `codetracer-evm-recorder`
# sibling and is not in this repository. The chain data is no longer the
# obstacle; the toolchain is.
#
# The container is NOT byte-identical between two runs over the same inputs, and
# that is a property of the RECORDER rather than of the inputs — measured over
# eight offline runs from this one transcript. Two mechanisms: a UUIDv7 recording
# id (every run differs) and the emission order of two storage variables within a
# step (a per-process coin flip). Decoded through `ct-print --full` the eight runs
# produce exactly two outputs, and both of them also occur online, so the
# transcript reproduces the live capture up to the recorder's own nondeterminism.
#
# `COMMIT` IS REQUIRED AND IS NOT DERIVED, which is deliberate. It is the commit
# of the checkout that BUILT the binary in `RECORDER`, it is published into every
# row's `runtimeCommit`, and NOTHING HERE CAN READ IT OFF THE BINARY —
# `codetracer-evm-recorder --version` answers `0.1.0` and no commit. A default of
# `git -C ../codetracer-evm-recorder rev-parse HEAD` would be right only when the
# binary came from that one checkout at its current HEAD, and silently wrong — not
# absent, WRONG — for a binary built in a worktree or before a pull. A figure
# published into provenance has to be stated by whoever knows it.
eth-capture RECORDER COMMIT TX=ETH_CAPTURE_TX OUT=".eth-capture/tree" *ARGS:
    node tools/chain/eth-rpc-transcript.mjs \
      --replay --transcript fixtures/chain-inputs/ethereum-mainnet/{{TX}} -- \
      bash tools/chain/eth-capture.sh \
        --recorder {{RECORDER}} --recorder-commit {{COMMIT}} \
        --tx {{TX}} --out {{OUT}} \
        --transcript fixtures/chain-inputs/ethereum-mainnet/{{TX}} {{ARGS}}

# Re-record the committed input set against a live archive endpoint.
#
# THE ONE RECIPE HERE THAT NEEDS THE NETWORK, and the only one that should. It
# proxies the same capture to a real endpoint and writes every distinct answer
# into the fixtures tree, so `just eth-capture` can replay it forever after.
# ~3 minutes against a free public archive; the offline replay of the same
# conversation takes ~9 seconds.
#
# Re-record only for a reason you can state: the inputs are immutable facts, so a
# re-record over the SAME transaction should move only `recordedAt`, the two
# tip-dependent answers (`eth_blockNumber`, `eth_getBlockByNumber ['finalized']`)
# and the endpoint-identity ones. A re-record that moves an `immutable` answer is
# a finding about the endpoint, not a refresh.
eth-inputs-record RECORDER COMMIT TX=ETH_CAPTURE_TX UPSTREAM="https://eth.drpc.org" *ARGS:
    node tools/chain/eth-rpc-transcript.mjs \
      --record --upstream {{UPSTREAM}} \
      --out fixtures/chain-inputs/ethereum-mainnet/{{TX}} -- \
      bash tools/chain/eth-capture.sh \
        --recorder {{RECORDER}} --recorder-commit {{COMMIT}} \
        --tx {{TX}} --out .eth-capture/tree {{ARGS}}

# Hash every committed input against its manifest and report the ledger.
#
# Offline, toolchain-free, and in `chain-selftest` through
# `eth-rpc-transcript-selftest.mjs`, which runs this check over the real tree as
# well as over planted defects.
eth-inputs-verify TX=ETH_CAPTURE_TX:
    node tools/chain/eth-rpc-transcript.mjs \
      --verify --transcript fixtures/chain-inputs/ethereum-mainnet/{{TX}}

# Publish a generated tree into a local object-store directory (M8 delta publisher).
# Idempotent + resumable: re-run to upload only new objects and flip current.json.
publish tree="demo-site" dest="published":
    nim c -r --hints:off src/blocktracer_publish.nim --tree {{tree}} --backend local --dest {{dest}}

# ── Visual-design capture harness (VD.0) ────────────────────────────────────
# Screenshots of every named view at every viewport in both themes. See
# tools/capture/README.md. `capture` with no arguments is a FULL REGENERATION
# and cleans screenshots/ first, so a renamed view leaves no stale image.

# Install the pinned Playwright package and its browser (once).
#
# `npm ci` and not `npm install`: the lockfile pins the exact version, and that
# version must equal the one the pinned Nix environment's browser bundle was
# built for (`nix run .#capture-env -- --print-pin | grep playwright`). A skewed
# pair usually WORKS and silently changes the pixels, which is why
# lib/pinned-env.mjs refuses it rather than hashing it.
#
# The browser download is for HOST runs only. Inside the pinned environment the
# browsers come from the store, so the download is skipped there.
capture-setup:
    cd tools/capture && npm ci --no-audit --no-fund && npx playwright install chromium

# Capture. Pass targeting flags through, e.g.
#   just capture "--view tx-detail --size wide --theme dark"
capture args="":
    node tools/capture/capture.mjs {{args}}

# Print the named view list, the viewport set, the theme axis and the canary.
capture-list:
    node tools/capture/capture.mjs --list

# verify_capture_covers_named_view_list, verify_full_regen_removes_stale_images
# and verify_corpus_subject_drift_is_detected — the last one being the check that
# every PNG is a photograph of the subject its view still resolves to. The first
# three assertions are about names; that one is about content, and it is the only
# thing that notices a chain rename moving every image's subject while the view
# list, the file list and the chain coverage all stay green.
capture-coverage:
    node tools/capture/check-coverage.mjs

# verify_no_badge_is_clipped_out_of_its_own_cell.
#
# The assertion `check-coverage` cannot make. E proves every published chain is
# the SUBJECT of a ready view; it says nothing about whether the page can be
# READ, and on 2026-09-05 that gap shipped a provenance label cut at
# `live Noir call f` — the debugger register's only claim to be showing real
# network data — with every gate in the tree green.
#
# It walks the BUILT REGISTRY rather than `views.mjs`, so it reaches the real
# chains' transaction pages, which no captured image shows: every `tx-detail--*`
# view resolves through the synthetic chain. Two controls run first and the
# sweep is not believed unless both hold — exit 2 means the instrument failed,
# which is a different verdict from exit 1, a page defect.
capture-legibility:
    node tools/capture/check-badge-legibility.mjs

# verify_copy_result_is_shown_without_colour_alone.
#
# The assertion H2 cannot make. H2 asks whether the stylesheet has a RULE for
# every class the bundle adds; `stylesheetDrawsClass` is one regex, so `.copied{}`
# — a rule drawing nothing — turns it green. This asks what the rule DRAWS: that
# both copy results render, differ from the un-clicked control, differ from each
# other, and stay distinct with colour removed, in both themes.
#
# `bindCopy` promises "The result is SHOWN, both ways … a copy control that
# silently failed would be the affordance-that-lies defect wearing a tick", and
# until 2026-09-06 nothing drew either class, so neither result was shown.
capture-copy-affordance:
    node tools/capture/check-copy-affordance.mjs

# verify_canary_capture_is_byte_identical — ADVISORY on a host; use
# `just capture-canary-pinned` for a tier-1 verdict.
capture-canary:
    node tools/capture/check-canary.mjs

# What the pinned capture environment fixes, and its content-hash id. Two
# hashes are comparable only if two runs print the same id.
capture-env-pin:
    nix run .#capture-env -- --print-pin

# The tier-1 determinism canary, in the pinned capture environment
# (tools/capture/capture-env.nix — browser build, fontconfig set and renderer
# flags fixed; no daemon, no VM).
#
# ON DARWIN THIS IS STILL ADVISORY. The pinned Chromium rasterises through the
# host's CoreGraphics/CoreText stack, which no derivation can pin, so the
# harness refuses to call it a tier-1 verdict however pinned the inputs are.
# Linux is where a tier-1 verdict is producible, and CI is the environment that
# has to reproduce itself.
capture-canary-pinned args="":
    nix run .#capture-env -- node tools/capture/check-canary.mjs --no-build {{args}}

# Full regeneration in the pinned capture environment.
capture-pinned args="":
    nix run .#capture-env -- node tools/capture/capture.mjs --no-build {{args}}

# All four VD.0 verifications in the pinned capture environment.
capture-selftest-pinned:
    nix run .#capture-env -- node tools/capture/selftest.mjs

# The gate a baseline comparison must pass before it may be believed.
capture-gate:
    node tools/capture/require-deterministic.mjs

# ── Journey conformance (spec claims, judged in a browser) ──────────────────
# Each journey is a sentence from the spec — "a visitor who opens X sees Y" —
# asserted by loading the artefact CI deploys in a real browser. See
# tools/journeys/README.md for what is and is not claimed.
#
# These are NOT `just test`: that recipe is the Nim suites over rendered markup,
# which run in seconds and need no browser. These need a built site, a browser
# and — for the journeys that drive a live session — the 18 MB replay engine.

# NOT into client/dist: the exporter removes that directory and writes it again,
# so an engine staged inside it is destroyed by the next export.

# Fetch the PINNED replay engine into client/.replay-engine-cache, once (18 MB).
journeys-engine:
    ./client/hydrate/fetch-engine.sh client/.replay-engine-cache

# ── the engine pin ─────────────────────────────────────────────────────────
#
# The engine is the one artefact this repository consumes and does not build,
# from an origin that always serves its publisher's latest deployment. It used
# to be taken unpinned: two agents an hour apart on 2026-09-04 received
# different engines (`e63dd40a…`/18,117,700 and `22acb8e1…`/18,117,658 bytes)
# and lost a like-for-like comparison to it, and the sha256 block that would
# have caught it was RECORDING the hashes rather than checking them.
#
# `client/hydrate/engine-pin.txt` now names the bytes; `fetch-engine.sh`
# asserts them; and these two recipes are the check and the deliberate bump.

# Does the pin bite? Nine refusals over a synthetic origin, plus the three
# places that describe the engine (pin, Nim constant, deploy workflow) agreeing.
# Offline — a gate that needs the publisher to be up gets skipped.
engine-pin-check:
    node tools/deploy/engine-pin-selftest.mjs

# ── existence checked as freshness ─────────────────────────────────────────
#
# One mechanism, 10 reuse-decision sites in this repository. A guard tests that
# a built artefact is THERE and the decision made on the answer is that it is
# THIS SOURCE'S. Every one of them carried a remedy — "build it first", "run
# without --no-build first" — naming the exact condition an existence test
# cannot detect.
#
# THAT NUMBER IS NOW CHECKED, and it needed to be: it said EIGHT while
# `build-freshness-selftest.mjs`'s `SITES` held ten, having been re-measured on
# 2026-09-05 (the register before that said fifteen across both repos and the
# tree said otherwise) and never moved again as sites were added. It is the same
# copy-goes-stale failure as the `chain-selftest` header above, in a second
# comment, and it was found the same way — by reading the tool instead of the
# sentence. The suite now parses this line and compares it to its own list, so a
# site added there without moving this number is a red rather than a drift.

# Does the freshness question decide, and is it asked at every reuse decision?
build-freshness-selftest:
    node tools/capture/build-freshness-selftest.mjs

# Move the pin to the engine the publisher is serving NOW, and print the diff.
# Deliberately manual: a pin a script updates on its own is the unpinned state
# wearing a file. Review the diff, reconcile ReplayEngineWasmBytes, commit both.
engine-pin-update:
    ./client/hydrate/update-engine-pin.sh

# Run the journeys over an already-built site (client/dist).
journeys *ARGS:
    node tools/journeys/run.mjs {{ARGS}}

# `export-hydrated`, not `export`: the two disagree about the debug route, and
# the deployed one is the one that ships the hydration bundle.

# Build the deployed shape, then run every journey over it.
journeys-build: journeys-engine
    cd client && just export-hydrated
    node tools/journeys/run.mjs

# Slower than `journeys-build` and the stronger claim: it removes every question
# about which flags the local build used. This is what CI runs.

# The journeys over `nix build .#default` — byte-for-byte what the deploy uploads.
journeys-deployed:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#default
    rm -rf .journey-site && mkdir -p .journey-site
    cp -R result/. .journey-site/
    chmod -R u+w .journey-site
    # INTO THE CACHE, and let the runner stage from there — which is what the
    # `journeys` CI job already does, and what `lib/engine.mjs` is written for.
    # Fetching straight into `.journey-site/replay-engine` made this the only
    # path that could present `stageEngine` with two complete-but-different
    # engines (a fetched one in the tree, an older one in the cache), which it
    # now REFUSES rather than silently picking between. One fetch, one cache,
    # one engine, and `--engine-cache` stays the only way to name a different one.
    ./client/hydrate/fetch-engine.sh client/.replay-engine-cache
    node tools/journeys/run.mjs --dist .journey-site

# Each mutation is restored byte-for-byte, and the assertion is proved green
# again afterwards — otherwise a mutation that failed to apply scores a kill.

# Do the journeys bite? One mutation per arm, each aimed at one named assertion.
journeys-selftest:
    node tools/journeys/selftest.mjs

# One SHARD of it, for a runner with a wall-clock box. 62 arms is ~115 minutes
# and `the-timeline-can-be-dragged` alone is ~45 of them; a run under an agent's
# background task was killed at ~60 minutes on arm 47 of 62 with no verdict.
# `--arm` cannot answer that — it selects by name, and a name is not a budget.
#
#   just journeys-selftest-shard 1 4     # …and 2 4, 3 4, 4 4, in any order
#   just journeys-selftest-combine 4
#
# A SHARD IS NOT A RUN. Its verdict is about the arms it holds; `combine` is
# where the suite's claim is made, and it refuses unless the shards cover the
# arm list exactly.
journeys-selftest-shard I OF:
    node tools/journeys/selftest.mjs --shard {{I}}/{{OF}}

# ONE verdict over the shard journals. Fails unless every arm was run exactly
# once and killed; a shard that never ran is reported by name as DID NOT RUN,
# because "three of four shards passed" is not a claim about this suite.
journeys-selftest-combine OF:
    node tools/journeys/selftest.mjs --combine {{OF}}

# Does the selftest SAY when it did not run? It has been observed dying part-way
# through its arm list with no RESULT line, and a stall producing no verdict
# reads to a human exactly like a suite nobody bothered to run. Machinery that
# reports an ending is only exercised by an ending, so an ordinary run covers
# none of it: this produces four real ones — an unmatched filter, SIGTERM
# mid-arm, SIGKILL mid-arm, and a throw — and demands each name itself. It also
# proves the SIGTERM path puts the mutated file back, which a `finally` cannot.
journeys-selftest-verdict:
    bash tools/journeys/selftest-verdict-test.sh

# All four VD.0 verifications, end to end.
capture-selftest:
    node tools/capture/selftest.mjs

# ── Review brief and the quality gate (VD.1) ────────────────────────────────
# The brief's §4 is generated from tools/capture/expectations.mjs; the gate is
# evaluated over reviews/ledger.json. See tools/visual-review-brief.md.

# Regenerate the brief's per-view expected-elements section.
review-brief:
    node tools/capture/render-brief.mjs

# verify_brief_has_expectation_block_per_view
review-check-brief:
    node tools/capture/check-brief.mjs

# verify_corpus_names_the_build_it_photographs (H1) and
# verify_hydration_adds_no_class_the_page_cannot_draw (H2).
#
# The campaign photographs `client/dist` — `just export`, zero JavaScript — and
# the deployed site is `flake.nix`'s `packages.default`, which exports the same
# routes with `-d:hydrationBundle`. `debugLayout` emits that script, so every
# `debugger*` view and `tx-detail--session` are captures of a build no visitor
# is served. That is a gap in the INSTRUMENT, and until VD.11 nothing a reviewer
# read said which build was in front of them: one shipped reason string
# misattributed its own cause to it and one P1 was nearly filed on it.
#
# H1 decides the per-view answer from the two built trees and `render-brief.mjs`
# renders it into every block, so the brief's claim is measured. H2 is the
# assertion the campaign could not make before: a class the shipped bundle adds
# and the inlined stylesheet cannot draw is invisible to every capture and every
# reviewer, which is the affordance-that-lies defect with a build boundary
# hiding it.
#
# NO VERDICT rather than PASS without both trees — `just capture ""` builds them.
capture-hydration-divergence:
    node tools/capture/check-hydration-divergence.mjs

# Re-measure and rewrite the committed map. Read the diff: a view moving between
# arms means a route started or stopped serving a session.
capture-hydration-divergence-write:
    node tools/capture/check-hydration-divergence.mjs --write

# Emit the sub-agent prompts for one captured image, e.g.
#   just review-prompt "--view tx-detail --size wide --theme light --all"
review-prompt args="":
    node tools/capture/review-prompt.mjs {{args}}

# Merge reviewer reports into reviews/ledger.json. The ONLY way an entry gets
# into the ledger: a hand-written one is how VD.1's reviewer defeated the
# determinism gate, and the ledger is the gate's evidence. Each report is the
# ```json block brief §10 Part 2 defines.
#
#   just review-ingest "--dir reviews/rounds/vd5-round3 --gate-scope debugger/wide/dark"
#
# It also establishes the one thing gate.mjs cannot: that all six reviewers of
# a triple looked at the SAME bytes (G2's "the exact image"), by recording each
# capture's sha256 and refusing a set that disagrees.
review-ingest args="":
    node tools/capture/ingest-review.mjs {{args}}

# Does every ledger entry still match the report it was built from?
#
# `imageSha256` establishes that six reviewers looked at the same pixels;
# nothing established that the LEDGER still matches the round file it claims to
# have been built from — and that gap is not hypothetical. A reviewer agent that
# stalled and was relaunched finished 68 minutes later and rewrote its round
# file after the ingest had run, leaving a committed ledger entry and a file on
# disk that disagreed while every check in the pipeline stayed green: the gate
# re-hashes the IMAGE, and ingest had already finished.
#
# Reports NO VERDICT rather than PASS over a ledger with nothing to check.
#
# Pass a round directory to ALSO check the other direction — that every report
# FILE in it parses and reached the ledger:
#
#   just review-verify reviews/rounds/vd9-r1
#
# The two are different questions and the second one is not implied by the
# first. `--verify` walks the LEDGER, so a report that was never ingested leaves
# nothing to iterate over and the round looks complete from that side while a
# reviewer's judgement is missing from the evidence the gate decides over. In
# vd9-r1 a report was written with its json fence opened and never closed;
# ingest refused it, correctly and loudly, and had that refusal scrolled past,
# every remaining check would have been green over a five-lens "six-lens" triple.
# It is the file-existence-is-not-completion hazard once more, one step later.
review-verify round="":
    node tools/capture/ingest-review.mjs {{ if round == "" { "--verify" } else { "--verify-round " + round } }}

# Proof that the ingest refuses — one case per rule, plus a base case that must
# be ACCEPTED so the file cannot pass by rejecting everything.
review-ingest-selftest:
    node tools/capture/ingest-selftest.mjs

# verify_gate_definition_is_machine_checkable — the gate over the findings ledger.
review-gate args="":
    node tools/capture/gate.mjs {{args}}

# The ledger schema and the five gate conditions.
review-gate-explain:
    node tools/capture/gate.mjs --explain

# Proof that the gate decides: every condition independently blocks.
review-gate-selftest:
    node tools/capture/gate-selftest.mjs

# verify_deliberate_break_is_detected — list, run, or grade a recorded round.
review-break args="--list":
    node tools/capture/break-check.mjs {{args}}

# All three VD.1 verifications, end to end.
review-selftest:
    node tools/capture/review-selftest.mjs

# ── Foundations pass (VD.2) ─────────────────────────────────────────────────
# The web-lineage token layer lives in client/src/design_system/web.tokens.json
# and is emitted by tokens.nim. See docs/DESIGN-DIVERGENCES-WEB.md.

# verify_no_raw_values_in_views, plus the Design-System.md §4.1 divergence rule.
# --require-built turns the shipped-CSS cross-check from NOT RUN into a failure,
# so the local run is strictly stronger than CI's bare-Node one.
design-check:
    node tools/design/check-tokens.mjs --require-built

# The same checks without a build — exactly what the visual-design CI job runs.
design-check-bare:
    node tools/design/check-tokens.mjs

# What each check decides, and why the allowlist is what it is.
design-explain:
    node tools/design/check-tokens.mjs --explain

# Regenerate the implemented-binding table in the divergence document.
design-bindings:
    node tools/design/check-tokens.mjs --write-bindings

# What each STALE `ledger@<revision>:<id>` citation points at, then and now.
#
# B4 NOW CALLS THIS (Q21). It used to assert revision CURRENCY as a proxy for
# "this citation still means what the comment says", which never missed a
# meaning change and fired on every citation at every ingest regardless of what
# the round touched — three consecutive rounds turned the same five tx-detail
# sites red while re-reviewing debugger triples, all SAFE-RESTAMP every time.
# `tools/design/lib/citation-meaning.mjs` is the shared half; B4 fails only on
# MEANING-CHANGED, on an id that has left the ledger, and on a revision not in
# history.
#
# This command stays, and is still the thing to run when B4 is red: it prints
# the two texts side by side so the reader can see WHAT changed rather than
# being told THAT something did.
#
# Prints the finding as it stood at the cited revision beside the finding at
# that id now, and classifies each site SAFE-RESTAMP or MEANING-CHANGED.
design-citations:
    node tools/design/citation-evidence.mjs

# Proof that the token lint DECIDES: every rule driven against the real product
# source carrying one deliberate violation, restored byte-identically after.
design-selftest:
    node tools/design/check-tokens-selftest.mjs

# verify_the_arrangement_did_not_move — the element-geometry diff between two
# BUILT TREES, for the operator's standing constraint on every finish pass:
# "The special arrangement on the blockexplorer page stays (i.e. the top bar,
# the transaction details panel, etc)."
#
# It looks at no pixels — a finish pass is allowed to change every one of them.
# It compares the page-absolute box of every structural element, the count of
# each, and the document's own tag-plus-class sequence, and prints what differs.
#
# It takes TWO trees, which is why it is not a CI gate and is not in
# `design-verify`: CI has one. Build the comparison tree first —
#
#   git stash push -- client/src/components/styles.nim
#   (cd client && just export) && cp -R client/dist /tmp/dist-before
#   git stash pop && (cd client && just export)
#   just design-arrangement /tmp/dist-before client/dist
#
# exit 0 nothing moved · 1 something did · 2 the check could not run.
design-arrangement BEFORE AFTER="client/dist":
    node tools/capture/check-arrangement.mjs {{BEFORE}} {{AFTER}}

# verify_foundations_round_reaches_bar — the gate narrowed to the foundations
# criteria, with the FULL gate reported alongside it and never in place of it.
review-gate-foundations args="":
    node tools/capture/gate.mjs --foundations {{args}}

# Every VD.2 design check, including the ones that need a build. Run
# `cd client && just export` first — `design-check` passes --require-built and
# fails, rather than skipping, when there is no dist/ to cross-check.
design-verify: design-selftest design-check

# Live-reload dev server for the IsoNim client site. Runs the client's real
# static exporter, serves client/dist/, and reloads every open tab on any edit
# under client/src or src/ (the shared contract + demo generator). Delegates to
# the client workspace so paths resolve from there. `just dev [PORT] [HOST]`.
dev *ARGS:
    cd client && just dev {{ARGS}}

# Build the CLI binaries.
build:
    nim c --hints:off -d:release -o:blocktracer-demo-gen src/blocktracer_demo_gen.nim
    nim c --hints:off -d:release -o:blocktracer-validate src/blocktracer_validate.nim
    nim c --hints:off -d:release -o:blocktracer-publish src/blocktracer_publish.nim

# ── is the PUBLISHED KEY LAYOUT unchanged? ─────────────────────────────────
#
# `just byte-identity <ref>` builds both producers from `<ref>` AND from the
# working tree, runs both over the same six committed captures, manifests every
# published object with sha256, and reports the object count and the
# differing-line count per tree and in total.
#
# IT TAKES A REF BECAUSE THE CLAIM IS ABOUT TWO BUILDS. "Every shard path this
# project has published is still addressable" (Publishing-And-Caching.md §6.1,
# §6.2) cannot be asserted by any test in this repository: a test compiled from
# one tree can only see one of the two producers the claim compares. There is no
# default ref, because a default of HEAD would compare the working tree to itself
# whenever the change under review was already committed, and report zero for
# that reason.
#
# WHY IT IS A RECIPE NOW. It was an operator procedure, and every reviewer
# re-invented it from nothing — two trees, six captures, sha256 manifests, mutant
# controls. The last one recorded that rebuilding it consumed most of the review.
#
# `just byte-identity-mutant <ref>` ADDS THE CONTROL, and the control is not
# optional evidence: this diff has reported zero on every run it has ever had,
# and a comparison that always reports zero is indistinguishable from one that
# cannot fail. The mutant builds a third pair from a COPY of the working tree
# with one field of `tools/chain/identifier-encodings.json` changed — `hex`'s
# `stripPrefix`, emptied — and REQUIRES the differing-line count to be non-zero.
# Nothing is mutated in this repository, so an interrupted run cannot leave it
# modified.
#
# THE MUTANT IS NOT THE `case` RULE, AND THAT IS THE MEASUREMENT'S CONTENT
# RATHER THAN A GAP IN IT. Every identifier in every committed capture is already
# lowercase, so no mutation of the case rule can move a byte: measured, a mutant
# of `identifierKeyForm` moves NOTHING at all, while the `stripPrefix` mutant
# above moves 6,157 manifest lines and stops the demo producer dead. This diff is
# live for the payload composition and SILENT ABOUT CASE BY CONSTRUCTION, which is
# why the evidence for per-encoding case handling is
# `tests/tidentifierencoding.nim` plus two compile-time refusals and not this.
#
# A DIFFERING LINE IS NOT AN OBJECT. An object whose PATH moved contributes two
# lines (the old path leaves, the new one arrives) and an object whose BYTES moved
# contributes two as well; only a tree the mutant could not publish at all
# contributes one per object. So the mutant's 6,157 lines over 11,043 objects are
# roughly 2,900 moved objects plus the 309 of a demo tree that refused. The line
# count is what is reported because it is what `diff` can be held to without the
# recipe interpreting it.
#
# IT DOES NOT COVER §5's GLOBAL HASH INDEX, AND THE RUN SAYS SO ON EVERY RUN.
# The set this zero is a zero over is "what the two PRODUCERS write". The global
# index is written by `buildGlobalHashIndex` in `client/src/static_export.nim`
# during the SITE EXPORT, which this recipe does not run — so the headline
# artifact of the per-shape widening sits outside its own zero. Measured at
# a145e68 and re-measured unchanged against the merged `dev` 4db3414: 51 of
# 11,043 objects are index objects, ALL under `idx/hash/1/` and ALL in the demo
# tree, 0 in format 2, and there is NO `idx/hash/meta.json` in any tree. The recipe now prints that census as a SCOPE block before its verdict
# rather than leaving it to a reader to discover, because a note goes stale and a
# count taken on the run does not. Closing the gap needs the exporter built and
# run on both sides, which roughly doubles a recipe that is already two release
# builds; it is an open operator question rather than a silent omission.
#
# It never contacts a chain. Both producers read committed captures off disk; the
# live follower is neither built nor run, and running it would write into
# `client/fixtures/chain/` — which is the thing being compared.
#
# Heavy: two full release builds of both producers plus twelve publishes. The
# work directory defaults to `/build/byte-identity`; override with
# `BYTE_IDENTITY_WORK` or `--work`.
byte-identity REF:
    tools/chain/byte-identity.sh --ref {{REF}}

byte-identity-mutant REF:
    tools/chain/byte-identity.sh --ref {{REF}} --mutant
