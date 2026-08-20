# Single-apply URL derivation:
#   1. Enable the Worker's workers.dev route (so it's reachable by Logpush).
#   2. Look up the account's workers.dev subdomain via the API.
#   3. Build the Worker URL — used as the Logpush destination — so the operator
#      never has to hand-copy it into terraform.tfvars.
#
# If you set worker_endpoint explicitly (e.g. a custom domain), that wins and
# this derivation is skipped.

# 1. Publish the workers.dev route for the script.
resource "cloudflare_workers_script_subdomain" "notifier" {
  account_id       = var.cloudflare_account_id
  script_name      = var.worker_name
  enabled          = true
  previews_enabled = false
  depends_on       = [cloudflare_workers_script.notifier]
}

# 2. Fetch the account's workers.dev subdomain (e.g. "rm-815").
data "external" "workers_subdomain" {
  program = ["bash", "${path.module}/scripts/workers_subdomain.sh"]
  query = {
    account_id = var.cloudflare_account_id
    api_token  = var.cloudflare_api_token
  }
}

locals {
  # Explicit worker_endpoint wins; otherwise derive the workers.dev URL.
  derived_worker_url        = "https://${var.worker_name}.${data.external.workers_subdomain.result.subdomain}.workers.dev"
  effective_worker_endpoint = var.worker_endpoint != "" ? var.worker_endpoint : local.derived_worker_url
}
