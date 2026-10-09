#!/usr/bin/env bash
#
# go-live.sh — run DEPLOY.md's four operator steps in the ONE order that does
# not take the site down, and refuse every other order.
#
# WHY THIS IS A SCRIPT AND NOT A CHECKLIST. The steps are individually easy and
# collectively ordered, and the ordering constraint is the whole risk:
#
#   infra terraform/cloudflare/metacraft-prod/README.md
#     "…creates the proxied apex record pointing at R2 and Pages stops serving
#      blocktracer.org the moment it lands. The order is: create this bucket ->
#      publish the tree into it (Step 4) -> only then bind the domain. Binding
#      an empty bucket takes the site down."
#
# DEPLOY.md numbers the bind Step 2 and the publish Step 4, for historical
# reasons, so the runbook read top-to-bottom does exactly the wrong thing. A
# correction note now says so, but a note is something a tired operator reads
# past at the one moment it matters. Here the bind is UNREACHABLE until a
# publish has happened and a verifier has passed — not discouraged, unreachable.
#
# WHAT IT NEVER DOES. It never prints a credential, never writes one to disk,
# and never takes one as an argument (argv is world-readable in ps). Secrets
# come from the environment or an interactive prompt, and the script only ever
# tests whether they are non-empty.
#
# Usage:
#   scripts/go-live.sh --tree DIR                 # dry run: say what would happen
#   scripts/go-live.sh --tree DIR --yes           # CORS + publish + verify
#   scripts/go-live.sh --tree DIR --yes --bind    # …and bind the apex at the end
#   scripts/go-live.sh --tree DIR --rehearse OUT  # the SAME sequence, local store
#   scripts/go-live.sh --tree DIR --yes --refresh # supersede objects fixed since
#
# REFRESH exists because the publisher's default is "present => skip", and that
# default cannot correct anything. `d/{chain}/block/{hash}.json` is keyed by the
# BLOCK's hash while its bytes are this producer's RENDERING of that block, so
# fixing a field in `ingest.nim` does not move the key — and under key-existence
# alone the corrected object reaches a store that already holds the wrong one
# NEVER, not merely late (publisher.nim, `refreshContent`). Pass `--refresh`
# after a producer fix. It does not extend to `/t/**`: a trace container whose
# bytes moved under fixed input is a non-deterministic recorder, and the
# publisher refuses rather than overwriting it.
#
# REHEARSE exists because a dry run proves the ordering and nothing else: it
# never executes a publish or a verification, so the apply path ships untested
# and the first time it runs is against production. `--rehearse` runs every
# step for real against a local directory — no credential, no network, no
# bucket — so the code that will touch production has been executed before it
# does. It refuses `--bind` by construction: there is no apex to move.
#
# Credentials, from the environment, never from argv:
#   R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY   object read+write on this bucket
#   CF_ADMIN_TOKEN                            ONLY for --bind (zone + R2 rights)
#
# Exit codes:  0 done · 1 a step refused · 2 usage · 3 the tree is not publishable
set -euo pipefail

ACCOUNT_ID="${R2_ACCOUNT_ID:-803741d99690718276ea30950f690c46}"
BUCKET="${R2_BUCKET:-blocktracer}"
ENDPOINT="${R2_ENDPOINT:-https://${ACCOUNT_ID}.r2.cloudflarestorage.com}"
ZONE_ID="${CF_ZONE_ID:-3e380c5c250ae708bfaf2b38ceed750a}"
DOMAIN="${BLOCKTRACER_DOMAIN:-blocktracer.org}"

TREE="" ; APPLY=0 ; BIND=0 ; MISSING=0 ; REHEARSE="" ; REFRESH=0 ; LEDGER_DIR="${LEDGER_DIR:-.chain-state}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree)    TREE="${2:?--tree needs a directory}"; shift 2 ;;
    --ledgers) LEDGER_DIR="${2:?--ledgers needs a directory}"; shift 2 ;;
    --yes)     APPLY=1; shift ;;
    --rehearse) REHEARSE="${2:?--rehearse needs an output directory}"; APPLY=1; shift 2 ;;
    --refresh) REFRESH=1; shift ;;
    --bind)    BIND=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TREE" ]] || { echo "go-live: --tree is required" >&2; exit 2; }
if [[ -n "$REHEARSE" && "$BIND" -eq 1 ]]; then
  echo "go-live: --rehearse cannot --bind; a rehearsal has no apex to move" >&2; exit 2
fi

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
no()   { printf '   REFUSE  %s\n' "$*" >&2; }
plan() { printf '   would  %s\n' "$*"; }

