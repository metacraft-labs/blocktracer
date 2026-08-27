# Package

version       = "0.0.1"
author        = "Metacraft Labs"
description    = "BlockTracer — static block explorer pipeline. M5b/M5c slice: the versioned data contract and the Demo Data Generator."
license        = "MIT"
srcDir         = "src"
installExt     = @["nim"]
bin            = @["blocktracer_demo_gen", "blocktracer_validate"]
namedBin["blocktracer_demo_gen"] = "blocktracer-demo-gen"
namedBin["blocktracer_validate"] = "blocktracer-validate"

# Requires

requires "nim >= 2.0.0"
# No third-party dependencies: the contract, validator and demo generator use the
# Nim standard library only, so `nimble build` and CI need no package resolution.

# Tasks

task test, "Run the conformance test suite":
  exec "nim c -r --hints:off tests/tcontract.nim"

task demo, "Generate a demo tree into ./demo-site and validate it":
  exec "nim c -r --hints:off src/blocktracer_demo_gen.nim --out:demo-site"
  exec "nim c -r --hints:off src/blocktracer_validate.nim demo-site"
