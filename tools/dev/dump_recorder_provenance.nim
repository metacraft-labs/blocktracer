## Ingest a capture and print, per published container, the recorder it is filed
## under and the `/t/**` address that recorder derives.
##
## THIS EXISTS TO BE DIFFED AGAINST ITSELF ACROSS A CODE CHANGE. "The existing
## containers' ids are unchanged" is a claim about bytes, and the only way to
## show it is to produce the bytes on both sides of the change and compare them.
## Prose asserting it is exactly the evidence this campaign does not accept.
##
## Usage: dump_recorder_provenance <snapshotDir> <workDir>

import std/[json, os, algorithm, strutils, tables]
import blocktracer/chain/ingest

proc main =
  if paramCount() < 2:
    quit "usage: dump_recorder_provenance <snapshotDir> <workDir>"
  let snapshotDir = paramStr(1)
  let workDir = paramStr(2)
  createDir workDir
  let ing = ingestSnapshot(IngestConfig(outDir: workDir,
                                        snapshotDir: snapshotDir,
                                        scope: isFull))

  # The registry row, which is where the chain's default pin and its inventory
  # of recorders live.
  let regPath = workDir / "registry" / "chains.v1.json"
  let reg = parseJson(readFile(regPath))
  let row = reg["chains"][ing.chain]
  echo "chain              ", ing.chain
  echo "registry.recorder  ", row["recorder"]["build"].getStr, "  ",
       row["recorder"]{"version"}.getStr
  if row.hasKey("recorders"):
    for r in row["recorders"]:
      echo "registry.recorders ", r["build"].getStr, "  ",
           r{"version"}.getStr

  # Every published manifest, keyed by the transaction it is about, so the
  # comparison is per container rather than per directory-listing order.
  var rows: seq[string]
  for path in walkDirRec(workDir / "t"):
    if path.endsWith("manifest.json"):
      let m = parseJson(readFile(path))
      let tid = m["traceArtifactId"].getStr
      rows.add m["tx"].getStr & "  tid=" & tid &
               "  recorder=" & m["recorder"]["build"].getStr &
               "  version=" & m["recorder"]{"version"}.getStr &
               "  container=" & m["container"]["hash"].getStr

  # The overlay's view of the same containers — the field a CLIENT derives the
  # address from. Printed beside the manifest so a divergence between what the
  # tree says produced a container and what the tree tells a browser to derive
  # its address from cannot hide in either one alone.
  var overlayRecorder = initTable[string, string]()
  let tsRoot = workDir / "d" / ing.chain / "ts"
  if dirExists(tsRoot):
    for path in walkDirRec(tsRoot):
      if not path.endsWith(".json"): continue
      let o = parseJson(readFile(path))
      let tr = o{"trace"}
      if tr == nil: continue
      overlayRecorder[o["tx"].getStr] =
        if tr.hasKey("recorder"): tr["recorder"]["build"].getStr
        else: "(none: addressed by the chain pin)"

  sort(rows)
  echo "containers         ", rows.len
  for r in rows:
    let tx = r.split("  ")[0]
    echo r & "  overlayRecorder=" &
         (if tx in overlayRecorder: overlayRecorder[tx] else: "(no overlay row)")

main()
