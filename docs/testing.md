# Testing the DLP Email Notifier

This guide walks through deploying the DLP notification Worker and sending a test
event so you can confirm the whole chain works: **DLP match → Worker → email**.

The notifier reports **both blocked and allowed** DLP matches — so you also get
alerted when a DLP profile fires on a policy whose action is *allow* (monitor
mode), not only on blocks.

---

## Prerequisites

- The Worker is deployed via Terraform (`terraform apply`) with `notify_mode`
  set to your chosen transport (`smtp`, `cf_email`, or `log`).
- You have the Worker's URL and its shared secret (token).
- For `smtp` mode: your mail server's host/port/credentials are in
  `terraform.tfvars`, and the `From:` address belongs to the **same domain you
  authenticate as** (this avoids the message being silently dropped for SPF/DKIM
  reasons).

Set these two values for the commands below:

| Placeholder | What it is |
|---|---|
| `<WORKER_URL>` | e.g. `https://workers-email-dlp-notifier.<subdomain>.workers.dev` |
| `<SHARED_SECRET>` | the token from `terraform output -raw shared_secret` |

---

## Step 1 — Deploy / update the Worker

Apply your configuration. This uploads the Worker and its bindings (transport,
recipients, SMTP settings).

```bash
terraform apply
```

Confirm the plan, then approve. A successful run ends with
`Apply complete! Resources: … 1 changed …`.

> **Note:** any change to `terraform.tfvars` (recipients, `notify_mode`,
> `from_address`, SMTP settings) only reaches the live Worker after you run
> `terraform apply` again.

**📸 Screenshot 1 — `terraform apply` completing successfully**

![apply-complete](screenshots/01-terraform-apply.png)

---

## Step 2 — (Optional) Watch the Worker logs live

In a **separate terminal**, stream the Worker's logs. Keep this running while you
send the test in Step 3 — you'll see the result and any SMTP errors in real time.

**zsh / bash**
```bash
npx wrangler tail workers-email-dlp-notifier --format json
```

**nushell**
```nu
^npx wrangler tail workers-email-dlp-notifier --format json
```

A successful send logs:
`DLP notify [smtp]: 2 match(es), 1/1 recipients ok`

---

## Step 3 — Send a test DLP event

This posts a sample batch containing **one blocked** and **one allowed** DLP
match to the Worker. The Worker filters for DLP hits, builds the digest, and
sends the email.

### zsh / bash

```bash
URL="<WORKER_URL>"
SECRET="<SHARED_SECRET>"

curl -s -X POST "$URL?token=$SECRET" \
  -H 'content-type: application/x-ndjson' \
  --data-binary '{"Datetime":"2026-01-01T00:00:00Z","Email":"alice@example.com","HTTPHost":"paste.example.com","Action":"allow","PolicyName":"Monitor secrets","DLPProfiles":["Credentials and Secrets"]}
{"Datetime":"2026-01-01T00:00:05Z","Email":"bob@example.com","HTTPHost":"upload.example.com","Action":"block","PolicyName":"Block PII","DLPProfiles":["Social Security, Insurance, Tax, and Identifier Numbers"]}'
```

### nushell

```nu
let url = "<WORKER_URL>"
let secret = "<SHARED_SECRET>"

let body = '{"Datetime":"2026-01-01T00:00:00Z","Email":"alice@example.com","HTTPHost":"paste.example.com","Action":"allow","PolicyName":"Monitor secrets","DLPProfiles":["Credentials and Secrets"]}
{"Datetime":"2026-01-01T00:00:05Z","Email":"bob@example.com","HTTPHost":"upload.example.com","Action":"block","PolicyName":"Block PII","DLPProfiles":["Social Security, Insurance, Tax, and Identifier Numbers"]}'

^curl -s -X POST $"($url)?token=($secret)" -H 'content-type: application/x-ndjson' --data-binary $body
```

> **Shell note:** in nushell, `^curl` forces the external binary, and
> `$"($url)?token=($secret)"` is string interpolation (the zsh/bash `"$URL?token=$SECRET"`
> form does not expand in nu).

### Expected response

```
ok: 2 DLP match(es), smtp notified 1/1
```

- `2 DLP match(es)` — both sample events matched a DLP profile.
- `1/1` — the number of **recipients** notified (add more addresses to
  `notification_recipients` to fan out wider). Both matches are combined into the
  one email.

If you instead see `"mode":"log"`, the Worker is still in **log mode** — set
`notify_mode = "smtp"` in `terraform.tfvars` and re-apply.

**📸 Screenshot 2 — the `curl` command and its `smtp notified` response**

![curl-response](screenshots/02-curl-response.png)

---

## Step 4 — Confirm the email

Check the inbox of the address in `notification_recipients`. You should receive a
message like:

> **Subject:** DLP: 2 match(es) — 1 blocked, 1 allowed
>
> 🚫 **Blocked (1)** — bob@example.com → upload.example.com — *Social Security,
> Insurance, Tax, and Identifier Numbers* — policy: Block PII
>
> ⚠️ **Allowed (DLP triggered, policy action = allow) (1)** — alice@example.com →
> paste.example.com — *Credentials and Secrets* — policy: Monitor secrets

**📸 Screenshot 3 — the received email showing the blocked + allowed sections**

![received-email](screenshots/03-received-email.png)

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Response says `"mode":"log"` | Worker still in log mode | `notify_mode = "smtp"` in tfvars, then `terraform apply` |
| `smtp notified 0/1` | Mail server rejected the message | Watch `wrangler tail` for the SMTP reply code (e.g. `535` auth) |
| Response OK but **no email arrives** | `From:` domain ≠ authenticated domain → dropped for SPF/DKIM | Set `from_address` to an address on the domain you authenticate as, re-apply |
| Email in **spam** | Sending domain lacks SPF/DKIM/DMARC records | Publish SPF/DKIM for the sending domain |
| `403 forbidden` from the Worker | Wrong or missing `?token=` | Use the current `terraform output -raw shared_secret` |
| Nothing in `wrangler tail` | Wrong account selected | Re-run and pick the correct account at the prompt |

> **Tip:** if the Worker reports success but mail doesn't land, the answer is in
> your **mail server's log** (e.g. `/var/log/mail.log`). Look for the message by
> its `from=` / `to=` addresses: `status=sent` means your server relayed it (a
> receiving-side/spam issue), while `bounced`/`reject` means your server refused
> it (the reason string says why).
