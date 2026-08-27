## `blocktracer-publish` — the resumable, incremental delta publisher (M8).
##
## Reconciles a generated tree (one generation from the demo generator, or the real
## pipeline's processing output) against an object-store backend: uploads only the
## additions, in dependency order, then atomically flips `current.json`. Idempotent
## and resumable — a re-run uploads zero content objects, and a killed run resumes
## from the published `current.json` with no gap or double-upload.
##
## Usage:
##   blocktracer-publish --tree DIR --backend local --dest DIR [--chain C] [--writer ID]
##   blocktracer-publish --tree DIR --backend s3 --bucket NAME [--endpoint URL]
##                        [--prefix P] [--chain C] [--writer ID]
##
## Flags:
##   --tree DIR       the generated tree to publish (required)
##   --backend        local | s3          (default: local)
##   --dest DIR       local backend: the store directory (required for local)
##   --bucket NAME    s3/r2 backend: bucket name (required for s3)
##   --endpoint URL   s3/r2 backend: R2 endpoint (https://<acct>.r2.cloudflarestorage.com)
##   --prefix P       s3/r2 backend: key prefix inside the bucket
##   --chain C        publish only chain C (default: every chain under DIR/d)
##   --writer ID      lease owner id (default: publisher-<pid>)
##   --no-lease       skip the per-chain single-writer lease (local preview only)
##   --halt-before-pointer   stop after content, before the visibility flip (drill)

import std/[os, parseopt]
import blocktracer/publish/objectstore
import blocktracer/publish/publisher

proc usage() =
  stderr.writeLine """usage:
  blocktracer-publish --tree DIR --backend local --dest DIR [--chain C] [--writer ID]
  blocktracer-publish --tree DIR --backend s3 --bucket NAME [--endpoint URL] [--prefix P]"""

proc main() =
  var
    tree = ""
    backend = "local"
    dest = ""
    bucket = ""
    endpoint = ""
    prefix = ""
    opts = defaultOptions()
  # Accept both `--flag value` (space) and `--flag:value` / `--flag=value` (colon).
  var pending = ""
  proc assign(k, v: string) =
    case k
    of "tree", "t": tree = v
    of "backend", "b": backend = v
    of "dest", "d": dest = v
    of "bucket": bucket = v
    of "endpoint": endpoint = v
    of "prefix": prefix = v
    of "chain", "c": opts.chain = v
    of "writer", "w": opts.writer = v
    else: discard
  const valueFlags = ["tree", "t", "backend", "b", "dest", "d", "bucket",
                      "endpoint", "prefix", "chain", "c", "writer", "w"]
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "no-lease": opts.takeLease = false
      of "halt-before-pointer": opts.haltBeforePointer = true
      of "help", "h": usage(); return
      else:
        if key in valueFlags:
          if val.len > 0: assign(key, val)      # colon/equals form
          else: pending = key                   # space form: value is next token
        # unknown flag: ignore
    of cmdArgument:
      if pending.len > 0: assign(pending, key); pending = ""
    else: discard

  if tree.len == 0 or not dirExists(tree):
    stderr.writeLine "error: --tree must be an existing directory"
    usage(); quit 2

  var store: ObjectStore
  case backend
  of "local":
    if dest.len == 0:
      stderr.writeLine "error: local backend needs --dest DIR"; quit 2
    store = newLocalObjectStore(dest)
  of "s3", "r2":
    if bucket.len == 0:
      stderr.writeLine "error: s3 backend needs --bucket NAME"; quit 2
    store = newS3ObjectStore(bucket, prefix = prefix, endpoint = endpoint)
  else:
    stderr.writeLine "error: unknown --backend '" & backend & "'"; quit 2

  var incidents = 0
  try:
    let results = publishTree(store, tree, opts)
    for r in results:
      echo "chain ", r.chain, ":"
      let from0 = if r.resumedFrom.present: r.resumedFrom.generation else: "(none)"
      echo "  resumed-from generation : ", from0
      echo "  published generation    : ",
        (if r.publishedGeneration.len > 0: r.publishedGeneration else: "(unchanged)")
      echo "  content uploaded        : ", r.contentUploaded.len
      echo "  content skipped         : ", r.contentSkipped.len
      echo "  pointers written        : ", r.pointersWritten.len
      echo "  pointer flipped         : ", r.pointerFlipped
      if r.haltedBeforePointer:
        echo "  HALTED before pointer flip (content is in place, not yet visible)"
      if r.determinismIncidents.len > 0:
        incidents += r.determinismIncidents.len
        echo "  DETERMINISM INCIDENTS   : ", r.determinismIncidents.len
        for k in r.determinismIncidents: echo "    ! ", k
  except PublishError as e:
    stderr.writeLine "publish failed: " & e.msg
    quit 1

  if incidents > 0:
    stderr.writeLine "publish completed WITH " & $incidents &
      " determinism incident(s) — see above; those objects were NOT overwritten"
    quit 3

main()
