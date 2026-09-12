# Developing BlockTracer's chain path on `high-mem-server`

The chain follower, its packaging and the ingest service are developed **on
`high-mem-server`**, not on the macOS laptop. This file is the working
agreement for an agent that finds itself with a shell on that host.

Every figure below was checked against a tree on 2026-09-10 and the source is
named. `infra` claims were read from **`origin/live`** (`b99cf923`, fetched
2026-09-10 01:15) with `git show origin/live:<path>`, **not** from the local
`infra` worktree, which was 114 commits behind. `blocktracer` claims were read
from `origin/dev` (`d09416e`). Laptop-state claims were executed on the laptop.

Read [`AGENTS.md` §6](../AGENTS.md) first if you have not; it carries the three
rules, and this file carries the argument behind each.

---

## 1. Why the host and not the laptop

### 1.1 The chain packages build on Linux, and the gate lives there

`tools/chain/nix/default.nix` packages five outputs, exposed by `flake.nix`
lines 173–177 as `chain-tools`, `chain-runtime`, `aztec-ct-writer-wasm`,
`chain-follower` and `chain-follower-nodejs`. Everything about them was
measured on `aarch64-darwin` until **2026-09-08**, when they were first built
**cold, from source, on `x86_64-linux`**: 115 derivations, the whole job in
**2 min 02 s**, `aztec-ct-writer`'s release profile in 32 s (run 34229795600,
`gpu-server-002-mcl-003`). A warm re-run on a sibling sharing that host's store
took 32 s, which is what the gate costs to keep.

The gate is `ci.yml`'s **`chain-follower-linux`** job (`.github/workflows/ci.yml`,
from line 1531). It runs on `[self-hosted, x86-64-v3, gpu, rr-hw-counters]` —
i.e. a **GPU host, not this one** — asserts `builtins.currentSystem` is
`x86_64-linux` before it builds anything, and builds one package per step so a
failure is named by the step. `timeout-minutes: 120`, sized for a cold store,
with a note that an exhaustion is reported by the API as `cancelled` rather
than `failure`.

What the Linux build showed that darwin could not, all from that file's header:
the fixed-output npm hash computed on darwin yields a working Linux tree
(`bb.js` and `leveldown` ship many platforms in one package; what matters is
which object node *selects*, and on linux-x64 both are ELF64-x86-64);
`aztec_ct_writer.wasm` linked by the packaged `lld` is **268,136 bytes, 39
exports, 0 imports**; and the wrapper's `set --` argument passthrough is
asserted by two probes that differ only in the message they must produce.

So: this repository's chain packages have a Linux verdict, and the machine that
runs them in production is a Linux machine. The laptop has neither.

### 1.2 `avm.wasm` stopped being a file in someone's home directory

`infra`'s `services/blocktracer-ingest/avm-wasm.json` pins the module by
content:

```
sha256  41af520a72939affdd9cc1287f8d61a58e216e126a11f7c824cadcc3e4b905a7
bytes   1565773
url     .../aztec-avm-runtime/releases/download/avm-wasm-41af520a/avm.wasm
```

— all three verified in that file, together with the provenance block
(`aztec-avm-runtime` @ `9144ff54`, workflow `avm-wasm.yml` job `node-host`,
run 34236949453, runner `gpu-server-002-mcl-004`, staged 2026-09-08T14:27:13Z).

The sentence that explains why the pin exists is in the **`.nix` beside it**,
`services/blocktracer-ingest/avm-wasm.nix`, not in the JSON:

> `runtime.avmWasm` used to be an operator-supplied path, and every actual value
> it ever held was a file in somebody's home directory. That is the reason the
> follower had only ever run on one workstation: the module could be enabled
> anywhere and the AVM could be produced nowhere.

`avm.wasm` is still **not built** by either repository — barretenberg's CMake
calls `FetchContent_Populate` at configure time, which a nix sandbox has no
network for, and `verification/lib_avm_wasm.sh` demands 8 GB of free work
space. Both files say so and neither pretends otherwise. The pin is a
`fetchurl` against a public release asset because the ingest R2 bucket is
declared private on purpose (`terraform/cloudflare/blocktracer-prod/main.tf`,
citing `Chain-Data-Ingestion.md` §4.8) and `fetchurl` has no credentials.

