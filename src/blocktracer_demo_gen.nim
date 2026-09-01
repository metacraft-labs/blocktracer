## `blocktracer-demo-gen` — emit the demo static-site tree (M5c).
##
## Usage:
##   blocktracer-demo-gen [--out DIR] [--seed SEED] [--trace-fixture PATH]
##                        [--trace-sources DIR]
##
## Deterministic: the same seed produces a byte-identical tree, so the output is a
## usable regression fixture. That is why the trace container is a vendored file
## rather than a fresh `nargo trace` invocation — `nargo trace` stamps a new UUIDv7
## recording id into every container it writes, so regenerating would change the
## bytes on each run (fixtures/trace/noir_space_ship/README.md).

import std/[os, parseopt, strutils]
import blocktracer/demo/generator

proc main() =
  var
    outDir = "demo-site"
    seed = "blocktracer-demo-0"
    fixture = "fixtures/trace/noir_space_ship/zk_shields.ct"
    sources = "fixtures/trace/noir_space_ship/sources"
    tourDir = "fixtures/trace/tour"
  proc needValue(opt, val: string) =
    if val.len == 0:
      stderr.writeLine "--" & opt & " needs a value; use --" & opt & ":VALUE"
      quit 2

  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      # `parseopt` only fills `val` for the `--opt:VALUE` / `--opt=VALUE` forms.
      # `--out DIR` leaves it empty, and an empty out-dir used to mean "write the
      # whole tree into the current directory" — which silently scatters `d/`,
      # `t/`, `idx/` and a `src/aztec/` over the source checkout. Refuse instead.
      of "out", "o": needValue("out", val); outDir = val
      of "seed", "s": needValue("seed", val); seed = val
      of "trace-fixture", "f": needValue("trace-fixture", val); fixture = val
      of "trace-sources": needValue("trace-sources", val); sources = val
      of "tour-dir": needValue("tour-dir", val); tourDir = val
      of "no-tour": tourDir = ""
      of "help", "h":
        echo "blocktracer-demo-gen [--out DIR] [--seed SEED] " &
             "[--trace-fixture PATH] [--trace-sources DIR] " &
             "[--tour-dir DIR | --no-tour]"
        return
      else: discard
    else: discard

  if not fileExists(fixture):
    stderr.writeLine "trace fixture not found: " & fixture
    quit 2
  if not dirExists(sources):
    # Without sources the tree still validates, but every step in the debugger
    # resolves to a file the viewer cannot display — refuse rather than ship that.
    stderr.writeLine "trace sources not found: " & sources
    quit 2

  if tourDir.len > 0 and not fileExists(tourDir / "manifest.json"):
    stderr.writeLine "tour manifest not found: " & (tourDir / "manifest.json") &
                     " (pass --no-tour to generate the tree without it)"
    quit 2

  let cfg = DemoConfig(outDir: outDir, seed: seed, traceFixturePath: fixture,
                       traceSourcesDir: sources, tourDir: tourDir)
  let n = generate(cfg)
  echo "Wrote demo tree to " & outDir & " (" & $n & " transactions)."
  echo "Traces: real CTFS containers recorded by `nargo trace` (Noir tracer fork" &
       " @ 906af2f42d)."
  echo "        M5c tree: " & fixture & " (1315 steps, 80 calls), one container" &
       " behind six executions."
  if tourDir.len > 0:
    echo "        capability tour: " & $readTour(tourDir).len & " programs from " &
         tourDir & ", each with its OWN container and sources."
  else:
    echo "        capability tour: not published (--no-tour)."

main()
