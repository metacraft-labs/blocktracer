# The recorder conformance kit

You are writing a recorder for a chain this project has never run. This kit answers
one question, without you reading our reader, building this repository, or asking us:

> **Does the tree I just wrote validate?**

It is a fixture template you copy and one command you run.

## What is in the box

```text
conformance-kit/
  README.md               this file
  template/
    minimal/              the FLOOR: every required member, nothing else
    complete/             EVERY member, and every availability state a snapshot reaches
```

and, in a release, three binaries beside them:

| command | reads | answers |
| ------- | ----- | ------- |
| `blocktracer-conformance` | a **snapshot** tree | all three checks below, in order, one verdict |
| `blocktracer-validate` | a **published** tree | is it well formed against the contract? |
| `blocktracer-client-conformance` | a **published** tree | can a consumer read it end to end? |

`blocktracer-conformance` is the one to run. It ingests your snapshot into a
temporary directory and then runs the other two over what that produced, so the
three checks are chained rather than described:

```sh
blocktracer-conformance --snapshot path/to/my-snapshot
```

It exits `0` when all three are clean, `1` when any refuses, and `2` when there is
no snapshot tree at the path you gave — a run with no fixture is **not** a pass.

It reaches no network, needs no checkout and needs no Nim toolchain: the contract
is compiled into the binary, and every file it opens is under the directory you
named or the directory it publishes into.

## What a failure tells you

Every refusal names the **rule** of `Data-Contract.md` §5 it enforces and the
**path** of the offending file. *Invalid tree* is not a report anyone can act on;
this is:

```text
[1/3] snapshot   REFUSED
REFUSED (Data-Contract.md §5):
  rule: S5-COUNTS-ROWS (§5.2)
  path: /home/you/my-snapshot/snapshot.json
  said: [§5.2 S5-COUNTS-ROWS] the snapshot at /home/you/my-snapshot/snapshot.json
        states counts.blocks=26 counts.transactions=9 over 26 block(s) and 8
        transaction(s). `counts.blocks` and `counts.transactions` are measurements
        of the rows beside them and must equal their lengths…
```

The rule id is the key you grep §5 for. The full set of them is in
`tools/chain/snapshot-contract.json` in the `blocktracer` repository, which is §5 in
machine-readable form and what both the reader and this kit read — the same file,
compiled into the binary you just ran. It states every rule id, the section it
belongs to, and the sentence it enforces, so you can resolve a citation without
holding §5 itself.

## The template, and how to read it

The two trees are not two examples of the same thing. They are the two ends of the
contract. Between them every member you **may leave out** appears present in one tree
and absent in the other — which is how you learn, without reading §5.2b line by line,
which those are. The **52** members the contract requires of every container appear in
both, because a tree short of one of them is not a conforming tree and could not be
shipped here as an example of one. (The census is 134 members: 52 required
everywhere, 6 required on some rows and not others — `container` on a traced row,
`refusalReason` on an untraced one — and 76 optional. The 82 that are not required
everywhere are the ones shown both ways.)

**`minimal/`** is the floor: one block, one untraced transaction, every member the
contract requires and not one more. No sidecars, no `captures`, no
`artifactResolution`. If your producer can write this, it can publish.

**`complete/`** carries everything. Six transactions, chosen so that each is a shape
the contract treats differently:

| row | `outcome` | what it demonstrates | published `availability` |
| --- | --------- | -------------------- | ------------------------ |
| 1 | `replayed` | a container, all four row-named sidecar kinds **named explicitly** at non-default paths, every optional member of a row | `ready` |
| 2 | `replayed` | the same, with the sidecars found through §5.1's **defaults** — the row names none of them — and every container carrying only its required members | `ready` |
| 3 | `divergent` | a real recording whose effects did not reproduce the block's | `divergent` |
| 4 | `refused` | **this pipeline declined it**, with a machine-readable `refusalReason` from the closed set | `absent`, with a cause |
| 5 | `not-attempted` | every execution states its **own** reason, so the row leaves none for a container to belong to | `absent` on **every** execution — the list-shaped overlay |
| 6 | `private-only` | **the chain published no such execution**: a sentence and *no* `refusalReason`, because the closed set is a set of things *we* did | `absent`, no cause |

Rows 4, 5 and 6 are the point of the template rather than decoration. "This
execution was declined, and here is why", "every execution was declined, each with
its own sentence" and "the chain never made this execution public" are three
different statements, and a recorder that can only express the first has a page
that lies about the other two.

A few shapes look odd on purpose:

- the second call trace's single frame is `{}`. Every member of a call frame is
  optional, and a template that never showed that would leave you guessing;
- the second source bundle, the second cost entry and the second `artifacts` entry
  each carry a **different** subset of their container's optional members, so no
  member is shown only one way;
- `minimal/` and `complete/` use different chain slugs, because a slug another
  producer already published is refused rather than resolved (`S5-CHAIN-UNIQUE`).

## The template cannot quietly fall behind the contract

The completeness of the template is not maintained by hand. `§11` of
`tools/chain/snapshot-contract-selftest.mjs` walks these trees against the census
itself and fails when

- a member §5 names is exercised by no tree,
- a member a conforming tree may omit is never shown absent,
- or a member appears in a tree that the census does not name.

So a member added to the contract that the template does not exercise turns
something red, and each of those three arms is shown able to fail by a planted
control in the same suite.

## What a snapshot cannot say

`Trace-Artifacts.md` §6 has **five** availability states. A snapshot
reaches **three** of them — `ready`, `divergent` and `absent` — and the template
carries all three. The other two, `onDemand` and `unsupported`, are decisions of the
*publisher* rather than facts a capture carries: `onDemand` offers a "Generate
trace" button, and `unsupported` says no recorder exists for this VM. The reader
constructs neither, and `tests/tchainsnapshot.nim` asserts that it does not, so this
is a measured gap rather than a claim about coverage.

## The two documents this file names

`Data-Contract.md` and `Trace-Artifacts.md` are BlockTracer's specifications. They are
named here, not linked: this README travels inside a released artifact, and a relative
link out of it resolves only in a checkout that has both repositories side by side —
which is exactly the checkout this kit exists so that you do not need. What travels
with you instead is `tools/chain/snapshot-contract.json`, §5 in machine-readable form,
compiled into the binary; ask us for the documents if you want the prose.

## If the kit is wrong

The questions you had to ask that §5 did not answer are §5 amendments, not tribal
knowledge. Say which section you were reading and what you could not decide.
