output "worker_name" {
  description = "Deployed Worker script name."
  value       = cloudflare_workers_script.notifier.script_name
}

output "notification_recipients" {
  description = "Current recipients of the DLP notification email."
  value       = var.notification_recipients
}

output "logpush_job_id" {
  description = "ID of the Logpush job feeding the Worker (null if not managed here)."
  value       = local.logpush_ready ? cloudflare_logpush_job.dlp[0].id : null
}

output "shared_secret" {
  description = "Shared secret Logpush presents to the Worker. Auto-generated if not supplied."
  value       = local.shared_secret
  sensitive   = true
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Done — one apply deployed the Worker, its workers.dev route, and Logpush.
       Worker URL: ${local.effective_worker_endpoint}
    2. Prereqs the Worker needs at RUNTIME (not created by this module):
         - A sender path: your own SMTP server (notify_mode=smtp) OR Cloudflare
           Email onboarded for the from_address domain (notify_mode=cf_email).
         - Gateway HTTP filtering + TLS inspection ON (else no DLP rows exist).
         - At least one DLP profile wired into a Gateway HTTP policy.
    3. To change WHO is notified: edit notification_recipients and re-apply.
    4. Test the Worker directly:
         curl -X POST "${local.effective_worker_endpoint}?token=<shared_secret>" \
           -H 'content-type: application/x-ndjson' \
           --data-binary '{"Datetime":"2026-01-01T00:00:00Z","Email":"t@x.com","HTTPHost":"paste.example","Action":"allow","DLPProfiles":["Credentials and Secrets"]}'
       (get the token: terraform output -raw shared_secret)
  EOT
}
