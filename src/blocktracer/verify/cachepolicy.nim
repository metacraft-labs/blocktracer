## verify/cachepolicy.nim — the object-class cache contract, read as data.
##
## `Static-Site-Architecture.md` §2.9 is the normative object-class registry and
## `Publishing-And-Caching.md` §4 says of its own table that it is GENERATED
## from §2.9 and stale wherever the two disagree. Neither of those is in this
## repository, so a program that checks a live instance against them has to hold
## a transcription — and the only honest transcription is one with a source that
## can be re-derived. `tools/verify/cache-policy.json` is that file: it carries
## the specs commit and the sha256 of each section's exact text, and
## `tools/verify/cache-policy-drift.mjs` recomputes both against a checkout.
##
## This module does three things and no more: read the file, match a key to a
## row, and say whether a served `Cache-Control` satisfies that row.
##
## ## The header string is not the contract; the DIRECTIVES are
##
## `public, max-age=0, s-maxage=5, stale-while-revalidate=60` and
## `max-age=0, s-maxage=5, stale-while-revalidate=60, public` state the same
## policy, and a CDN may add `public` on its own. So a row states which
## directives must be PRESENT with which values, and which must be ABSENT —
## which is what distinguishes `no-store` on a `/t/` 404 from a `no-store` that
## arrived beside a `max-age` nobody meant.
##
## ## Order is data, and getting it wrong fails quietly
##
## Rows are tried in order and the first hit wins, so `d/*/current.json` must
## precede `d/**`. A mis-ordered registry does not error — it applies the
## general rule to the specific object, which for `current.json` means asserting
## a year of immutability on the one hot mutable object per chain. The file
## carries an `orderSanity` list of (key, expected row) pairs and
## `tests/tverifypublished.nim` drives every one, so the order is pinned by
## assertions rather than by the order it happens to be written in.

import std/[json, strutils, tables]

const cachePolicyJson = staticRead("../../../tools/verify/cache-policy.json")

const CachePolicyFormat* = "blocktracer/cache-policy@1"
  ## The format token this module knows. Named rather than inlined so a
  ## selftest can read it out of this source and check the data file agrees.

type
  Directive* = object
    name*: string
    value*: string
    hasValue*: bool

  PolicyRow* = object
    id*: string
    match*: string
    why*: string
    expect*: seq[Directive]
    forbid*: seq[string]
    windowed*: seq[Directive]      ## the `t/**` alternative; empty when none

  CachePolicy* = object
    rows*: seq[PolicyRow]
    absent*: seq[PolicyRow]
    orderSanity*: seq[tuple[key, rowId: string]]
    sourceCommit*: string

  PolicyVerdict* = object
    rowId*: string
    problems*: seq[string]

func matchesPattern*(pattern, key: string): bool =
  ## The tiny pattern language the data file documents: `*` is one segment,
  ## `**` is the remainder and may only appear last, everything else literal.
  ## A leading `**` (as in `**.html`) is written as a suffix match, which is the
  ## one shape §2.9's entry-page row needs.
  if pattern == "**": return true
  if pattern.startsWith("**"):
    return key.endsWith(pattern[2 .. ^1])
  let ps = pattern.split('/')
  let ks = key.split('/')
  var i = 0
  while i < ps.len:
    if ps[i] == "**":
      return i <= ks.len           # matches the remainder, empty included
    if i >= ks.len: return false
    if ps[i] != "*" and ps[i] != ks[i]: return false
    inc i
  i == ks.len

proc parseDirectives(n: JsonNode): seq[Directive] =
  if n == nil or n.kind != JObject: return
  for k, v in n.pairs:
    case v.kind
    of JInt: result.add Directive(name: k, value: $v.getInt, hasValue: true)
    of JBool: result.add Directive(name: k, hasValue: false)
    of JString: result.add Directive(name: k, value: v.getStr, hasValue: true)
    else: discard

proc parseRow(n: JsonNode): PolicyRow =
  result.id = n{"id"}.getStr
  result.match = n{"match"}.getStr
  result.why = n{"why"}.getStr
  result.expect = parseDirectives(n{"expect"})
  let f = n{"forbid"}
  if f != nil and f.kind == JArray:
    for x in f: result.forbid.add x.getStr
  result.windowed = parseDirectives(n{"windowedException"})

proc loadCachePolicy*(): CachePolicy =
  let j = parseJson(cachePolicyJson)
  if j{"format"}.getStr != CachePolicyFormat:
    raise newException(ValueError,
      "tools/verify/cache-policy.json declares format '" & j{"format"}.getStr &
      "' and this build reads '" & CachePolicyFormat & "'")
  result.sourceCommit = j{"source"}{"commit"}.getStr
  for r in j{"rows"}: result.rows.add parseRow(r)
  for r in j{"absent"}: result.absent.add parseRow(r)
  let os = j{"orderSanity"}
  if os != nil and os.kind == JArray:
    for pair in os:
      if pair.kind == JArray and pair.len == 2:
        result.orderSanity.add (pair[0].getStr, pair[1].getStr)

func parseCacheControl*(header: string): Table[string, string] =
  ## Lower-cased directive → value ("" for a bare directive).
  result = initTable[string, string]()
  for part in header.split(','):
    let p = part.strip()
    if p.len == 0: continue
    let eq = p.find('=')
    if eq < 0: result[p.toLowerAscii] = ""
    else: result[p[0 ..< eq].strip().toLowerAscii] = p[eq + 1 .. ^1].strip().strip(chars = {'"'})

proc satisfies(want: seq[Directive], got: Table[string, string]): seq[string] =
  for d in want:
    if not got.hasKey(d.name):
      result.add "`" & d.name & "` is missing" &
        (if d.hasValue: " (expected " & d.name & "=" & d.value & ")" else: "")
    elif d.hasValue and got[d.name] != d.value:
      result.add "`" & d.name & "` is " & got[d.name] & " and must be " & d.value

proc rowFor*(p: CachePolicy, key: string, absent: bool): PolicyRow =
  let rows = if absent: p.absent else: p.rows
  for r in rows:
    if matchesPattern(r.match, key): return r
  PolicyRow()

proc check*(p: CachePolicy, key: string, absent: bool, header: string): PolicyVerdict =
  let row = p.rowFor(key, absent)
  if row.id.len == 0: return PolicyVerdict()
  result.rowId = row.id
  let got = parseCacheControl(header)
  var problems = satisfies(row.expect, got)
  if problems.len > 0 and row.windowed.len > 0:
    # `/t/**` carries two legitimate policies and §4 says which one applies is
    # SET BY THE OBJECT, not by the path — so a windowed container satisfying
    # the windowed row is not a violation of the permanent one.
    let alt = satisfies(row.windowed, got)
    if alt.len == 0:
      problems = @[]
      result.rowId = row.id & " (windowed)"
  for f in row.forbid:
    if got.hasKey(f):
      problems.add "`" & f & "` is present and this class forbids it"
  result.problems = problems
