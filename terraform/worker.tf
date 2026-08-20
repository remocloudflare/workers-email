locals {
  # The Cloudflare send_email binding is attached ONLY in cf_email mode.
  email_binding = var.notify_mode == "cf_email" ? [{
    name                          = "EMAIL"
    type                          = "send_email"
    allowed_destination_addresses = var.notification_recipients
  }] : []

  # SMTP config bindings are attached ONLY in smtp mode.
  smtp_bindings = var.notify_mode == "smtp" ? concat(
    [
      { name = "SMTP_HOST", type = "plain_text", text = var.smtp_host },
      { name = "SMTP_PORT", type = "plain_text", text = tostring(var.smtp_port) },
      { name = "SMTP_TLS", type = "plain_text", text = var.smtp_tls },
      { name = "SMTP_USER", type = "plain_text", text = var.smtp_user },
      { name = "SMTP_EHLO", type = "plain_text", text = var.smtp_ehlo },
    ],
    var.smtp_pass != "" ? [{ name = "SMTP_PASS", type = "secret_text", text = var.smtp_pass }] : []
  ) : []

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

  bindings = concat(local.email_binding, local.smtp_bindings, local.config_bindings)

  observability = { enabled = true }

  depends_on = [null_resource.build]
}
