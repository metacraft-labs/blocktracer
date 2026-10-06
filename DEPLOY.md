# DEPLOY — a plan for serving blocktracer.org from R2

> **Corrected 2026-09-28 against a full-scale rehearsal.** Everything below was
> written before any of it had been run. A dress rehearsal of the real tree
> (**460,589 objects**, both chains, against a local S3) then found a data-loss
> defect and three further corrections, all marked **CORRECTION (2026-09-28)**
> in place. The step order also changed: **Step 2b now runs first.** Read the
> corrections before executing a step; the surrounding prose is otherwise as
> written and still accurate.

> **CARRIED OUT 2026-10-05/06. The block below is kept as written and is now
> history, not status.** blocktracer.org is served from the **`blocktracer` R2
> bucket**, not from Pages. The full history of both Aztec chains is published:
> **882,642 objects**, `aztec` at generation `raztec00001` (102,690 blocks /
> 60,846 transactions) and `aztec-testnet` at `rtestnet0001` (99,092 blocks /
> 25,421 transactions) — 201,782 blocks, against the 170 + 9 the apex served
> before. The publish ran ~23 hours; bucket verification passed exhaustively on
> both chains and the census matched at 882,642.
>
> The steps were executed in the corrected order (1 -> 2b -> 3 -> 4 -> 2), and
> each one that behaved differently from this file is marked
> **CORRECTION (2026-10-06)** in place. The file stays a runbook, because the
> next chain repeats it.
>
> **One defect is still open at the time of writing:** R2 resolves no index
> document, so directory-ish URLs 404 (`/aztec` -> 404 while
> `/aztec/index.html` -> 200). See the correction under Step 2.

> **None of this is production, and none of it has been done.** blocktracer.org is
> served by the **`blocktracer` Cloudflare Pages project**, with the apex as a
> custom domain on it and `live` as its production branch — see
> [`AGENTS.md`](./AGENTS.md). Promoting production means fast-forwarding `live`,
> and needs no credential a deploy does not already hold.
>
> Every step below is undone: `data.json` declares no `blocktracer` R2 bucket,
> `r2_custom_domains` is `{}`, the repository holds no `R2_*` secret, and no
> publishing workflow has ever existed on any branch. `infra`'s own README says
> the apex "is already served by its Pages project (apex CNAME + custom domain
> added out-of-band)".
>
> This file described itself as production for long enough that readers could not
> answer what serves blocktracer.org. Keep it as a plan; if it is ever carried
> out, the sentence above is the one to change first.

This is the **credentialed** runbook that *would* take the demo (fake-data)
BlockTracer tree live on **blocktracer.org** from Cloudflare R2 behind the CDN,
kept fresh by the M8 delta publisher (`blocktracer-publish`).

Everything an **agent** can do is already done and merged on `feat/m8-publisher`:
the publisher, its `ObjectStore` backends (local + R2/S3), and the tests. The steps
below need production credentials and a human-gated apply, so they are for the
**parent / a production operator** — per
`codetracer-specs/BlockTracer/Deployment-And-Operations.md` §6c, *agents never hold
production credentials*.

Facts used below (from `infra/terraform/cloudflare/metacraft-prod/`):

| Thing                    | Value                                        |
| ------------------------ | -------------------------------------------- |
| Cloudflare account id    | `803741d99690718276ea30950f690c46`           |
| `blocktracer.org` zone   | already declared; zone id `3e380c5c250ae708bfaf2b38ceed750a` |
| Infra root (Cloudflare)  | `infra/terraform/cloudflare/metacraft-prod/` |
| Infra root (CI secrets)  | `infra/terraform/github/secrets-metacraft-prod/` |

Nothing here is a dashboard click that stays a dashboard click: R2 buckets, DNS and
secrets are Terraform/OpenTofu in the `infra` repo, applied through its
plan-on-PR / apply-on-merge pipeline (Deployment §6b). The two exceptions the
provider cannot yet manage (the R2 custom domain) are called out explicitly.

---

## Step 1 — Add the R2 bucket (infra PR)

The whole published tree lives in **one R2 bucket** (two CDNs in front of one bucket
is the availability design — Deployment §4.2). Add it to the metacraft-prod data
model.

