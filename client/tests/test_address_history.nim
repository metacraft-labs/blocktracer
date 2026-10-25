## tests/test_address_history.nim — an address's chain history below the window.
##
## Recorder-Solana spine need (f): a producer may carry the chain's own history
## for an address below the captured window (§5.2 `addressHistory`), and the
## ingest publishes it as the address's OLDEST segment, with no `transactions`
## and the entries as `untraced`. This file grades what the address page makes
## of that segment:
##
##   * the entries are listed, in full, and NONE is a link — no container for
##     them exists in the tree, so a link would open a page it does not hold;
##   * the page does not call that segment "complete history", and says older
##     history was not fetched unless the segment says it is complete;
##   * the window's own segment renders exactly as it did, and `older` from it
##     reaches the history segment.
##
## Served from an in-memory store, the pattern `test_explorer_breadth.nim`'s
## `bigHistoryStore` uses, so the segment shapes are the ones ingest writes.

import std/[unittest, strutils]

import ../src/ssr
import ../src/reader

const
  Chain = "hist"
  Addr = "0x" & "ab".repeat(20)
  WindowTx = "0x" & "11".repeat(32)
  OldA = "0x" & "91".repeat(32)
  OldB = "0x" & "92".repeat(32)

proc historyStore(complete: bool): ObjectStore =
  let shard = Addr[2 .. 5]
  let segDir = "d/" & Chain & "/seg/" & shard & "/" & Addr & "/"
  newObjectStore("addr-history", proc(path: string): ObjectResponse =
    proc found(body: string): ObjectResponse = ObjectResponse(found: true, body: body)
    if path == "registry/chains.v1.json":
      return found("""{"version":1,"chains":{"""" & Chain &
        """":{"recorder":{"id":"r","build":"b","version":"0"},""" &
        """"profile":{"name":"default","hash":"p"},"traceSchema":"ctfs/v4"}}}""")
    if path == "d/" & Chain & "/current.json":
      return found("""{"chain":"""" & Chain & """","generation":"1",""" &
        """"traceSelectionVersion":"1","head":{"height":100,"hash":"0xhead"},""" &
        """"finalized":{"height":100,"hash":"0xhead"}}""")
    if path == "d/" & Chain & "/g/1/root.json":
      return found("""{"contractVersion":1,"chain":"""" & Chain &
        """","generation":"1","traceSelectionVersion":"1","maps":{""" &
        """"summary":"d/""" & Chain & """/g/1/summary.json","height":[],""" &
        """"blocks":[],"addr":["d/""" & Chain & """/g/1/addr/""" & shard &
        """/""" & Addr & """.json"],"txstate":[]}}""")
    if path == "d/" & Chain & "/g/1/summary.json":
      return found("""{"chain":"""" & Chain & """","generation":"1",""" &
        """"counters":{"blocks":1,"transactions":1},"coverageMode":"selective","stale":false}""")
    if path == "d/" & Chain & "/g/1/addr/" & shard & "/" & Addr & ".json":
      return found("""{"chain":"""" & Chain & """","address":"""" & Addr &
        """","segments":["""" & segDir & """100-100.json","""" & segDir &
        """97-98.json"]}""")
    if path == segDir & "100-100.json":
      return found("""{"chain":"""" & Chain & """","address":"""" & Addr &
        """","fromBlock":100,"toBlock":100,"transactions":["""" & WindowTx & """"]}""")
    if path == segDir & "97-98.json":
      return found("""{"chain":"""" & Chain & """","address":"""" & Addr &
        """","fromBlock":97,"toBlock":98,"transactions":[],"untraced":[""" &
        """{"txHash":"""" & OldA & """","blockNumber":98,"timestamp":1700000000,"failed":false},""" &
        """{"txHash":"""" & OldB & """","blockNumber":97,"timestamp":null,"failed":true}],""" &
        """"complete":""" & $complete & ""","limit":2}""")
    ObjectResponse(found: false))

var asserted = 0
template ck(c: untyped) =
  inc asserted
  check c

suite "an address's chain history below the window":
  let root = newDataRoot("", historyStore(complete = false))
  let info = chainInfo(root, Chain)

  test "the reader parses the untraced segment, and leaves the window's alone":
    let listed = addressSegmentPaths(root, info, Addr)
    ck listed.paths.len == 2
    let win = readAddressSegment(info, listed.paths[0])
    ck win.untraced.len == 0 and win.transactions == @[WindowTx]
    let old = readAddressSegment(info, listed.paths[1])
    ck old.transactions.len == 0
    ck old.untraced.len == 2
    ck old.untraced[0].txHash == OldA and old.untraced[0].timestamp == 1700000000
    ck old.untraced[1].failed and old.untraced[1].timestamp == 0
    ck not old.complete and old.limit == 2

  test "the history page lists every entry in full and links none of them":
    let body = renderAddress(root, Chain, Addr, "97-98")
    ck "Earlier transactions" in body
    ck OldA in body and OldB in body
    ck ("/tx/" & OldA) notin body and ("/tx/" & OldB) notin body
    ck "2023-11-14 22:13:20" in body
    ck "Older history was not fetched" in body
    ck "Complete history" notin body

  test "a complete history does not say older history exists":
    let r2 = newDataRoot("", historyStore(complete = true))
    let body = renderAddress(r2, Chain, Addr, "97-98")
    ck "Earlier transactions" in body
    ck "Older history was not fetched" notin body

  test "the window's segment is unchanged and steps older to the history":
    let body = renderAddress(root, Chain, Addr, "")
    ck "Earlier transactions" notin body
    ck "Complete history" in body
    ck "/seg/97-98" in body

  test "assertion count":
    check asserted == 7 + 6 + 2 + 3
