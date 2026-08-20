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
    "log"  = deploy the Worker WITHOUT an email binding; on a DLP match it logs
             and returns the digest as JSON. Use to verify Worker + Logpush + DLP
             filtering with no email onboarding. (default)
    "send" = attach the Cloudflare send_email binding and actually email the
             notification_recipients. Requires email onboarding (see README).
  EOT
  type        = string
  default     = "log"

  validation {
    condition     = contains(["log", "send"], var.notify_mode)
    error_message = "notify_mode must be \"log\" or \"send\"."
  }
}

variable "from_address" {
  description = <<-EOT
    Verified sender address for the notification email, e.g. dlp-alerts@yourdomain.com.
    Required only when notify_mode = "send". The domain MUST be onboarded to
    Cloudflare Email first (see README).
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

variable "worker_endpoint" {
  description = <<-EOT
    Public HTTPS URL of the deployed Worker that Logpush POSTs to, e.g.
    https://workers-email-dlp-notifier.<your-subdomain>.workers.dev
    or a custom domain. Required only when manage_logpush = true.
    Find the workers.dev URL in the Worker's dashboard after the first apply,
    or set a custom domain. Leave "" to skip Logpush creation on the first
    apply, then set it and re-apply.
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