Edit `infra/terraform/cloudflare/metacraft-prod/data.json`, under `r2_buckets`:

```json
    "blocktracer": {
      "account_id": "803741d99690718276ea30950f690c46",
      "name": "blocktracer"
    }
```

`default.nix` already fans `r2_buckets` into `cloudflare_r2_bucket.this`, so this is
the entire change. Open a PR against `infra`; the terraform-cloudflare CI plans it,
and merge applies it (human-gated production environment).

If the bucket already exists (created during development), import it first — zero
plan drift is the gate (Deployment §6b.2). Add to `import-ids.json`:

```json
    { "to": "cloudflare_r2_bucket.this[\"blocktracer\"]", "id": "803741d99690718276ea30950f690c46/blocktracer" }
```

---

## Step 2 — Bind `blocktracer.org` to the bucket (R2 custom domain)

> **CORRECTION (2026-09-30) — this step runs LAST, after Step 4 has published.**
> Its number is its history, not its position. `infra`'s
> `terraform/cloudflare/metacraft-prod/README.md` (lines 53-58 on `live`) already
> states the rule for this exact binding:
>
> > "Binding it to the apex (DEPLOY.md Step 2, `cloudflare_r2_custom_domain` —
> > **not** Terraform-manageable in provider v5, so an operator API call) creates
> > the proxied apex record pointing at R2 and **Pages stops serving
> > `blocktracer.org` the moment it lands**. The order is: create this bucket →
> > publish the tree into it (Step 4) → only then bind the domain. **Binding an
> > empty bucket takes the site down.**"
>
> The apex is indeed already serving: on 2026-09-30 it answered with a real
> registry and real generations — `aztec` 170 blocks / 2 transactions,
> `aztec-testnet` 9 blocks / 3 transactions.
>
> So this binding is not "turn the site on". It is **switching a live origin**,
> and the switch is atomic while the upload is not. Bind before Step 4 and the
> apex serves an empty bucket for the length of the publish — at the rehearsed
> 536 objects/s, a 882,642-object tree is about **27 minutes of hard downtime**,
> for no gain, replacing a working site with nothing.
>
> The order is therefore: **Step 1** (bucket) → **Step 2b** (cache rules, per the
> 2026-09-28 correction below — they must be in force before the origin changes)
> → **Step 3** (credential) → **Step 4** (publish, verified) → **this step**.
>
> The verification line further down still reads `200 once Step 4 has published
> index.html`. Under this order it is a `200` immediately, and if it is not, the
> bind is what to undo.


> **CORRECTION (2026-09-28) — run Step 2b (cache rules) BEFORE this step.**
> The `no-store` that trace 404s carry today is **Cloudflare Pages' default, not
> configuration**, and it disappears the moment R2 becomes the origin. Binding R2
> first therefore opens a window in which 404s under `/t/` are cached for
> Cloudflare's default **three minutes** — which is exactly the go-live defect the
> cache rules exist to prevent, arriving in the gap between two steps of this
> runbook. Landing the rules first puts the contract in force at the instant the
> origin changes. See `infra` PR #1626, which measured every rule against the live
> Pages site before recommending this order.


