## SDK-CONSUMER: BlockTracer's own Layer-3 ViewModels over @blocktracer/client.
##
## `viewmodel` — the barrel for BlockTracer's own ViewModel layer.
##
## [Front-End-Architecture.md](../../../codetracer-specs/BlockTracer/Front-End-Architecture.md)
## §2's layer 3 holds two families side by side in one reactive graph: the Embed
## SDK's, which know about traces and steps and frames, and these, which know
## about chains and transactions and published data. This module is the second
## family's single import.
##
## ## §3's table, row by row, with the honest status of each
##
## | ViewModel | Module | Status |
## | --- | --- | --- |
## | `ChainRegistryVM` | `chain_registry_vm` | built; the history-floor field has no producer yet (M6) — read when present, `fvUnstated` otherwise |
## | `ChainVM` | `chain_vm` | built |
## | `BlockVM` | `block_vm` | built |
## | `TransactionVM` | `transaction_vm` | built |
## | `AddressVM` | `address_vm` | history and verified-source status built; **account state and code blocked** — no account object class exists in the tree (M6) |
## | `SearchVM` | `search_vm` | shape detection, local inference and direct-path resolution built; **hash index and name shards blocked** at the Client SDK facade (Client-SDK.md §5's open question) |
## | `SourceBundleVM` | `source_bundle_vm` | built |
## | `TraceStatusVM` | `trace_status_vm` | built |
## | `GenerationJobVM` | `generation_job_vm` | the §14.1 state machine built in full; **the transport is blocked** — there is no `/enqueue` service |
## | `CapabilityVM` | `capability_vm` | the ladder and the §9.5 ceiling built; the four host probes are inputs, and wiring them to a real browser is M12's debug route |
## | `ArtifactVM` | `artifact_vm` | derivation, manifest and availability built; **range residency has no writer** until M12's replay worker exists |
## | `DivergenceVM` | `divergence_vm` | built |
## | `AccountVM` | `account_vm` | the rule built and enforced; **every input blocked** by design — the read path is anonymous |
##
## Nothing above is stubbed to look finished. A blocked input has no signal
## rather than a seeded one, so the first real ingestion is an addition and not
## a correction.
##
## ## The two modules that are not ViewModels
##
## `chain_degradation` is the canonical treatment of §14's seven chain- and
## delivery-shaped rows — one enum, precedence as data, per-surface sensitivity
## sets — mirroring what M2b did for the six that reach a pane.
##
## `replay_status` is the **write half of the seam**: it turns chain-shaped
## facts into the four axes of the Embed SDK's catalogue, in the wire spellings
## `ReplayDataStore.applyReplayStatus` accepts. That is how a BlockTracer pane
## over an SDK ViewModel renders a degraded state without the SDK ever learning
## what a chain is.

# The Client SDK facade, reached through `contract_equality`, which re-exports
# it together with `==` for the contract's discriminated unions — see that
# module for why the two travel as one import.
import viewmodel/contract_equality
export contract_equality

import viewmodel/chain_degradation
export chain_degradation

import viewmodel/replay_status
export replay_status

import viewmodel/delivery
export delivery

import viewmodel/chain_registry_vm
export chain_registry_vm

import viewmodel/chain_vm
export chain_vm

import viewmodel/block_vm
export block_vm

import viewmodel/trace_status_vm
export trace_status_vm

import viewmodel/artifact_vm
export artifact_vm

import viewmodel/divergence_vm
export divergence_vm

import viewmodel/source_bundle_vm
export source_bundle_vm

import viewmodel/capability_vm
export capability_vm

import viewmodel/generation_job_vm
export generation_job_vm

import viewmodel/transaction_vm
export transaction_vm

import viewmodel/address_vm
export address_vm

import viewmodel/search_vm
export search_vm

import viewmodel/account_vm
export account_vm
