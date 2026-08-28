# Package

version       = "0.0.1"
author        = "Metacraft Labs"
description    = "BlockTracer — static block explorer. M5b/M5c: the versioned data contract + Demo Data Generator; M8: the resumable, incremental delta publisher; M12a: @blocktracer/client, the chain-aware Client SDK over the published tree."
license        = "MIT"
srcDir         = "src"
installExt     = @["nim"]
bin            = @["blocktracer_demo_gen", "blocktracer_validate", "blocktracer_publish"]
namedBin["blocktracer_demo_gen"] = "blocktracer-demo-gen"
namedBin["blocktracer_validate"] = "blocktracer-validate"
namedBin["blocktracer_publish"] = "blocktracer-publish"

# Requires

requires "nim >= 2.0.0"
# No third-party dependencies: the contract, validator and demo generator use the
# Nim standard library only, so `nimble build` and CI need no package resolution.

# Tasks

task test, "Run the conformance + publisher + Client SDK test suites":
  exec "nim c -r --hints:off tests/tcontract.nim"
  exec "nim c -r --hints:off tests/tpublish.nim"
  # M12a: the consumer-side conformance suite for @blocktracer/client. It needs
  # no debugger on the Nim path — the handoff to the CodeTracer Embed SDK is a
  # separate suite (tests/tembedhandoff.nim, `just sdk-test-embed`), because the
  # chain half compiling without one IS the layering.
  exec "nim c -r --hints:off tests/tclientsdk.nim"

task demo, "Generate a demo tree into ./demo-site and validate it":
  exec "nim c -r --hints:off src/blocktracer_demo_gen.nim --out:demo-site"
  exec "nim c -r --hints:off src/blocktracer_validate.nim demo-site"
