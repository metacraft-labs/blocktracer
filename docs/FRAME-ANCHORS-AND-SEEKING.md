# Frame anchors, and what they must carry for a seek to be cheap

> **Status:** design, not built.
> **Written:** 2026-10-26, after `a-link-to-a-frame-arrives-at-that-frame` went
> red at 0 of 6 and the cause turned out to be the anchor's shape rather than
> its derivation.

## 0. The defect this is about

A §6.0a deep link names a frame. The served page resolves it correctly — every
pre-engine assertion in that journey passes. Hydration then moves off it.

Measured on `/aztec-testnet-frames/tx/0x0a807e…/debug`:

| | rows | carrying `call:` anchors |
| --- | --- | --- |
| served (JavaScript off) | 83 | 47 |
| hydrated | 34 | 18 |

The 18 are a contiguous PREFIX of the 47 and match exactly where both lists
have them, so anchor IDENTITY was never wrong. The lookup DOMAIN was: the live
Call Trace is viewport-windowed, and `selectCalltraceFrame` resolves against
the window.

**Widening the lookup does not fix it, and that was tried.** Probing
`store.calltrace.lines` instead of `visibleLines` makes the anchor resolve and
leaves the selection off-screen, so the pane marks nothing — §7.0 went from 6
of 6 to 0 of 6. Adding a `setViewport` scroll restored the mark and still left
the identity claim at 0, because `store.calltrace.lines` is ITSELF the fetched
window: measured on a deep link to `call:0.0.0.3.7.0`, the hydrated pane held
18 anchors, first `call:0`, last `call:0.0.0.3.3`, and the target was not
present. There is no full frame list client-side to resolve against.

## 1. Why the current anchor cannot be resolved cheaply

`withCallAnchors` derives `call:0.0.0.3.7.0` from the DEPTH SEQUENCE of the
rows. That has two consequences, and both are structural:

* **It needs the whole list from the root.** A path is a position in a tree,
  so a window that does not start at row 0 produces wrong path STRINGS even
  for frames it does hold.
* **It is not a coordinate.** Nothing in the string says where the record is,
  so resolving it is a walk, never a jump.

The identity property is worth keeping — `Click-Navigation.md` §4 requires
"a frame identity written by the static exporter and one resolved from a live
session are the same string", and `withCallAnchors` is what guarantees it. The
problem is that identity is all it carries.

## 2. What a seek actually costs

`ctfs-container.md` §7. A chunked stream `calls.dat` has a companion
`calls.idx`:

```
calls.idx:  [chunk_size: u32][offset_0: u64][offset_1: u64]...
```

Seeking to record `N` is:

1. `chunk = N / chunk_size`
2. read `calls.idx[4 + chunk*8]`      — the chunk's byte offset
3. read `calls.idx[4 + (chunk+1)*8]`  — the next one
4. decompress `calls.dat[offset .. next]`
5. take record `N % chunk_size`

**Two u64 reads and one chunk decompress — O(1).** The spec's own properties
table says the same: "O(log n) block mapping (at most 5 reads); O(1) chunk
seek via companion index."

What it needs is `N`. Nothing else. So an anchor that carries `N` can be
resolved by a seek; an anchor that carries only a path cannot.

## 3. The compact profile has no such structures, by design

§1e's compact profile is for a container that is RESIDENT before its first
query — the threshold is measured in RAW bytes "because residency is a
property of logical size". §1f stores every member inflated: "the full
container's members under the same names with every zstd frame replaced by its
content."

A companion index maps records to byte offsets of COMPRESSED chunks. Inflating
the member invalidates every one of those offsets, which is why
`compact_container` refuses a seekable-zstd `events.log` rather than copying
its frames — doing so "would break §1e's raw-member property".

So a compact container cannot seek, and does not need to: it is small enough
to hold whole. That is the bargain §1e makes.

## 4. The proposal

Carry both. The path stays the identity; an index is added as a seek hint.

```
call:0.0.0.3.7.0@12345
└── path, as today ──┘ └ record index in calls.dat
```

**Resolution:**

1. **Full profile, hint present.** Seek to record `N` (§2). Read it,
   recompute its path, and compare with the anchor's path.
   * equal → resolved, at two u64 reads and one chunk.
   * not equal → fall to 2.
2. **Compact profile, or no hint, or the hint did not verify.** Load the
   container and resolve the PATH against the entire trace. For a compact
   container this is what §1e already assumes; the cost is bounded by the
   residency threshold rather than by the recording's length.

**The hint is verified, never trusted.** An index is a position in one
recording; a path is identity across recordings. A container re-recorded at
the same URL keeps every path valid and invalidates every index, and an
unverified hint would then land silently on the WRONG frame — which is worse
than landing slowly on the right one. The recompute-and-compare in step 1
costs one record read and makes the hint unable to lie.

**Old anchors keep working.** An anchor with no `@N` is exactly today's
anchor and takes path 2. The index is additive, so links already shared
resolve as they do now.

## 5. Where the change lands

* `withCallAnchors` — the one function both producers derive from. Emitting
  the index here is what keeps the static exporter's anchors and the live
  session's identical, which is the property §4 of `Click-Navigation.md`
  asks for and the reason this is not done in two places.
* The resolvers — `session_project.selectCalltraceFrame` and
  `hydrate.markServedFrame` — gain step 1 and keep step 2 as what they do now.
* Nothing in the viewport needs to change. With a verified hint the resolver
  does not consult the rendered rows at all, so windowing stops being
  load-bearing for deep links.

## 6. What this does not settle

* **Where `N` comes from on the static side.** The exporter writes rows from
  its own read of the container; whether it already knows each call's record
  index, or must be taught to carry it, is unmeasured.
* **Whether one index is enough.** A frame is a record in `calls.dat`; a
  landing also wants a step coordinate. §6.0a already carries `?t=`
  separately, so this is probably not the anchor's job — but it is not
  checked.
* **The 18-of-47 symptom has a second cause.** Even with a hint, a pane that
  renders only its viewport must SCROLL to show the selected row. That is
  `setViewport` with a new `firstRow`, which is already the supported path
  (`calltrace_vm.setViewport` → `scrollPosition`), and is independent of how
  the anchor resolved.