### 1.3 What the laptop actually requires — the reproducibility problem this moves

The historic-replay work needs a hand-assembled toolchain that exists nowhere
but this laptop. Executed on it, 2026-09-10:

| Piece | State on the laptop |
|---|---|
| `avm.wasm` | `~/.cache/aztec-m36-notes/site/assets/avm.wasm` — a browser-capture cache directory, one of a dozen `~/.cache/aztec-*` trees each holding its own copy |
| `ct_writer.wasm` | The main runtime checkout `/Users/zahary/m/dev/aztec-avm-runtime` **cannot supply it**: its built `aztec_ct_writer.wasm` is 262,709 bytes and its export table contains no `ct_source_step`. `.agent-wt/bt-frame-view-avm`'s build (263,217 bytes) does. `bt-historic-replay-runtime` carries the symbol in `ct-writer/src/lib.rs` but has no built wasm at all |
| A separate runtime worktree | Consequently yes — the replay driver and the writer come from different checkouts |
| Node | System node is **v20.20.1** (`/opt/homebrew/bin/node`) and it **rejects the flag outright**: `node --experimental-wasm-exnref -e …` → `node: bad option: --experimental-wasm-exnref`. Node ≥ 22 is required for that reason alone |

None of that is declared anywhere, none of it is fetchable by another machine,
and the differences between the copies are load-bearing (the `ct_source_step`
export is the whole difference between a source-level and a rung-3 capture).
**That is the problem the move solves**: on `high-mem-server` every one of those
inputs is either a store path from `tools/chain/nix` or a content pin in
`infra`.

Two corrections to the folklore, both from `tools/chain/nix/default.nix`'s own
measurements (2026-09-07, darwin-aarch64): node **22 accepts**
`--experimental-wasm-exnref`, so the flag is not what forces a newer node; and
the `--import-memory` `avm.wasm` compiles on node 22 *without* the flag and
needs it on node 24. The full replay produced byte-identical `.ct` containers on
both. `nodejs_22` is therefore the single pin used by the devshell, the package
and the infra module's `nodePackage`.

---

## 2. Setup

Repos live at **`/home/zahary/metacraft/<repo>`** — the mapping in
`infra/docs/Continue-On-Linux.handoff.md` §0 is `/Users/zahary/m/dev/<repo>` →
`/home/zahary/metacraft/<repo>`, and that section ends "On Linux, `direnv allow`
each repo". Do that once per repo.

The idiom for running anything inside a repo's devshell non-interactively is the
one `infra/docs/partner-program-staging.md` uses throughout:

```sh
direnv exec /home/zahary/metacraft/infra bash -lc 'cd /home/zahary/metacraft/infra && just …'
```

Name the **exact** repo path in `direnv exec` — it is the directory whose
`.envrc` is loaded, and it is not inferred from the `cd` inside the command.

**Heavy build and capture work goes in `/build`.** It is a dedicated ZFS
dataset, converged idempotently by
`machines/server/high-mem-server/configuration.nix` (the
`Converge zroot/root/build dataset + properties (/build)` unit):

```
zfs create -o mountpoint=/build zroot/root/build
  mountpoint=/build  sync=disabled  …
install -d -o zahary -g users -m 0775 /build
```

`sync=disabled` is why it is the right place: build and capture output is
reproducible, so the writes may be buffered and never fsynced, which is the only
lever that actually reduces this host's exposure to §3c. CI's Rust builds
already land there (`mcl.github-runners.cargoTargetBase = "/build/cargo"`).
Never `$HOME`, never `/var` — both are on the same contended pool with normal
sync semantics.

---

## 3. Three hazards

### (a) The pull-agent restarts what you stop

`high-mem-server` is an auto-deploy target. `infra/services/deployment/default.nix`
enables `services.mcl-deploy-agent` for every host where

```nix
pkgs.stdenv.hostPlatform.isLinux
&& config.mcl.host-info.type == "server"
&& !(config.mcl.host-info.isDebugVM or false)
```

and `machines/default.nix` sets `mcl.host-info.type` from the machine's
directory, so everything under `machines/server/` is a `server`. The agent polls
`https://cache.metacraft-labs.com/mcl-deployments/high-mem-server/latest.json`
with `dryRun = false`.