> **CORRECTION (2026-10-06) — the endpoint below was wrong, and undoing it was
> worse than leaving it. ~50 minutes of production downtime.**
>
> There are two R2 custom-domain endpoint families and only one of them works:
>
> | endpoint | what it does |
> | --- | --- |
> | `POST .../r2/buckets/{b}/custom_domains` | attaches the domain but **never sets `enabled`**. The apex then answers **401**. |
> | `POST .../r2/buckets/{b}/domains/custom` | the correct one. The response carries `"enabled": true` and the apex serves. |
>
> The command further down used the first. It returned success, so nothing looked
> wrong until the apex started answering 401.
>
> **Then detaching to retry deleted the apex DNS record**, turning the 401 into a
> **522** — the bind is not reversible by detaching. Undoing a bad bind removes
> the record the bind created, so "undo and try again" is a second outage, not a
> rollback. Re-binding through the correct endpoint restored service.
>
> So the verification line below ("`200` immediately, and if it is not, the bind
> is what to undo") is right that the bind is the suspect and **wrong that undoing
> it is safe**. Re-bind through `/domains/custom`; do not detach.
>
> **Check `enabled`, not the HTTP status of your own call**, which is the only
> way to tell these two apart before users do:
>
> ```bash
> curl -sS -H "Authorization: Bearer $CF_ADMIN_TOKEN" \
>   "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/r2/buckets/blocktracer/domains/custom" \
>   | jq '.result[] | {domain, enabled, status}'
> ```

> **CORRECTION (2026-10-06) — R2 resolves no index document; Pages did.**
> Pages served `index.html` for a directory-ish path. R2 is an object store: a
> request names an object or it 404s. So after the switch `/`, `/chains` and
> `/aztec` all 404 while `/aztec/index.html` is a `200` — every human-facing
> entry URL, broken, with the data plane (`/d/**`, `/t/**`) completely healthy.
> This is invisible in any check that fetches a real object.
>
> The fix is **not** in the publisher, which would have to write a duplicate
> object per directory. It is a Cloudflare `http_request_transform` ruleset in
> `infra` (`metacraft-prod`, PR #1714) that rewrites a path with no known file
> extension to `.../index.html`.
>
> **Budget a token grant for it.** Ruleset permissions are granted per *phase*,
> and the apply token held only `Dynamic URL Redirect`. The first apply failed
> with `403 "request is not authorized"`, which names neither the permission nor
> the zone. Grant `Transform Rules: Edit` on the apply token **and `Read` on the
> plan token** (otherwise the apply starts working and the next PR's plan starts
> failing), plus the `blocktracer.org` zone scope on each. See
> `infra/machines/ci/secrets/cloudflare/README.md`.

The zone `blocktracer.org` already exists in the root. What remains is to serve the
bucket at the apex and turn on the CDN.

**Terraform cannot do this in provider v5** — `cloudflare_r2_custom_domain` has no
import support, the same wall `default.nix` documents for the codetracer domains. So
this one binding is done by a production operator via the Cloudflare API/dashboard
and then recorded, not left as drift:

```bash
# Operator, with a token scoped to R2 + DNS on this account.
curl -sS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/803741d99690718276ea30950f690c46/r2/buckets/blocktracer/domains/custom" \
  -H "Authorization: Bearer $CF_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "domain": "blocktracer.org",
    "zoneId": "3e380c5c250ae708bfaf2b38ceed750a",
    "enabled": true,
    "minTLS": "1.2"
  }'
```

This creates the proxied `blocktracer.org` (apex) DNS record pointing at R2 and
enables Cloudflare in front of it. Verify:

```bash
dig +short blocktracer.org            # a Cloudflare-proxied record
curl -sI https://blocktracer.org/     # 200 once Step 4 has published index.html
```

> **Cache rules are required for correctness** and are a separate `infra` PR against
> the same root (Deployment §4.1): `current.json` must be
> `max-age=0, s-maxage=5, stale-while-revalidate=60`; `/d/**`, `/t/**`, `/idx/**`,
> `/_a/**` immutable; 404 under `/t/` `no-store`; range requests cacheable. The full
> table is `Publishing-And-Caching.md` §4. The fake-data site is browsable without
> them; they are needed before it is *fast and correct under load*.

---

## Step 3 — Create the publisher credential and store it as repo secrets

> **CORRECTION (2026-09-28) — a Step 3b is missing from this runbook.**
> **R2 bucket CORS must be configured before any artifact is published**
> (`Trace-Artifacts.md` §5.3, which also specifies `Cross-Origin-Resource-Policy`). Without it the debugger
> cannot fetch trace containers cross-origin, and the symptom appears in the
> browser at first use rather than at publish time.

> **The policy itself (added 2026-09-30).** The correction above says CORS is
> required and does not say what it is, which leaves the operator to derive it
> from a spec at the moment they are least able to check it. It is:
>
> ```json
> [
>   {
>     "AllowedOrigins": ["*"],
>     "AllowedMethods": ["GET", "HEAD"],
>     "AllowedHeaders": ["Range"],
>     "ExposeHeaders": ["Content-Range", "Content-Length", "ETag"],
>     "MaxAgeSeconds": 86400
>   }
> ]
> ```
>
> Dashboard → R2 → `blocktracer` → Settings → CORS policy, or
> `aws s3api put-bucket-cors --bucket blocktracer --endpoint-url "$R2_ENDPOINT"
> --cors-configuration file://cors.json`.
>
> **CORRECTION (2026-10-06) — the `aws s3api` form above fails with the
> publisher credential.** `put-bucket-cors` is *bucket configuration*; the
> publisher token is deliberately scoped to bucket **items** (`Workers R2
> Storage Bucket Item Read`/`Write`), so it returns `AccessDenied`. Widening it
> to the account-wide `Workers R2 Storage` pair would make the token able to
> create and delete buckets, which is exactly what the item-scoped pair exists
> to prevent — do not substitute them to make this command work.
>
> Set CORS through the Cloudflare API with an **admin** bearer token instead,
> which is also what `scripts/go-live.sh` Step 2 now does:
>
> ```bash
> curl -sS -X PUT \
>   "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/r2/buckets/blocktracer/cors" \
>   -H "Authorization: Bearer $CF_API_TOKEN" \
>   -H "Content-Type: application/json" --data @cors.json
> ```
>
> Verified in production on 2026-10-06: a ranged request returns `206` with
> `access-control-allow-origin: *`.

> `AllowedHeaders: Range` and the exposed `Content-Range` are the two that carry
> the weight — `Trace-Artifacts.md` §5.3: "without them the fetcher cannot issue
> or verify a partial read, and lazy loading silently degrades into whole-file
> downloads." That degradation is silent and expensive: a trace container is
> tens of megabytes, and the page would fetch all of it to show one frame.
>
> **`Cross-Origin-Resource-Policy: cross-origin` is NOT part of this JSON.** CORS
> policy sets only the `Access-Control-*` family; CORP is an ordinary response
> header and belongs with the cache rules (`infra` #1626 / Step 2b), not here.
> §5.3 also records that it is "not load-bearing" for this site, because the site
> deliberately does not enable cross-origin isolation — so its absence is not a
> reason to hold the go-live, while `Range` very much is.
>
> Verify after publishing, since a wrong policy shows up as a browser-side
> failure at first debug rather than at publish:
>
> ```sh
> curl -sI -H 'Origin: https://blocktracer.org' -H 'Range: bytes=0-1' \
>   https://blocktracer.org/t/<any-trace-object> \
>   | grep -iE 'access-control-|content-range|^HTTP'
> # expect: HTTP/2 206, access-control-allow-origin, content-range
> ```


Per Deployment §6b.3 the **publisher's credential is not the release-deploy
credential** and **must not be able to sign**: it needs write to *one* R2 bucket and
nothing else — no zone rights.

1. Create an **R2 API token** (Cloudflare dashboard → R2 → Manage API Tokens) scoped
   to **Object Read & Write** on the **`blocktracer`** bucket only. It yields an
   Access Key ID and a Secret Access Key (S3-compatible).

2. Store it as **GitHub Actions secrets on the `metacraft-labs/blocktracer` repo**
   through the `secrets-metacraft-prod` root (rides the terraform-ci matrix; any
   secret change is plan-comment-apply). Add these entries to that root's managed
   secret set (payloads sealed via agenix, per its README):

   | Secret name             | Value                                                             |
   | ----------------------- | ----------------------------------------------------------------- |
   | `R2_ACCOUNT_ID`         | `803741d99690718276ea30950f690c46`                                |
   | `R2_BUCKET`             | `blocktracer`                                                     |
   | `R2_ENDPOINT`           | `https://803741d99690718276ea30950f690c46.r2.cloudflarestorage.com` |
   | `R2_ACCESS_KEY_ID`      | *(from the R2 token)*                                             |
   | `R2_SECRET_ACCESS_KEY`  | *(from the R2 token — sealed)*                                    |

   These become `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` at publish time (R2
   speaks S3 SigV4; the publisher's R2 backend is a thin `aws` wrapper).

---

## Step 3b — Rehearse the publish, against a coverage contract

> **Added 2026-09-29.** The corrections in Step 4 below came out of a
> **460,589-object** dress rehearsal. That does not scale — Aztec is the
> smallest chain this project targets — and "run a smaller one" is not the fix
> either: a **290-object** rehearsal of the demo tree passed on the same day,
> and the difference was not the 460,299 objects. It was that the small one had
> **one chain**, and one chain cannot overwrite another's registry row.

`blocktracer-rehearse` runs the publish path against a **coverage contract** and
**refuses** when a cell of it was never exercised, so a *partial* rehearsal can
be sufficient and a *full* one can still be insufficient:

```bash
just rehearse                                 # the CI gate: demo corpus + register
just rehearse-tree --tree client/dist         # the bytes about to be uploaded
just rehearse-tree --tree a --tree b --mode full --no-derive
```

It reaches no network and takes no credential — every store it writes to is a
directory it creates — so unlike the rest of this runbook it is safe for an
agent to run. A 106-object partial rehearsal of the 878-object `client/dist`
reproduces defect **(a)** below and finds one more: **eight objects of that
tree, including `404.html` and all of `replay-engine/`, are published by no
chain's cycle at all.**

See [`docs/Publish-Rehearsal.md`](./docs/Publish-Rehearsal.md) for the contract,
the selection argument and the measured evidence.

---

## Step 4 — Publish the tree (CI, or a one-off operator run)

> **CORRECTION (2026-09-28) — this step as written publishes the DEMO tree, and
> three things about a real publish are not in it.**
>
> `(cd client && just export)` renders the fake-data demo tree into `client/dist`.
> That is the right thing for proving the pipeline, and it is **not** the chain
> history. A real publish points `--tree` at an assembled chain tree instead. The
> three requirements below were each established by measurement, and the first is
> a data-loss defect:
>
> **(a) ALL CHAINS MUST BE INGESTED INTO ONE SHARED TREE.** `registry/**`
> classifies as `ocPointer` and pointers are `stUnconditional` — *always rewrite*.
> Each chain ingested into its own `--out` produces a tree whose registry holds
> only that chain, so **publishing the second chain erases the first from the
> registry**: its blocks stay in the bucket, fetchable by hash, and invisible.
> Measured at full scale on 2026-09-28. `ingest.nim`'s merge guard names this
> hazard in its own comment but merges *within* a tree, which is the wrong seam.
> A guard now refuses a registry that drops a chain the store already holds, and
> refuses any unknown global `stUnconditional` key.
>
> **(b) THE FINAL ASSEMBLY MUST CARRY `--probe-floor`.** Without it the published
> registry advertises `reach=windowed` with a floor a few dozen blocks below tip,
> over a store holding the whole chain — the data is present and the pointer lies.
> Note `--probe-floor` on a **re-merge silently does nothing**: `mergeSnapshots`
> takes the window from the range with the newest `capturedAt`, so a run that
> reuses covered ranges honours the flag, runs the probe, and keeps the old
> window. The fix is to add one additive 1-block range at the tip carrying the
> flag, so its snapshot is newest and its window wins. Do **not** use `--refetch`
> on an existing range for this: it strips that range's containers.
>
> **(c) PUBLISH-THEN-PRUNE IS NOT YET SAFE.** `ingest.nim`'s unguarded `readFile`
> of each container means a pruned range breaks any later re-ingest, and the
> whole-chain generation maps are rebuilt from the union on every publish — so
> pruning produces maps that quietly stop naming pruned ranges. Streaming needs
> ingest to tolerate an absent container whose object is already published first.
>
> **(d) THE DEPLOY MUST CARRY THE REPLAY ENGINE, OR THE DEBUGGER SHIPS BROKEN.**
> `replay-engine/**` — the engine's worker and its ~18 MB wasm — is **not emitted
> by `static_export`, by design**. `client/Justfile` says so: *"Not part of
> `export`, and not committed: it is 18 MB of build output from another
> repository, and a deploy decides for itself whether to carry it."*
>
> So a deploy must do one of two things, and the default does neither:
>
>   * run `just replay-engine` (in `client/`), which fetches the pinned engine
>     into `dist/replay-engine/` — the **recommended** mode, because
>     CodeTracer-Embed-SDK.md §5.1's `new Worker(scriptURL)` requires a
>     **same-origin** script, which is also why `ReplayEngineBase` defaults to
>     `/replay-engine/`; or
>   * build with `-d:replayEngineBase=<origin>` pointing at a host that already
>     serves it, accepting that same-origin constraint.
>
> Note the ordering hazard `client/Justfile` also records: the exporter **removes
> `dist/` and rewrites it**, so an engine staged before the export is destroyed by
> it. Stage the engine *after* exporting, before publishing.
>
> The symptom names nothing: every page renders, every data object resolves, the
> publish exits 0, and **every debugger session fails to load its engine**.
> Verified on 2026-09-29 — a full-corpus export contained no `replay-engine/`
> directory at all.
>
> Check before publishing: the tree must contain `replay-engine/worker.js` and
> `replay-engine/pkg/*.wasm`. A separate defect that *would* have dropped them
> even when present — `belongs` admitting site-root objects by an allowlist of
> three literal names — is fixed, and the publisher now refuses any object
> belonging to no chain rather than skipping it at exit 0.
>
> (`-d:hydrationBundle` is a **different** input — it installs the single
> `client/hydrate/hydrate.js` and has nothing to do with the engine assets.)
>
> **Measured throughput**, for planning: 460,589 objects published in ~15 minutes
> (~500 objects/sec), peak RSS 300–450 MB, the per-chain lease surviving the whole
> run, and a second run reporting `content uploaded: 0` in 40 s — the idempotency
> contract holding at scale, not just on a sample.


The publisher is idempotent and resumable, so it is safe to run repeatedly and safe
to interrupt. It uploads only the delta and flips `current.json` last.

### One-off operator run (first go-live)

```bash
# From a checkout of metacraft-labs/blocktracer, inside `nix develop`.
export AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=auto            # R2 ignores region but the CLI wants one

# 1. Render the demo tree (data plane + client) into dist/.
(cd client && just export)

# 2. Publish it to R2 — content first, current.json last, per-chain lease held.
nim c --hints:off -d:release -o:blocktracer-publish src/blocktracer_publish.nim
./blocktracer-publish \
  --tree client/dist \
  --backend r2 \
  --bucket "$R2_BUCKET" \
  --endpoint "$R2_ENDPOINT"
```

Expected on first run: a few dozen content objects uploaded, `pointer flipped: true`,
`published generation: 1`. A second run reports `content uploaded: 0` — the
idempotency contract, now against the live bucket.

### CI (continuous / on release)

A workflow on `metacraft-labs/blocktracer` maps the secrets to the AWS env and runs
the same two commands. Sketch (`.github/workflows/publish.yml`):

```yaml
env:
  AWS_ACCESS_KEY_ID:     ${{ secrets.R2_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
  AWS_DEFAULT_REGION:    auto
steps:
  - uses: actions/checkout@v4
  - run: nix develop -c bash -c '(cd client && just export)'
  - run: nix develop -c bash -c '
      nim c --hints:off -d:release -o:blocktracer-publish src/blocktracer_publish.nim &&
      ./blocktracer-publish --tree client/dist --backend r2
        --bucket "${{ secrets.R2_BUCKET }}" --endpoint "${{ secrets.R2_ENDPOINT }}"'
```

The per-chain single-writer lease means two overlapping CI runs are safe: the second
is refused (`chain 'aztec' is locked by another publisher`) rather than corrupting a
cycle. The lease lives under a reserved `_leases/` prefix in the bucket, outside the
browser-visible namespace.

---

## Running the steps: `scripts/go-live.sh`

**Added 2026-09-30.** The steps above are individually easy and collectively
ordered, and this runbook numbers the apex bind **Step 2** and the publish
**Step 4** — so read top to bottom it points a live apex at an empty bucket.
The dated correction at Step 2 says so; `scripts/go-live.sh` makes it
unnecessary, by running them in the one safe order and making the others
unreachable rather than discouraged: **step 5 cannot execute unless step 4
verified every chain in the registry.**

```sh
# Rehearse the whole sequence against a local store. No credential, no
# network, no bucket — and it refuses --bind, having no apex to move.
scripts/go-live.sh --tree DIR --rehearse /tmp/gl-store

# The real thing.
export R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=…
scripts/go-live.sh --tree DIR --ledgers .chain-state --yes --bind
```

Credentials come from the environment or an interactive prompt, never from
argv, which is world-readable in `ps`; nothing prints one.

Dry run is the default. `--yes` mutates. `--bind` is additionally opt-in and
needs `CF_ADMIN_TOKEN`, which is deliberately not the publisher credential —
per Deployment §6b.3 that one must carry no zone rights.

## What "LIVE" means, and how to confirm it

After Steps 1–4:

```bash
curl -sI  https://blocktracer.org/                       # 200, the home page
curl -sS  https://blocktracer.org/d/aztec/current.json   # {"generation":"1",...}
curl -sS  https://blocktracer.org/registry/chains.v1.json
# Walk one entity end to end:
curl -sSI https://blocktracer.org/aztec/tx/<txhash>/      # a pre-rendered entry page
```

`blocktracer.org` now serves the demo explorer over the fake Aztec data plane, and a
re-run of Step 4 publishes any new generation as a delta with a single atomic pointer
flip. **This is the campaign's "fake-data site LIVE" bound** — reached the moment
Step 4's first publish completes against the live bucket bound to the zone.

### The curls above prove the site answers. They do not prove the data arrived.

**Added 2026-09-30.** Four requests against a CDN cannot distinguish a complete
tree from a truncated one — every path that is present returns `200` in both.
The check that can tell the difference is `blocktracer-verify-published`, which
is read-only by construction (it holds a `verify/source.Source`, which has no
write operation) and therefore safe to run against production repeatedly.

Run it **once per chain**, because `--ledger` takes one ledger and each ledger
names one chain. Two runs is the whole of it:

```bash
# inside `nix develop`, from a checkout of this repo
nimble build -d:release blocktracer-verify-published

for c in aztec aztec-testnet; do
  ./blocktracer-verify-published \
    --url https://blocktracer.org \
    --tree "$TREE" \
    --expect-chain aztec --expect-chain aztec-testnet \
    --expect-chain aztec-testnet-frames \
    --ledger ".chain-state/$c/coverage.json"
done
```

`$TREE` is the tree that was published — it supplies the expectation from
*outside* the instance, which is the point: it is what makes `REGISTRY` and
`CENSUS` run at all, and it compares sampled objects byte for byte.

Exit codes: `0` clean, `1` a finding, `2` usage, `3` the instrument voided the
run. **Do not read `UNRUNNABLE` as a pass** — it means the check did not
happen, and each one prints why.

Measured against the staged go-live tree on 2026-09-30, before any publish, so
that the post-publish run has a known-good baseline rather than being its own
first test:

```
PASS  CENSUS — store holds 882642 object(s); per class, local == store
         ocEntryPage 385731 · ocContent 374374 · ocGenMap 86284
         ocTraceContainer 18093 · ocTraceManifest 18093 · +6 classes
PASS  LEDGER — chain 'aztec':         all 102690 heights — exhaustive
PASS  LEDGER — chain 'aztec-testnet': all  99091 heights — exhaustive
PASS  RANGE  — 865 heights matched by identity, all byte-identical
```

Two things only the **production** run can establish, because a local directory
serves no response headers and `CACHE` reports `UNRUNNABLE` against one:

- the cache contract of §4.1 / `Publishing-And-Caching.md` §4 actually in force;
- range requests (`206`) surviving the chosen topology.

Note for the `curl` block above: after the first full-history publish the
generation ids are `raztec00001` and `rtestnet0001`, not `"1"` — `"1"` is what
the pre-backfill site serves today.

The credentialed apply list, in one line each:

1. **R2 bucket** — `blocktracer` added to `data.json` `r2_buckets` (infra PR, merge-applied).
2. **DNS / custom domain** — bind `blocktracer.org` (zone `3e380c5c…`) to the bucket via the R2 custom-domain API (operator; provider can't import it yet).
3. **Secrets** — R2 write-only token stored as repo Actions secrets through `secrets-metacraft-prod`.
4. **Publish** — `blocktracer-publish --backend r2 …` from CI (or once by an operator).
