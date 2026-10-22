## Test helper: read server-rendered markup without IsoNim's hydration keys.
##
## Shared by the suites that assert tag shapes on SSR output. It edits nothing
## but the keys, so a suite that compares served bytes (for example a page
## against the file the export wrote) must compare the raw documents instead.

import std/strutils

proc withoutHydrationKeys*(html: string): string =
  ## The document without IsoNim's hydration keys. The SSR codegen writes a
  ## `data-hk="N"` on every element it emits, numbered in render order, so a
  ## tag shape would otherwise read `<html data-hk="1" lang="en" …>`.
  ## The keys are the renderer's bookkeeping for re-attaching the client, not
  ## content or structure a suite asserts, and every other byte is left as
  ## served — a removed key leaves the attributes it sat between unchanged.
  const key = " data-hk=\""
  result = newStringOfCap(html.len)
  var i = 0
  while i < html.len:
    let at = html.find(key, i)
    if at < 0:
      result.add html[i .. ^1]
      break
    result.add html[i ..< at]
    let close = html.find('"', at + key.len)
    doAssert close >= 0, "unterminated data-hk attribute at " & $at
    i = close + 1
