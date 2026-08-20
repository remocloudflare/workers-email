#!/usr/bin/env bash
# Returns the account's workers.dev subdomain as JSON for the `external` data
# source: {"subdomain":"<name>"}. Terraform passes {account_id, api_token} as
# JSON on stdin.
set -euo pipefail

INPUT="$(cat)"

ACCT="$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["account_id"])')"
TOKEN="$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["api_token"])')"

sub="$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCT/workers/subdomain" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("result",{}).get("subdomain",""))')"

printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.dumps({'subdomain': '$sub'}))"
