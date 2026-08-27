# BlockTracer workspace commands.
# `just` recipes wrap the nimble tasks so the workspace has one entry point.

# Run the conformance test suite.
test:
    nim c -r --hints:off tests/tcontract.nim

# Generate a demo static tree into ./demo-site.
demo-gen out="demo-site" seed="blocktracer-demo-0":
    nim c -r --hints:off src/blocktracer_demo_gen.nim --out:{{out}} --seed:{{seed}}

# Validate a static tree against the contract.
validate dir="demo-site":
    nim c -r --hints:off src/blocktracer_validate.nim {{dir}}

# Generate a demo tree and validate it (the M5c end-to-end check).
demo: (demo-gen) (validate)

# Build the CLI binaries.
build:
    nim c --hints:off -d:release -o:blocktracer-demo-gen src/blocktracer_demo_gen.nim
    nim c --hints:off -d:release -o:blocktracer-validate src/blocktracer_validate.nim
