# Historical Aztec replay inputs

These 41 immutable JSON-RPC transcripts describe the original transactions in
the existing Aztec snapshots: 39 from testnet deployment `1821665230` and two
from mainnet deployment `4248422647`. They are inputs to execution, not encoded
trace containers. Preparation replays them through the real runtime client and
its upstream response schemas, without a live RPC endpoint.

Each transcript was captured with
`aztec-avm-runtime/replay/tools/replay_settled_transaction.mjs --capture`,
including the state witnesses discovered during hydration and the wrong-block
control's actual responses. Transaction bodies came from the published body
store; the runtime checked both the leading hash and the recomputed transaction
hash. The capture retained the original outcome: 40 reproduced transactions and
the one existing divergent transaction.

The public RPC endpoints now serve different deployments. To obtain these
original inputs, archive nodes from `@aztec/aztec@5.2.0` restored published
snapshots before the subjects and retained all subsequent historical state:

| Deployment | Initial L2 snapshot | Pinned L1 head |
| --- | ---: | ---: |
| Testnet `1821665230` | 63152 | 11636765 |
| Mainnet `4248422647` | 67946 | 25882289 |

`provenance.archiveRestoration` records those settings, the public L1 sources,
the capture runtime revision and the execution-observer AVM digest. The local
RPC URLs in `provenance.endpoint` are the actual capture transports; they are
not endpoints that playback contacts. Keeping them as recorded also preserves
the trace's honest chain-provenance event. This changes the old event's endpoint
text, which is accounted for explicitly in the snapshots' container byte counts.

`tools/fixtures/recordings.json` binds every original output to its transaction
and deployment. Preparation checks identity, block, outcome and all declared
recording measurements. A missing response is an error, never a synthesized
not-found answer. The two copies of the Noir-frame transaction use the same real
input; the former reconstructed fixture is no longer substituted for it.
