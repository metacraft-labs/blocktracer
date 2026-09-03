## contract/shards.nim — path sharding
## (Static-Site-Architecture.md §2, Trace-Artifacts.md §3).
##
## Split out of `ids.nim` rather than copied. `ids.nim` derives opaque content
## ids and therefore imports `std/sha1`, which reaches `std/endians` and does
## not compile on the JS backend at all. Sharding needs none of that — it is
## string slicing — and the browser needs it, because `client/searchboot/`
## computes `/d/{chain}/tx/{shard}/{hash}.json` in a tab.
##
## The rule `paths.nim` states about itself applies with more force here: "a
## second `hexShard` would be a second place for the layout to drift". The
## producer, the validator and now the browser resolve one definition, and
## `ids.nim` re-exports these so no existing importer has to know the split
## happened.

import std/strutils

func hexShard*(hashHex: string): string =
  ## `{h0h1}` / `{a0a1}` shard: first two bytes (4 hex chars) of a 0x-prefixed
  ## hash or address.
  var h = hashHex
  if h.startsWith("0x"): h = h[2 .. ^1]
  if h.len < 4: h = h & repeat('0', 4 - h.len)
  h[0 .. 3]

func traceShards*(tid: string): tuple[a, b: string] =
  ## `/t/{tid[0:2]}/{tid[2:4]}/{tid}/` — Trace-Artifacts.md §3.
  (tid[0 .. 1], tid[2 .. 3])
