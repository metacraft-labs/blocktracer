# The demo session fixture

The `zk_shields` Noir program (workdir `noir_space_ship`) as the debug route's
**session fixture**: the source the editor pane renders, and the symbol table
its call trace is keyed against.

## What these bytes are

`src/main.nr` and `src/shield.nr` are copied verbatim from the trace CodeTracer
recorded at
`~/.local/share/codetracer/01a04973-d25d-78fd-9a89-e8b11f71734e/files/src/`;
`symbols.json` is that recording's symbol table with one edit — the recorder
writes absolute paths from the machine that recorded it
(`/Users/…/test-programs/noir_space_ship/src/shield.nr`), and those are
rewritten to the paths the container interns (`src/shield.nr`), which is what a
viewer resolves a step's position against. The entries are then sorted by
(path, line) so the file is stable.

## Why a fixture is here at all, and when it goes away

The CTFS container carries **no source text** (Trace-Artifacts.md §2.5), so
source has to arrive from somewhere else. The published route for that is a
content-addressed source bundle at `/src/{chain}/{codeHash}/{bundleHash}.json`
(Source-Resolution.md §5), and `debugger/demo_session.nim` **prefers a
published bundle whenever the tree has one** — `sourceDocumentsFromBundle`
takes precedence over these files, and the M5c demo generator is what will
start publishing them.

Until then a tree with no bundles would render an editor pane with nothing in
it, which would make the debug route uncapturable and the source renderer
untested against real source. So these files are the fallback, and the day the
data plane publishes the same program as a bundle they become dead weight and
can be deleted in one commit — the preference order already points elsewhere.

## What it is not

It is not a second copy of the trace. There is no `.ct` here: the container
lives in `fixtures/trace/` at the repository root and is published into the
data plane by the demo generator. These are the *sources*, which that container
references and does not contain.
