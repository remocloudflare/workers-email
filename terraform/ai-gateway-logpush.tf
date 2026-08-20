# AI Gateway Logpush job (dataset: ai_gateway_events) → the Worker.
#
# A DLP block in AI Gateway surfaces as StatusCode 424. The Worker detects the
# ai_gateway_events shape and alerts on 424. The matched DLP profile + prompt
# content live in the ENCRYPTED Metadata/RequestBody (hybrid RSA+AES) — alerting
# here uses only the plaintext StatusCode; decryption is a future enhancement.
#
# NOTE: as of cloudflare/cloudflare v5.x the provider's cloudflare_logpush_job
# `dataset` enum does NOT include "ai_gateway_events" (the REST API DOES accept
# it). So this job is created via the API through a null_resource rather than the
# native resource. Revisit once the provider adds the dataset.
#
# Prereqs (configured out-of-band / see README):
#   - Gateway has collect_logs = true
#   - Gateway has logpush = true AND a logpush_public_key uploaded
# These AI-Gateway gateway-level settings are not managed by the v5 provider's
# ai_gateway resource.

locals {
  aig_logpush_ready = var.enable_ai_gateway && var.ai_gateway_name != ""
  aig_logpush_dest  = local.aig_logpush_ready ? "${local.effective_worker_endpoint}?token=${local.shared_secret}" : ""
}

resource "null_resource" "ai_gateway_logpush" {
  count = local.aig_logpush_ready ? 1 : 0

  triggers = {
    dest    = local.aig_logpush_dest
    name    = var.ai_gateway_logpush_job_name
    account = var.cloudflare_account_id
  }

  # Create (or recreate) the AI Gateway Logpush job via the REST API.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CF_TOKEN = var.cloudflare_api_token
      ACCT     = var.cloudflare_account_id
      JOBNAME  = var.ai_gateway_logpush_job_name
      DEST     = local.aig_logpush_dest
    }
    command = <<-EOT
      set -euo pipefail
      # delete any existing job with the same name (idempotent create)
      existing=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
        "https://api.cloudflare.com/client/v4/accounts/$ACCT/logpush/jobs" \
        | python3 -c "import sys,json;   [print(j['id']) for j in (json.load(sys.stdin).get('result') or []) if j.get('name')=='$JOBNAME']")
      for id in $existing; do
        curl -s -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
          "https://api.cloudflare.com/client/v4/accounts/$ACCT/logpush/jobs/$id" >/dev/null
      done
      curl -s -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/accounts/$ACCT/logpush/jobs" \
        --data "$(python3 - <<PY
import json,os
print(json.dumps({
  "name": os.environ["JOBNAME"],
  "dataset": "ai_gateway_events",
  "destination_conf": os.environ["DEST"],
  "enabled": True,
  "output_options": {
    "output_type": "ndjson",
    "timestamp_format": "rfc3339",
    "field_names": ["Datetime","Gateway","Provider","Model","Endpoint","StatusCode","Cached","RateLimited"]
  }
}))
PY
)" | python3 -c "import sys,json; d=json.load(sys.stdin); print('AI Gateway Logpush job:', 'OK id='+str(d['result']['id']) if d.get('success') else 'FAILED '+json.dumps(d.get('errors')))"
    EOT
  }

  # Best-effort delete on destroy.
  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CF_TOKEN = self.triggers.account # placeholder; token not available on destroy
      ACCT     = self.triggers.account
      JOBNAME  = self.triggers.name
    }
    command = "echo 'On destroy, remove the AI Gateway Logpush job named '$JOBNAME' via API/dashboard (token not available in destroy provisioner).'"
  }

  depends_on = [cloudflare_workers_script.notifier]
}
