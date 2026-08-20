#!/usr/bin/env bash
#
# configure-ai-gateway-dlp.sh — make an AI Gateway's DLP config reproducible.
#
# WHY THIS EXISTS: the cloudflare/cloudflare v5 Terraform provider does NOT expose
# AI Gateway DLP (the gateway `.dlp` block) or predefined-profile entry toggles.
# Both are dashboard/REST-API only. This script codifies what we'd otherwise click.
#
# What it does, idempotently:
#   1. Snapshots the current gateway config to <gateway>.snapshot.json (restore point).
#   2. Enables detection ENTRIES on each requested predefined profile
#      (a profile with 0 enabled entries detects nothing — attaching it is not enough).
#   3. MERGE-SAFELY sets the gateway's .dlp policy (GET full object, set only .dlp,
#      PUT the whole thing back) so it can't wipe logpush/rate-limiting/etc.
#
# GOTCHAS baked in (learned the hard way — see cloudflare-ai-gateway-dlp skill):
#   - predefined entry toggle endpoint is /dlp/profiles/predefined/<id> (PUT);
#     plain /dlp/profiles/<id> returns 405.
#   - profile/entry changes take ~20-30s to propagate before they block.
#   - a partial gateway PUT that omits .dlp sets it to null (disables blocking).
#
# Requirements: bash, curl, python3, and CLOUDFLARE_API_TOKEN + account id.
# Token scopes: AI Gateway:Edit + DLP (Account · DLP:Edit).
#
# Usage:
#   export CLOUDFLARE_API_TOKEN=...    # or it reads terraform/terraform.tfvars
#   ./configure-ai-gateway-dlp.sh <account_id> <gateway_name>
#
# Edit PROFILE_IDS below for the coverage you want (names are comments).

set -euo pipefail

ACCT="${1:?usage: $0 <account_id> <gateway_name>}"
GW="${2:?usage: $0 <account_id> <gateway_name>}"

# Resolve token: env var, else terraform.tfvars next to this script's repo.
TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  TFVARS="$(dirname "$0")/terraform/terraform.tfvars"
  [ -f "$TFVARS" ] && TOKEN="$(grep -E '^\s*cloudflare_api_token' "$TFVARS" | sed -E 's/.*=\s*"([^"]+)".*/\1/')"
fi
[ -n "$TOKEN" ] || { echo "No CLOUDFLARE_API_TOKEN (env or terraform.tfvars)"; exit 1; }

API="https://api.cloudflare.com/client/v4/accounts/$ACCT"

# --- Coverage: predefined profile IDs to enable + attach. Edit as needed. ---
# Get IDs for your account: curl .../dlp/profiles | jq '.result[]|{id,name,type}'
PROFILE_IDS=(
  "d658f520-6ecb-4a34-a725-ba37243c2d28"  # Social Security, Insurance, Tax, and Identifier Numbers
  "c8932cc4-3312-4152-8041-f3f257122dc4"  # Credentials and Secrets
  "0e1a3432-c838-4b28-b13e-2958047fad7c"  # Source Code
)
# Custom profiles (already have their own entries; just attach, don't toggle):
CUSTOM_PROFILE_IDS=(
  "4cb6ff3a-571a-431f-bdaa-922a7b3df9f4"  # remo-Credit Card (loose formatting)
)

echo "==> 1. Snapshot current gateway config"
curl -s -H "Authorization: Bearer $TOKEN" "$API/ai-gateway/gateways/$GW" \
  | python3 -c "import sys,json; json.dump(json.load(sys.stdin)['result'], open('$GW.snapshot.json','w'), indent=1)"
echo "    saved $GW.snapshot.json"

echo "==> 2. Enable detection entries on predefined profiles"
for PID in "${PROFILE_IDS[@]}"; do
  # Fetch entries, enable all, PUT to the PREDEFINED endpoint.
  curl -s -H "Authorization: Bearer $TOKEN" "$API/dlp/profiles/$PID" > "/tmp/prof-$PID.json"
  BODY="$(python3 -c "
import json
d=json.load(open('/tmp/prof-$PID.json'))['result']
ents=d.get('entries') or []
print(json.dumps({'entries':[{'id':e['id'],'enabled':True} for e in ents]}))
")"
  RESULT="$(curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "$API/dlp/profiles/predefined/$PID" --data "$BODY" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if d.get('success') else 'FAIL '+json.dumps(d.get('errors')))")"
  NAME="$(python3 -c "import json; print(json.load(open('/tmp/prof-$PID.json'))['result'].get('name'))")"
  echo "    $NAME: $RESULT"
done

echo "==> 3. Merge-safe set of gateway .dlp policy (all profiles, BLOCK, REQUEST)"
ALL_IDS="$(printf '%s\n' "${PROFILE_IDS[@]}" "${CUSTOM_PROFILE_IDS[@]}")"
python3 - "$TOKEN" "$API" "$GW" "$ALL_IDS" <<'PY'
import json,sys,urllib.request
tok,api,gw,ids_raw=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
ids=[x for x in ids_raw.split("\n") if x.strip()]
base=f"{api}/ai-gateway/gateways/{gw}"
def call(method,url,body=None):
    data=json.dumps(body).encode() if body is not None else None
    r=urllib.request.Request(url,data=data,method=method,
        headers={"Authorization":f"Bearer {tok}","Content-Type":"application/json"})
    try: return json.load(urllib.request.urlopen(r))
    except urllib.error.HTTPError as e: return {"success":False,"http":e.code,"err":e.read().decode()[:400]}
cur=call("GET",base)["result"]
cur["dlp"]={"enabled":True,"policies":[{"id":"Policy 1","enabled":True,
    "action":"BLOCK","check":["REQUEST"],"profiles":ids}]}
writable=["cache_ttl","cache_invalidate_on_update","collect_logs","rate_limiting_interval",
          "rate_limiting_limit","authentication","logpush","logpush_public_key","dlp"]
body={k:cur[k] for k in writable if k in cur and cur[k] is not None}
r=call("PUT",base,body)
if r.get("success"):
    p=r["result"]["dlp"]["policies"][0]
    print(f"    OK: action={p['action']} check={p['check']} #profiles={len(p['profiles'])} logpush={r['result'].get('logpush')}")
else:
    print("    FAIL:",r.get("http"),r.get("err")); sys.exit(1)
PY

echo "==> Done. Wait ~20-30s for propagation, then test:"
echo "    (a large code block / real secret / SSN should return HTTP 424)"