`services/blocktracer-ingest/default.nix` declares the follower unit
`blocktracer-ingest.service` with `wantedBy = [ "multi-user.target" ]`, and a
`blocktracer-ingest-publish.service` driven by a timer at
`publishIntervalSeconds`. So once the module is bound to this host, **any merge
to infra's `live` re-activates the follower mid-manual-run, silently** — a
`systemctl stop` is undone by an activation you did not initiate and will not be
told about.

> **Correction to an earlier draft of this note.** On `origin/live` today,
> `mcl.blocktracer-ingest` is **not enabled on any machine**: the only
> instantiation in the tree is `tests/blocktracer-ingest-deployment.nix`. The
> hazard is therefore *prospective* — it becomes live the moment the module is
> bound to `high-mem-server`, which is the point of doing this work here. Do not
> read a quiet `systemctl status blocktracer-ingest` as evidence the hazard is
> not real; read it as evidence the binding has not landed yet.

**Use `systemctl mask`, not `stop`, for the duration of a manual run, and
unmask afterwards.** A masked unit is a symlink to `/dev/null`; activation
cannot start it. An unmask you forget is worse than the stop you avoided, so
pair them in the same shell.

`infra/AGENTS.md` "Guardrails for agent-driven edits" states the same hazard
from the other side — "Never bypass the auto-deploy flow by SSH-ing to a host and
running `nixos-rebuild switch` yourself … The pull-agent will overwrite your
change on the next tick." Stopping a unit the deployed manifest wants running is
that sentence read backwards.

### (b) The R2 lease does not protect you from yourself

From `services/blocktracer-ingest/default.nix`, the publisher's lease:

```sh
LEASE_KEY="_leases/$CHAIN"
LEASE_ID="$(cat /etc/machine-id 2>/dev/null || hostname)"
…
s3 put-object --bucket "$BUCKET" --key "$LEASE_KEY" --if-none-match '*' --body "$LEASE_TMP"
…
if [[ "$HOLDER" != "$LEASE_ID" && "$AGE" -lt 900 ]]; then
  echo "… is leased by '$HOLDER' …; refusing to write." >&2
  exit 75   # EX_TEMPFAIL
fi
```

`leaseTtlSeconds` defaults to **900**. The identity is **`/etc/machine-id`**,
which is a property of the *host*. A manual publish run started by you on
`high-mem-server` therefore presents the **same holder** as the service's own
publish timer: the `HOLDER != LEASE_ID` conjunct is false, the guard is skipped,
the lease heartbeat is refreshed, and **both processes proceed**. The lease
guards against a second host. It does not guard against a second process.

Losing the lease is `exit 75`, and the unit declares `SuccessExitStatus = [ 75 ]`
— deliberately, because a host that legitimately lost the lease is the system
working. The consequence for you is that **contention does not colour the unit
red**, does not fire `OnFailure`, and appears only as one `refusing to write`
line in the journal.

Separately, and worse for manual work: the **follower has no lease, no cursor
and no lock at all.** Its own header:

> Today the follower's only resume state is `snapshot.json`, re-read at startup
> into an in-memory `Set`. There is no cursor, no lease, and no lock: two
> followers on one directory last-write-wins each other, and a kill between the
> driver writing `ct/<hash>.ct` and the rename of `snapshot.json` leaves an
> orphan container that nothing references.

A 2026-09-09 correction in the same file withdraws the cursor claim outright:
`follow-chain.mjs` keeps ONE cumulative snapshot per chain that only ever grows,
so listing `observations/` does **not** reconstruct which ranges were scanned.
That is recorded as an open gap.

Practical rule: **mask the follower (3a) before running one by hand**, and treat
a hand-run publish as something the service can be racing even though nothing
will go red.

### (c) Disk write bandwidth is the binding resource, and cgroup I/O control cannot save you

`infra/docs/host-health/high-mem-server.healthlog.md` §2, "Primary failure mode
— ZFS write stalls → watchdog reset", mechanism marked **confirmed**:

Six consumer QLC SSDs (Samsung 870 QVO 4TB) in RAID5 behind a PERC H710 sustain
only **~78 MB/s** of ZFS writes once past their SLC cache — RAID5
read-modify-write is the worst case for QLC. Past that, txg sync reaches ~38 s
against a 5 s `zfs_txg_timeout`, measured on the running host:

