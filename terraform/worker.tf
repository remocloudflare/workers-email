resource "cloudflare_workers_script" "notifier" {
  account_id     = var.cloudflare_account_id
  script_name    = var.worker_name
  content_file   = local.bundle_js
  content_sha256 = fileexists(local.bundle_js) ? filesha256(local.bundle_js) : local.placeholder
  main_module    = "index.js"

  compatibility_date  = var.compatibility_date
  compatibility_flags = ["nodejs_compat"]

  bindings = [
    # Cloudflare Email binding — no API key, no SMTP.
    # allowed_destination_addresses restricts sends to exactly the notification
    # recipient list (defense in depth). With Email Routing these destinations
    # must be verified addresses; with Email Sending the from-domain must be
    # onboarded. See README prereqs.
    {
      name                          = "EMAIL"
      type                          = "send_email"
      allowed_destination_addresses = var.notification_recipients
    },
    { name = "FROM_ADDRESS", type = "plain_text", text = var.from_address },
    { name = "FROM_NAME", type = "plain_text", text = var.from_name },
    { name = "RECIPIENTS", type = "plain_text", text = local.recipients_csv },
    { name = "ACCOUNT_NAME", type = "plain_text", text = var.account_label },
    { name = "SHARED_SECRET", type = "secret_text", text = local.shared_secret },
  ]

  observability = { enabled = true }

  depends_on = [null_resource.build]
}