# ── Step 0. Is the tree publishable at all? ─────────────────────────────────
#
# Checked BEFORE any credential is touched, because the failure that costs the
# most is a half-published tree: the publisher writes content first and flips
# current.json last, but a tree that was wrong to begin with flips a pointer at
# content nobody verified.
say "Step 0 — is the tree publishable?"
[[ -d "$TREE" ]]                         || { no "no such tree: $TREE"; exit 3; }
[[ -f "$TREE/index.html" ]]              || { no "$TREE has no index.html — this is a build dir, not a publishable tree"; exit 3; }
[[ -f "$TREE/registry/chains.v1.json" ]] || { no "$TREE has no registry/chains.v1.json"; exit 3; }
objects=$(find "$TREE" -type f | wc -l | tr -d ' ')
# The floor exists to stop a stub reaching PRODUCTION. A rehearsal writes to a
# local directory, and refusing a small tree there would make the apply path
# untestable without 14 GB of disk — which is how an apply path ships untested.
if [[ -z "$REHEARSE" ]]; then
  [[ "$objects" -gt 1000 ]] || { no "$TREE holds only $objects object(s); refusing to treat that as a full tree"; exit 3; }
fi
ok "$objects objects, index.html and registry present"

chains=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["chains"])))' \
          "$TREE/registry/chains.v1.json")
ok "chains in the registry: $chains"

# ── Step 1. Credentials — presence only, never a value ──────────────────────
say "Step 1 — credentials"
if [[ -n "$REHEARSE" ]]; then
  ok "rehearsal: no credential is used, and none is asked for"
elif [[ -z "${R2_ACCESS_KEY_ID:-}" || -z "${R2_SECRET_ACCESS_KEY:-}" ]]; then
  if [[ "$APPLY" -eq 1 ]]; then
    read -r -p  "   R2 Access Key ID: " R2_ACCESS_KEY_ID
    read -r -s -p "   R2 Secret Access Key (not echoed): " R2_SECRET_ACCESS_KEY; echo
  else
    plan "prompt for R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY"
  fi
fi
if [[ "$APPLY" -eq 1 && -z "$REHEARSE" ]]; then
  [[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" ]] \
    || { no "empty credential. An empty key degrades into an anonymous request that 403s like a network fault"; exit 1; }
  ok "both credential fields are non-empty (values never printed)"
fi
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}" \
       AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}" \
       AWS_DEFAULT_REGION=auto

# ── Step 2. CORS, BEFORE any artifact exists ────────────────────────────────
#
# Trace-Artifacts.md §5.3. `Range` and the exposed `Content-Range` are the pair
# that matters: without them lazy loading degrades into whole-file downloads of
# tens-of-megabyte containers, with no error anywhere — the most expensive kind
# of silence. CORP is NOT set here; it is a plain response header and belongs
# with the cache rules, not in a CORS policy.
say "Step 2 — bucket CORS (before any artifact is published)"
cors_json=$(mktemp); trap 'rm -f "$cors_json"' EXIT
cat > "$cors_json" <<'JSON'
{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","HEAD"],
 "AllowedHeaders":["Range"],
 "ExposeHeaders":["Content-Range","Content-Length","ETag"],
 "MaxAgeSeconds":86400}]}
JSON
if [[ -n "$REHEARSE" ]]; then
  plan "rehearsal: CORS is a bucket property; a local store has none"
elif [[ "$APPLY" -eq 1 ]]; then
  aws s3api put-bucket-cors --bucket "$BUCKET" --endpoint-url "$ENDPOINT" \
      --cors-configuration "file://$cors_json" \
    || { no "could not set CORS on $BUCKET"; exit 1; }
  aws s3api get-bucket-cors --bucket "$BUCKET" --endpoint-url "$ENDPOINT" \
      | grep -q 'Range' \
    || { no "CORS read-back does not mention Range — the policy did not take"; exit 1; }
  ok "CORS applied and read back with Range present"
else
  plan "put-bucket-cors on $BUCKET (AllowedHeaders: Range, expose Content-Range)"
fi

# ── Step 3. Publish ─────────────────────────────────────────────────────────
say "Step 3 — publish $objects objects to r2://$BUCKET"
publisher=$(command -v blocktracer-publish || echo ./blocktracer-publish)
# A missing tool is fatal to an APPLY and merely reported in a preview: a dry
# run whose whole point is to show steps 4 and 5 must not stop at step 3.
if [[ ! -x "$publisher" ]]; then
  if [[ "$APPLY" -eq 1 ]]; then no "blocktracer-publish not found; build it first"; exit 1
  else plan "MISSING: blocktracer-publish (build before --yes)"; MISSING=$((MISSING+1)); fi
fi
if [[ -n "$REHEARSE" ]]; then
  mkdir -p "$REHEARSE"
  "$publisher" --tree "$TREE" --backend local --dest "$REHEARSE" \
    || { no "rehearsal publish failed — this is the apply path, and it is broken"; exit 1; }
  ok "rehearsal publish completed into $REHEARSE"
