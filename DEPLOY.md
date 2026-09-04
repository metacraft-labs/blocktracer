# DEPLOY — an unexecuted plan for serving blocktracer.org from R2

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

The zone `blocktracer.org` already exists in the root. What remains is to serve the
bucket at the apex and turn on the CDN.

**Terraform cannot do this in provider v5** — `cloudflare_r2_custom_domain` has no
import support, the same wall `default.nix` documents for the codetracer domains. So
this one binding is done by a production operator via the Cloudflare API/dashboard
and then recorded, not left as drift:

```bash
# Operator, with a token scoped to R2 + DNS on this account.
curl -sS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/803741d99690718276ea30950f690c46/r2/buckets/blocktracer/custom_domains" \
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

## Step 4 — Publish the fake-data tree (CI, or a one-off operator run)

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

The credentialed apply list, in one line each:

1. **R2 bucket** — `blocktracer` added to `data.json` `r2_buckets` (infra PR, merge-applied).
2. **DNS / custom domain** — bind `blocktracer.org` (zone `3e380c5c…`) to the bucket via the R2 custom-domain API (operator; provider can't import it yet).
3. **Secrets** — R2 write-only token stored as repo Actions secrets through `secrets-metacraft-prod`.
4. **Publish** — `blocktracer-publish --backend r2 …` from CI (or once by an operator).
