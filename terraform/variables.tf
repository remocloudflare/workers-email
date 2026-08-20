variable "cloudflare_api_token" {
  description = "Cloudflare API token. Scopes: Workers Scripts:Edit, Logs Edit (Logpush), Account Settings:Read. See README."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the Worker and the Gateway/DLP config."
  type        = string
}

variable "worker_name" {
  description = "Name of the deployed Worker script."
  type        = string
  default     = "workers-email-dlp-notifier"
}

# ---------------------------------------------------------------------------
# Notification recipients — WHO gets the email. Edit this list and re-apply.
# ---------------------------------------------------------------------------
variable "notification_recipients" {
  description = <<-EOT
    List of email addresses that receive the DLP notification.
    Change this list and re-run `terraform apply` to update who is notified.
    Each address should be a real mailbox you control.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.notification_recipients) > 0
    error_message = "notification_recipients must contain at least one email address."
  }
}

variable "notify_mode" {
  description = <<-EOT
    "log"      = deploy the Worker WITHOUT any email transport; on a DLP match it
                 logs and returns the digest as JSON. Verify Worker + Logpush +
                 DLP filtering with zero email setup. (default)
    "cf_email" = use the Cloudflare send_email binding (requires CF Email
                 onboarding — see README).
    "smtp"     = relay the notification through the customer's own SMTP server
                 (submission port 587/465 with auth). No Cloudflare email
                 onboarding, no DNS changes on Cloudflare's side. NOTE: Cloudflare
                 blocks outbound port 25 from Workers, so the relay MUST be 587 or
                 465, not a plain port-25 MTA.
  EOT
  type        = string
  default     = "log"

  validation {
    condition     = contains(["log", "cf_email", "smtp"], var.notify_mode)
    error_message = "notify_mode must be \"log\", \"cf_email\", or \"smtp\"."
  }
}

variable "from_address" {
  description = <<-EOT
    Sender address for the notification email, e.g. dlp-alerts@yourdomain.com.
    Required when notify_mode = "cf_email" or "smtp". For cf_email the domain must
    be onboarded to Cloudflare Email; for smtp use an address on the domain you
    authenticate as (so it passes SPF/DKIM). See README.
  EOT
  type        = string
  default     = ""
}

variable "from_name" {
  description = "Display name shown as the email sender."
  type        = string
  default     = "Cloudflare DLP Notifier"
}

variable "account_label" {
  description = "Optional short label shown in the email subject/body (e.g. customer or environment name)."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# SMTP transport (notify_mode = "smtp") — relay through the customer's own
# mail server. No Cloudflare email onboarding, no DNS changes on CF's side.
# Cloudflare blocks outbound port 25, so use submission port 587 or 465.
# ---------------------------------------------------------------------------
variable "smtp_host" {
  description = "SMTP submission host (customer's mail server). Required when notify_mode = smtp."
  type        = string
  default     = ""
}

variable "smtp_port" {
  description = "SMTP submission port: 587 (STARTTLS) or 465 (implicit TLS). Port 25 is blocked by Cloudflare."
  type        = number
  default     = 587
}

variable "smtp_tls" {
  description = "TLS mode: \"starttls\" (port 587), \"tls\" (port 465), or \"none\" (testing only)."
  type        = string
  default     = "starttls"

  validation {
    condition     = contains(["starttls", "tls", "none"], var.smtp_tls)
    error_message = "smtp_tls must be \"starttls\", \"tls\", or \"none\"."
  }
}

variable "smtp_user" {
  description = "SMTP auth username. Leave empty for an unauthenticated relay (rare)."
  type        = string
  default     = ""
}

variable "smtp_pass" {
  description = "SMTP auth password (stored as a Worker secret binding)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_ehlo" {
  description = "EHLO hostname the Worker presents to the SMTP server."
  type        = string
  default     = "workers-email.dlp-notifier"
}

# ---------------------------------------------------------------------------
# Logpush wiring
# ---------------------------------------------------------------------------
variable "manage_logpush" {
  description = <<-EOT
    When true (default) Terraform creates the Logpush job (gateway_http dataset)
    that feeds this Worker. Set false if you prefer to create/point the Logpush
    job yourself, or your token lacks Logs:Edit.
  EOT
  type        = bool
  default     = true
}

variable "logpush_job_name" {
  description = "Name of the Logpush job that forwards Gateway HTTP logs to the Worker."
  type        = string
  default     = "dlp-notifier-gateway-http"
}

# --- AI Gateway Logpush (dataset: ai_gateway_events) ---
variable "enable_ai_gateway" {
  description = <<-EOT
    Master switch for the AI Gateway DLP path.
    true  = also create a Logpush job for the AI Gateway (ai_gateway_events
            dataset) that feeds this Worker. A DLP block in AI Gateway appears as
            StatusCode 424. Requires the gateway to have collect_logs + logpush +
            a logpush_public_key configured out-of-band (see README), and
            ai_gateway_name must be set.
    false = skip the AI Gateway path entirely (default). The Worker + Gateway HTTP
            DLP path still deploy and work normally.
  EOT
  type        = bool
  default     = false
}

variable "ai_gateway_name" {
  description = "Name/id of the AI Gateway to watch. Required when enable_ai_gateway = true."
  type        = string
  default     = ""
}

variable "ai_gateway_logpush_job_name" {
  description = "Name of the Logpush job forwarding AI Gateway events to the Worker."
  type        = string
  default     = "dlp-notifier-ai-gateway"
}

variable "worker_endpoint" {
  description = <<-EOT
    OPTIONAL override for the Worker URL that Logpush POSTs to. Leave "" (default)
    and the module auto-derives the workers.dev URL and enables the route in the
    SAME apply — no manual copy step. Set this only to force a specific URL, e.g.
    a custom domain like https://dlp-notify.example.com.
  EOT
  type        = string
  default     = ""
}

variable "shared_secret" {
  description = <<-EOT
    Optional shared secret. When non-empty, the Worker rejects any POST that does
    not present it (as ?token= on the destination URL). Leave "" to auto-generate,
    or set "disabled" semantics by setting manage separately. Recommended: leave
    empty to auto-generate a strong value.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "compatibility_date" {
  description = "Worker compatibility date."
  type        = string
  default     = "2026-03-31"
}

variable "repo_root" {
  description = "Path to the repo root (where src/ and wrangler.jsonc live), relative to the terraform/ dir."
  type        = string
  default     = ".."
}
