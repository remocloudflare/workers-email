locals {
  # In "log" mode we deploy the Worker WITHOUT the send_email binding, so it can
  # be verified end-to-end (Worker + Logpush + DLP filtering) with no email
  # onboarding. In "send" mode the EMAIL binding is attached.
  email_binding = var.notify_mode == "send" ? [{
    name                          = "EMAIL"
    type                          = "send_email"
    allowed_destination_addresses = var.notification_recipients
  }] : []

  config_bindings = [
    { name = "NOTIFY_MODE", type = "plain_text", text = var.notify_mode },
    { name = "FROM_ADDRESS", type = "plain_text", text = var.from_address },
    { name = "FROM_NAME", type = "plain_text", text = var.from_name },
    { name = "RECIPIENTS", type = "plain_text", text = local.recipients_csv },
    { name = "ACCOUNT_NAME", type = "plain_text", text = var.account_label },
    { name = "SHARED_SECRET", type = "secret_text", text = local.shared_secret },
  ]
}

resource "cloudflare_workers_script" "notifier" {
  account_id     = var.cloudflare_account_id
  script_name    = var.worker_name
  content_file   = local.bundle_js
  content_sha256 = fileexists(local.bundle_js) ? filesha256(local.bundle_js) : local.placeholder
  main_module    = "index.js"

  compatibility_date  = var.compatibility_date
  compatibility_flags = ["nodejs_compat"]

  bindings = concat(local.email_binding, local.config_bindings)

  observability = { enabled = true }

  depends_on = [null_resource.build]
}
