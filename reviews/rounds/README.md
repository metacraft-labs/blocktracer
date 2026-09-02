# Review rounds — the reports the ledger was built from

`reviews/ledger.json` holds the CURRENT round: one entry per reviewer per
image, and `gate.mjs` decides over it. This directory holds the reports those
entries were ingested from, verbatim, so the ledger's contents can be traced
back to what a reviewer actually wrote rather than taken on trust.

Each file is one reviewer's report for one image: a prose summary followed by
the ```json block the review brief's §10 Part 2 defines. They are the INPUT to
`tools/capture/ingest-review.mjs`, which is the only thing that writes reviews
into the ledger:

    just review-ingest "--dir reviews/rounds/<round> --gate-scope <view>/<size>/<theme>"

Nothing here is edited by hand after the fact. A ledger entry that no report
in this tree accounts for is a defect, not a shortcut — the ledger is the
evidence the gate decides over, and VD.1's reviewer defeated the determinism
gate by hand-writing precisely that kind of entry.

## Rounds

VD.5 ran several rounds on the debugger register, each against a different
build. **The directories in this tree are the record — `ls reviews/rounds/`
rather than trusting a count in this sentence**, which said "three" while four
were described below and a fifth sat on disk undescribed.

- **Round 1** — six lenses on `debugger` at `wide`/`dark` and `laptop`/`light`,
  against the build the milestone unblocked on. Not in this tree: it predates
  the ingest path and was consumed as agent output rather than as files. Its
  result is the one that matters and is recorded in the milestone entry —
  `laptop`/`light` was reported **`expectedElements: missing` by six of six
  reviewers**, because the source pane rendered from line 1 and the session's
  position therefore fell below the fold at that viewport. `wide`/`dark`, where
  the same position is above the fold, reported `present` from all six. A
  presence failure visible at one viewport and not the other is exactly what
  VD.5 deliverable 1 reviews both viewports to catch.

- `vd5-round2/` — **12/12**, six lenses on each of the two images, against the
  build that fixed round 1. All twelve report `present`; zero P1. Complete lens
  coverage, but its captures predate round 3's scrubber change, so it is
  evidence of the fix landing rather than the gated round. `ingest-review.mjs`
  will now refuse to file these against the current captures, and should.

- `vd5-round3/` — **12/12**. All twelve report `present`; zero P1 across both
  images. Eleven were run in one session; `laptop`/`light`'s `ADV` reviewer was
  added afterwards, the session having reached its 200-subagent cap before it
  could run. Only eleven of the twelve ever reached the ledger.

  **Superseded.** The review round that followed made two further code changes
  — the scrubber's `int()` truncation, and two source comments inside the
  INLINED stylesheet — and both move the served bytes. Round 3's captures were
  therefore replaced, and its reports are reviews of an image that no longer
  exists. They are kept because they are evidence of what was seen, not
  deleted to tidy the record; they are simply not the gated round.

  This is the failure mode the round-4 work closed in the tooling. `gate.mjs`
  checked only that six reviewer NAMES were present, so it would have
  certified these five against the new capture without a word. It now
  re-verifies each review's recorded `imageSha256` against the file on disk,
  and it named all eleven of these as superseded the moment the recapture
  landed — which is how the supersession above was noticed rather than
  reasoned about.

- `vd5-round4/` — **12/12**, six lenses on each of the two images, against the
  build this milestone lands. Every report was written against the capture whose
  sha256 the ledger records, and `gate.mjs` re-checks that against the file
  rather than taking the ledger's word. It is no longer the only VD.5 round on
  disk — see below.

- `vd5-round5/` — **NOT DESCRIBED HERE, and that is the finding rather than an
  omission being filled in.** 26 reports plus a `notes/` directory: six lenses
  over `debugger` at all four size/theme combinations, and two over
  `debugger--call-trace`/`wide`/`dark`. Neither this string nor `vd5-round4`
  appears anywhere in `reviews/ledger.json`, so which round the ledger currently
  holds cannot be settled from this file. Whoever ran round 5 should write its
  entry here and say what it supersedes; until then, read the reports.

**No VD.5 round is the current one.** `reviews/ledger.json` names `vd8`,
`vd9-r1`, `vd9-r2`, `vd10-r1`, `vd10-r2`, `vd11-r1` and `vd11-r2` and no `vd5`
round at all, so everything above is history. The round `gate.mjs` decides over
is whatever the ledger says today — ask it, not this file.