elif [[ "$APPLY" -eq 1 ]]; then
  pub_args=(--tree "$TREE" --backend s3 --bucket "$BUCKET" --endpoint "$ENDPOINT")
  [[ "$REFRESH" -eq 1 ]] && pub_args+=(--refresh)
  "$publisher" "${pub_args[@]}" \
    || { no "publish failed — NOT binding the apex; the live site is untouched"; exit 1; }
  ok "publish completed"
else
  plan "$publisher --tree $TREE --backend s3 --bucket $BUCKET --endpoint $ENDPOINT"
fi

# ── Step 4. Verify, per chain, BEFORE the apex moves ────────────────────────
#
# --ledger takes ONE ledger and each ledger names ONE chain, so a two-chain
# instance needs two runs; one run reports "exhaustive" about one chain and
# says nothing about the other (see blocktracer#40). Iterating the registry's
# own chain list is what keeps that from being a thing somebody remembers.
say "Step 4 — verify the published tree, one run per chain"
verifier=$(command -v blocktracer-verify-published || echo ./blocktracer-verify-published)
verified=0
for c in $chains; do
  ledger="$LEDGER_DIR/$c/coverage.json"
  if [[ -n "$REHEARSE" ]]; then args=(--backend local --dest "$REHEARSE" --tree "$TREE" --allow-unrunnable CACHE)
  else args=(--url "https://$DOMAIN" --tree "$TREE"); fi
  for e in $chains; do args+=(--expect-chain "$e"); done
  if [[ -f "$ledger" ]]; then
    args+=(--ledger "$ledger")
  else
    # No ledger for this chain, so the exhaustive whole-range check cannot run
    # and the verifier exits non-zero for an UNRUNNABLE check — correctly, since
    # a check that did not happen is not a pass. Declaring it allowed keeps the
    # run honest AND finishable: the verifier still prints
    # `UNRUNNABLE ALLOWED (by request): LEDGER`, so the reduced coverage is in
    # the output rather than in somebody's head.
    #
    # Found by `--rehearse`: without this the bind is unreachable for any chain
    # that has no ledger, and `aztec-testnet-frames` is exactly that, so the
    # real go-live would have refused to bind and never said why.
    args+=(--allow-unrunnable LEDGER)
    printf '   note  %s has no ledger at %s — range is SAMPLED, not exhaustive\n' "$c" "$ledger"
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    [[ -x "$verifier" ]] || { no "blocktracer-verify-published not found; cannot verify, so not binding"; exit 1; }
    if "$verifier" "${args[@]}"; then ok "verified: $c"; verified=$((verified+1))
    else no "verification failed for $c — NOT binding the apex"; exit 1; fi
  else
    [[ -x "$verifier" ]] || { plan "MISSING: blocktracer-verify-published"; MISSING=$((MISSING+1)); }
    plan "$verifier ${args[*]}"
  fi
done

# ── Step 5. Bind the apex — LAST, and only if step 4 actually passed ────────
say "Step 5 — bind $DOMAIN to r2://$BUCKET"
if [[ "$BIND" -eq 0 ]]; then
  plan "skipped: pass --bind once you are satisfied with step 4"
  [[ "$MISSING" -eq 0 ]] || { printf '\n   %s tool(s) missing — build them before --yes\n' "$MISSING"; exit 1; }
  exit 0
fi
if [[ "$APPLY" -eq 0 ]]; then
  plan "POST .../r2/buckets/$BUCKET/custom_domains  (domain=$DOMAIN zone=$ZONE_ID)"
  # Same accounting as the no-bind path: a preview that ends `exit 0` while a
  # required tool is absent is the silent pass this script exists to avoid.
  [[ "$MISSING" -eq 0 ]] || { printf '\n   %s tool(s) missing — build them before --yes\n' "$MISSING"; exit 1; }
  exit 0
fi
# Structural, not advisory: nothing below can run unless every chain verified.
[[ "$verified" -gt 0 && "$verified" -eq "$(wc -w <<<"$chains")" ]] \
  || { no "only $verified chain(s) verified; the bind is unreachable until all of them are"; exit 1; }
[[ -n "${CF_ADMIN_TOKEN:-}" ]] \
  || { no "CF_ADMIN_TOKEN is not set; the bind needs zone rights the publisher token must not have"; exit 1; }
curl -fsS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/r2/buckets/$BUCKET/custom_domains" \
  -H "Authorization: Bearer $CF_ADMIN_TOKEN" -H "Content-Type: application/json" \
  --data "{\"domain\":\"$DOMAIN\",\"zoneId\":\"$ZONE_ID\",\"enabled\":true,\"minTLS\":\"1.2\"}" \
  >/dev/null || { no "custom-domain bind failed; Pages is still serving $DOMAIN"; exit 1; }
ok "bound. $DOMAIN now serves from R2 — it was serving from Pages until this moment"