```
txg=19357940  ndirty=2937MB  otime=37.3s  stime=37.85s     (zfs_txg_timeout = 5s)
txg=19357939  ndirty= 964MB  otime= 5.1s  stime=37.33s
```

`zroot` is `/` and has `failmode=wait`, so a stalled I/O blocks forever and every
disk-touching process parks in uninterruptible D state; PID 1 is eventually
starved and stops petting `/dev/watchdog0`; the iDRAC hard-resets the box. The
controller corroborates: **395 of its last 400 events** are `Unexpected sense …
Sense: b/00/00` (ABORTED COMMAND), with an identical `Other Error Count = 1158`
on all six drives — uniform, i.e. controller-path aborts rather than one failing
disk.

**Four watchdog hard resets, iDRAC SEL (the authoritative record):**

```
48 | 2026-08-18 15:37:16 | Watchdog2 | Hard reset
49 | 2026-08-18 20:44:49 | Watchdog2 | Hard reset
4a | 2026-08-19 01:56:13 | Watchdog2 | Hard reset
4b | 2026-08-20 00:18:39 | Watchdog2 | Hard reset
```

That span is 32 h 41 m; the healthlog phrases it as the first reset "~22 hours"
after a deploy, "then three more inside 34 hours". The trigger was
`7305d978` (2026-08-17) raising `eph-linux-x64` `maxRunners` 6 → 8, reverted in
`bed8284a` with a comment recording that **storage, not RAM or vCPU, is the
binding constraint here**. `services/garm-incus-runners.nix` repeats the whole
argument at `scaleSets.incus`, ending "DO NOT raise this without measuring zroot
write throughput first."

