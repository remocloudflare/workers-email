# workers-email — DLP notification via email

A Cloudflare Worker + Terraform module that **emails a digest when a DLP profile
matches** in Gateway HTTP traffic — for **blocked _and_ allowed** matches.

The customer ask this solves: *"notify me by email when a DLP policy is
triggered"* — without standing up a SIEM. Cloudflare has no native
"DLP-triggered → email" alert type today, so this wires **Logpush → Worker →
email** and lets you pick exactly who gets notified.

## What it does

```
Gateway HTTP traffic ─(DLP profile matches)─> Logpush (gateway_http dataset)
        │
        ▼
   Worker (this repo): keep rows where DLPProfiles is non-empty
        │  split into  🚫 Blocked   and   ⚠️ Allowed (DLP triggered, action=allow)
        ▼
   Cloudflare Email Sending  ──>  your recipient list
```

- **Notifies on ALLOWED too.** Filtering is on *"a DLP profile matched"*, not on
  the action — so a profile that fires on an `allow`/log-only policy still emails
  you. The digest separates blocked vs allowed sections.
- **Pick your recipients.** `notification_recipients` is a Terraform list. Edit
  it, `terraform apply`, done.
- **No third-party email service, no SMTP.** Uses the Cloudflare Email Sending
  `send_email` binding.
- **Portable.** The Worker source has zero hardcoded account values — everything
  arrives as bindings. A colleague clones the repo, fills in their own
  `terraform.tfvars`, and applies.

## Repo layout

```
workers-email/
├── src/index.js              # the Worker (filter + digest + email fan-out)
├── wrangler.jsonc            # Worker config (send_email binding, workers_dev)
├── package.json
└── terraform/
    ├── providers.tf          # cloudflare v5 + null + random
    ├── variables.tf          # all variables (recipients, from_address, ...)
    ├── locals.tf             # shared secret, recipients CSV
    ├── worker.tf             # cloudflare_workers_script + bindings
    ├── logpush.tf            # cloudflare_logpush_job (gateway_http)
    ├── build.tf              # bundles the Worker via wrangler --dry-run
    ├── outputs.tf            # worker name, job id, next_steps, verify cmds
    └── terraform.tfvars.example
```

## Prerequisites

These are **not** created by this module — they are account-level Cloudflare One
config the notification depends on:

1. **Gateway HTTP filtering + TLS inspection ON.** DLP can only match decrypted
   HTTPS. No inspection → no DLP rows → no email.
2. **At least one DLP profile wired into a Gateway HTTP policy.** A profile alone
   detects nothing; it must be referenced by an HTTP rule (action `block` or
   `allow`).
3. **Email Sending onboarded for the sender domain:**
   ```bash
   npx wrangler email sending enable yourdomain.com
   ```
   Then `from_address` can be anything `@yourdomain.com`.

### API token scopes

Account-scoped custom token with:
- **Workers Scripts: Edit**
- **Logs: Edit** (for the Logpush job)
- **Account Settings: Read** (`wrangler whoami`)

## Deploy

Terraform bundles the Worker for you (via `wrangler deploy --dry-run`), uploads
it, and creates the Logpush job. Two-step because Logpush needs the Worker's URL.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: token, account id, recipients, from_address
#   leave worker_endpoint = "" for now

terraform init
terraform apply            # builds + deploys the Worker (no Logpush yet)
```

Grab the Worker's URL from **Dashboard → Workers & Pages →
`workers-email-dlp-notifier`** (a `…workers.dev` URL), set it in
`terraform.tfvars`:

```hcl
worker_endpoint = "https://workers-email-dlp-notifier.<your-subdomain>.workers.dev"
```

```bash
terraform apply            # now creates the Logpush job pointed at the Worker
```

> Prefer a custom domain over `workers.dev`? Point one at the Worker and use that
> URL as `worker_endpoint`. The shared secret (`?token=`) protects the endpoint
> either way.

## Change who gets notified

```hcl
# terraform.tfvars
notification_recipients = [
  "secops@yourdomain.com",
  "soc-oncall@yourdomain.com",
  "dpo@yourdomain.com",
]
```
```bash
terraform apply
```

Recipients are also enforced at the binding level
(`allowed_destination_addresses`), so the Worker can only email the configured
list.

## Test without waiting for real traffic

```bash
SECRET=$(terraform output -raw shared_secret)
URL=$(terraform output -raw worker_name >/dev/null; echo "<your worker_endpoint>")

curl -X POST "$URL?token=$SECRET" \
  -H 'content-type: application/x-ndjson' \
  --data-binary '{"Datetime":"2026-01-01T00:00:00Z","Email":"tester@x.com","HTTPHost":"paste.example.com","Action":"allow","PolicyName":"Monitor secrets","DLPProfiles":["Credentials and Secrets"]}
{"Datetime":"2026-01-01T00:00:05Z","Email":"tester@x.com","HTTPHost":"upload.example.com","Action":"block","PolicyName":"Block PII","DLPProfiles":["Social Security, Insurance, Tax, and Identifier Numbers"]}'
```

You should get one email with a **🚫 Blocked (1)** and a **⚠️ Allowed (1)**
section.

## Important limitation to set with the customer

This alert reports **that** a DLP profile matched (user, host, profile, policy,
action). It does **not** contain the matched sensitive value itself. To capture
the actual content, enable **DLP Payload Logging** (Zero Trust → DLP → Settings)
— that's a separate, encrypted store you decrypt locally. Keeping the sensitive
value out of routine email is the safer default anyway.

## How "notify on allowed" works (the #4 ask)

Gateway HTTP logs include a `DLPProfiles` array on every request a DLP profile
matched — regardless of whether the policy's action was `block` or `allow`. The
Worker keeps every row with a non-empty `DLPProfiles` and buckets by `Action`.
So a "monitor-mode" DLP policy (action = allow, used while tuning false
positives) still generates email — exactly the visibility you want before you
switch a policy to block.

## Teardown

```bash
cd terraform
terraform destroy
```
This removes the Worker and the Logpush job. It does not touch your Gateway
policies, DLP profiles, or Email Sending onboarding.
