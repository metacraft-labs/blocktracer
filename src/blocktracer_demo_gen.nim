## `blocktracer-demo-gen` — emit the demo static-site tree (M5c).
##
## Usage:
##   blocktracer-demo-gen [--out DIR] [--seed SEED] [--trace-fixture PATH]
##
## Deterministic: the same seed produces a byte-identical tree, so the output is a
## usable regression fixture.

import std/[os, parseopt, strutils]
import blocktracer/demo/generator

proc main() =
  var
    outDir = "demo-site"
    seed = "blocktracer-demo-0"
    fixture = "fixtures/trace/minimal_trace.ct"
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "out", "o": outDir = val
      of "seed", "s": seed = val
      of "trace-fixture", "f": fixture = val
      of "help", "h":
        echo "blocktracer-demo-gen [--out DIR] [--seed SEED] [--trace-fixture PATH]"
        return
      else: discard
    else: discard

  if not fileExists(fixture):
    stderr.writeLine "trace fixture not found: " & fixture
    quit 2

  let cfg = DemoConfig(outDir: outDir, seed: seed, traceFixturePath: fixture)
  let n = generate(cfg)
  echo "Wrote demo tree to " & outDir & " (" & $n & " transactions)."
  echo "NOTE: trace.ct containers are copied from the stand-in fixture " & fixture
  echo "      (nargo was unavailable to record a real noir_space_ship .ct)."

main()
