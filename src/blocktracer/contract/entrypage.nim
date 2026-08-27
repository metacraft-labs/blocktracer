## The pre-rendered entry-page contract: the small, shared conventions a conformant
## HTML entry page must follow (Static-Site-Architecture.md §2, §4; Rendering-And-
## Delivery.md §4.2). Kept in `contract/` — not in the demo — so the conformance
## validator depends on it without depending on any producer, exactly as it reads raw
## JSON rather than the demo's types.
##
## What is contractual here is narrow and precise: a page carries its entity data in a
## `<script type="application/json" id="bt-data">` island, with `<`, `>`, `&` escaped
## so a token containing `</script>` cannot break out of the tag (§4.2). This module
## is the one place that escaping (producer side) and its inverse plus extraction
## (validator side) are defined.

import std/strutils

const
  siteBase* = "https://blocktracer.org"
    ## Canonical origin used in `<link rel="canonical">` (§4.2 example).
  dataScriptId* = "bt-data"
    ## The id of the inlined-data island (§4.2).
  dataScriptOpen* = "<script type=\"application/json\" id=\"" & dataScriptId & "\">"
  dataScriptClose* = "</script>"

proc escapeInline*(s: string): string =
  ## Escape the three characters that could break out of the inline JSON island
  ## (§4.2; Front-End-Architecture.md §9.4). JSON encoding alone does not prevent a
  ## `</script>` inside a string from closing the tag, so escape `<`, `>`, `&`.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '<': result.add "\\u003c"
    of '>': result.add "\\u003e"
    of '&': result.add "\\u0026"
    else: result.add c

proc unescapeInline*(s: string): string =
  ## Reverse of `escapeInline`, so a reader recovers the exact JSON bytes.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if i + 6 <= s.len and s[i] == '\\' and s[i+1] == 'u' and s[i+2] == '0' and
       s[i+3] == '0':
      let tail = s[i+4 .. i+5]
      case tail.toLowerAscii
      of "3c": result.add '<'; i += 6; continue
      of "3e": result.add '>'; i += 6; continue
      of "26": result.add '&'; i += 6; continue
      else: discard
    result.add s[i]
    inc i

proc extractInlineData*(html: string): tuple[json: string, found: bool] =
  ## Pull the `#bt-data` payload out of an entry page and unescape it back to raw
  ## JSON. The validator parses the result and cross-checks it against the data plane.
  let a = html.find(dataScriptOpen)
  if a < 0: return ("", false)
  let start = a + dataScriptOpen.len
  let b = html.find(dataScriptClose, start)
  if b < 0: return ("", false)
  (unescapeInline(html[start ..< b]), true)
