# Logpush job: forward Gateway HTTP logs (which carry DLPProfiles) to the Worker.
#
# The Worker does the DLP filtering (keeps only rows where DLPProfiles is
# non-empty, action-agnostic so BLOCKED and ALLOWED matches both notify), so the
# job ships the relevant fields and lets the Worker decide. If your account has
# high Gateway volume and you want to pre-filter at Logpush, add a `filter`
# expression — but note array-field filtering on DLPProfiles is limited, which is
# why filtering lives in the Worker.
#
# destination_conf appends the shared secret as ?token= so only Logpush (not a
# random POST) is accepted by the Worker.

locals {
  logpush_ready = var.manage_logpush
  logpush_dest  = local.logpush_ready ? "${local.effective_worker_endpoint}?token=${local.shared_secret}" : ""
}

resource "cloudflare_logpush_job" "dlp" {
  count            = local.logpush_ready ? 1 : 0
  account_id       = var.cloudflare_account_id
  name             = var.logpush_job_name
  dataset          = "gateway_http"
  destination_conf = local.logpush_dest
  enabled          = true
  kind             = ""

  output_options = {
    output_type      = "ndjson"
    timestamp_format = "rfc3339"
    field_names = [
      "Datetime",
      "Email",
      "UserID",
      "DeviceName",
      "HTTPHost",
      "URL",
      "Action",
      "PolicyName",
      "DLPProfiles",
    ]
  }

  depends_on = [
    cloudflare_workers_script.notifier,
    cloudflare_workers_script_subdomain.notifier,
  ]
}