`machines/server/high-mem-server/storage-stall-tolerance.nix` raised the
watchdog to 610 s (the R620's `max_timeout` is 613), which buys a *guaranteed*
grace of only `runtimeTime/2` ≈ 305 s, because systemd contracts only to ping
once per half-timeout. It does not remove the failure mode; it widens the window
a stall must exceed.

**cgroup I/O control cannot help.** From
`machines/server/high-mem-server/resource-isolation.nix` — note the path: it is a
**machine** file, not a `services/` one:

> The obvious tool — cgroup-v2 `io` controller weights (`IOWeight=`,
> `IOWriteBandwidthMax=`) — DOES NOT WORK on ZFS. ZFS does not participate in the
> block-layer cgroup io controller: writes are buffered in the ARC and the actual
> disk I/O is issued LATER by ZFS's own kernel taskqs (`txg_sync`, `z_wr_iss`, …)
> which run OUTSIDE the originating service's cgroup.

Verified on the box: ~60 `z_*`/txg kernel threads issue all pool I/O and
`system.slice/*/io.stat` does not reflect per-service ZFS writes.

And the CPU policy points the wrong way for you. The same file sets:

| Slice | `CPUWeight` | Holds |
|---|---|---|
| `critical.slice` | 2000 | `atticd`, `nginx`, `sshd` (+ `MemoryMin=2G`, `MemoryLow=4G`) |
| **`user.slice`** | **1000** | tmux, **agent sessions** |
| `system.slice` | 100 (default) | `garm`, `incusd`, `nix-daemon` |
| **`builds.slice`** | **20** | the CI runners |
| `machine.slice` | derived (900 today) | libvirt Windows domains |

An agent session outweighs the entire CI runner fleet **50 : 1** on CPU. The
isolation policy protects interactive work from a build storm; it does nothing
to protect the pool from *your* build, and it actively hands your build the CPU
to get there faster.

**A cold Nix build on this host is the single most likely cause of the next
watchdog reset.** (Reasoned, not measured: the measured facts are the ~78 MB/s
ceiling, the four resets, the runner-count trigger and the ineffective io
controller; the ranking is an inference from them.) Mitigations, in order:
build in `/build` (`sync=disabled`); prefer a substituter hit over a cold build
— the private cache is on this very host; keep `-j` modest; and never start a
large cold build while the runner fleet is busy.

---

## 4. Blast radius

State this plainly, because it is unusually wide for a development host. If
`high-mem-server` resets, all of the following go with it:

* **Fleet observability.** `configuration.nix` imports
  `services/monitoring/{prometheus,grafana,loki,promtail,node-exporter,deployment-events}.nix`
  plus `win-runner-memory.nix`. This is the Prometheus/Grafana/Loki host for the
  fleet — a reset blinds every other host's monitoring, including the alerting
  you would use to notice the next problem.
* **The deployment channel itself.** It runs `atticd` (the private Nix cache)
  and the nginx fronting it, which publishes the signed deployment manifests.
  `resource-isolation.nix`'s header records the observed failure (2026-06-25):
  atticd's SQLite pool times out at 30 s → every request 500s → CI's "Publish
  Deployment Manifests" step fails → **no new manifest is published → NOTHING
  reaches this or any other host.** An I/O storm can break the mechanism used to
  deploy a fix for the I/O storm.
* **The CI fleet.** 14 `eph-linux-x64` slots (6 + 4 + 4 across
  `metacraft-labs` / `blocksense-network` / `agent-harbor`), 4 more on the
  `eph-linux-x64-nested` transitional alias, up to 8 ephemeral Windows VMs
  (`eph-win-x64` 6 + `eph-win-x64-release` 2) and the static `win-ci-vm-001`.
  Figures from `services/garm-incus-runners.nix` and
  `infra/docs/CI-Runner-Fleet-Status.md` §1, which agree.
* **Data integrity.** `zroot` is a **single non-redundant ZFS vdev** — there is
  parity at the RAID5 layer, but ZFS sees one vdev, so it can *detect*
  corruption and never *repair* it. It carries **15 permanent data errors** in
  `zroot/root:<0x2345264>` (healthlog §1, verified 2026-08-19). The controller
  reports `FW supports sync cache: No`, so ZFS cannot flush its 512 MB
  write-back cache; a reset mid-stall discards acknowledged writes, and every
  reset is a fresh opportunity to add errors.
* **Silent state loss on reset.** Healthlog §2 (added 2026-08-22): any Go
  service here using `mattn/go-sqlite3` gets `PRAGMA synchronous = NORMAL`
  unless its DSN says otherwise, and in WAL mode that means commits are not
  fsynced. A watchdog reset demonstrably rolled back two GARM job-state updates
  committed ~3 minutes earlier. After any reset, treat the last
  seconds-to-minutes of every WAL-SQLite service's state as possibly lost.

**Do not restart GARM or `incusd` to "unstick" a queue.**
`infra/docs/CI-Runner-Fleet-Status.md` §5 says so verbatim: "Running jobs are
lost and the queue is unchanged. Both are operator decisions." §2 records the
worked example — a report called `eph-win-x64` dead with 0 online runners and
recommended restarting GARM and rotating credentials; the pool was in fact
*saturated at its ceiling*, two Windows instances were running, and a restart
would have killed both plus an in-flight macOS spawn. The same document also
forbids reclaiming orphaned pool files, incus volume rows or stopped `garm-*`
containers by hand — there is a managed sweeper
(`machines/server/high-mem-server/garm-orphan-sweeper.nix`) whose whole value is
the in-use precondition a manual `rm` does not have.

---

## 5. The accepted security posture

The operator has decided the agent runs as `zahary`. `users/zahary/user-info.nix`
puts that account in `super-admins` (alongside `devops` and `maintainers`, which
give `wheel` on servers via `modules/default-server-config/users.nix`), and this
repository's agenix ciphertexts are encrypted to the host SSH key **plus every
`super-admins` member** — the pattern is stated in
`services/attic/default.nix`, `services/repro-binary-cache/`,
`services/netbird/`, `services/metacraft-license-signing/` and the
secret-rotation runbooks. An agent with that account's SSH key can therefore
decrypt every service secret in the tree, including the R2 credential
`mcl.blocktracer-ingest.secretFiles.r2Credentials`. It also reaches the
virtualisation control plane without sudo — `modules/users.nix` adds `libvirtd`
to every included user and `incus-admin` wherever incus is enabled, "so `incus`
works without sudo" — and reaches GARM through `garm-admin`, a wrapper granted
to `super-admins` by a `NOPASSWD` sudo rule scoped to that one command path,
which `services/garm-admin-cli/default.nix` records as granting "full fleet
control". `codetracer-specs/BlockTracer/Deployment-And-Operations.md` §6c states
that **"Agents never hold production credentials"**; this host is a deliberate,
operator-approved exception to that rule, chosen so that one agent can move
between manual runs and the production service. This paragraph exists so a
future reader knows it was chosen rather than overlooked.
