/**
 * workers-email — DLP notification Worker
 *
 * Receives Cloudflare Logpush batches for the Gateway HTTP dataset, keeps only
 * the rows where a DLP profile matched, and emails a digest to a configurable
 * recipient list. Reports BOTH blocked matches AND allowed (logged-only)
 * matches — so you learn when a DLP profile fired on a policy whose action is
 * "allow", not just "block".
 *
 * All account-specific config arrives via bindings (see terraform/worker.tf):
 *   env.EMAIL          send_email binding (Cloudflare Email Sending)
 *   env.FROM_ADDRESS   verified sender, e.g. dlp-alerts@yourdomain.com
 *   env.FROM_NAME      display name for the sender
 *   env.RECIPIENTS     comma-separated list of notification recipients
 *   env.SHARED_SECRET  optional; if set, Logpush must present it (see below)
 *   env.ACCOUNT_NAME   optional label shown in the subject/body
 *
 * The Worker source contains ZERO hardcoded account values, so the same file
 * redeploys on any account with only a new terraform.tfvars.
 */

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "POST") {
      return new Response("workers-email DLP notifier: POST only", { status: 405 });
    }

    // Optional shared-secret gate. Logpush lets you append a header via the
    // destination URL (?header=...), or you can put a token in the path.
    if (env.SHARED_SECRET) {
      const provided =
        request.headers.get("cf-logpush-token") ||
        new URL(request.url).searchParams.get("token");
      if (provided !== env.SHARED_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
    }

    let rows;
    try {
      rows = await readLogpushBatch(request);
    } catch (err) {
      return new Response(`could not parse batch: ${err.message}`, { status: 400 });
    }

    // Keep only rows where a DLP profile matched. This is action-agnostic on
    // purpose: it captures block AND allow, so "allowed but DLP triggered"
    // events are reported too.
    const hits = rows.filter((r) => {
      const profiles = r.DLPProfiles ?? r.dlp_profiles ?? [];
      return Array.isArray(profiles) && profiles.length > 0;
    });

    if (hits.length === 0) {
      return new Response("ok: no DLP matches in batch", { status: 200 });
    }

    const recipients = (env.RECIPIENTS || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);

    if (recipients.length === 0) {
      return new Response("no recipients configured (env.RECIPIENTS empty)", { status: 500 });
    }

    const { subject, html, text } = buildDigest(hits, env);

    // Fan out: one message per recipient (send_email addresses one 'to' cleanly).
    const results = await Promise.allSettled(
      recipients.map((to) => sendOne(env, to, subject, html, text))
    );

    const failed = results.filter((r) => r.status === "rejected");
    if (failed.length) {
      // Log for observability; still 200 so Logpush doesn't infinitely retry
      // a partial success.
      console.error("send failures:", failed.map((f) => String(f.reason)));
    }
    console.log(
      `DLP notify: ${hits.length} match(es), ${recipients.length - failed.length}/${recipients.length} recipients ok`
    );

    return new Response(
      `ok: ${hits.length} DLP match(es), notified ${recipients.length - failed.length}/${recipients.length}`,
      { status: 200 }
    );
  },
};

/** Logpush POSTs newline-delimited JSON, gzip-compressed by default. */
async function readLogpushBatch(request) {
  const enc = (request.headers.get("content-encoding") || "").toLowerCase();
  let stream = request.body;
  if (enc.includes("gzip")) {
    stream = request.body.pipeThrough(new DecompressionStream("gzip"));
  }
  const text = await new Response(stream).text();
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

/** Build one row's human-readable line + structured fields. */
function normalize(r) {
  const profiles = r.DLPProfiles ?? r.dlp_profiles ?? [];
  return {
    when: r.Datetime ?? r.datetime ?? r.EdgeStartTimestamp ?? "",
    user: r.Email ?? r.UserID ?? r.email ?? r.user_id ?? "unknown-user",
    device: r.DeviceName ?? r.device_name ?? "",
    host: r.HTTPHost ?? r.http_host ?? r.DestinationIP ?? "",
    url: r.URL ?? r.url ?? "",
    action: (r.Action ?? r.action ?? "").toLowerCase(),
    policy: r.PolicyName ?? r.policy_name ?? "",
    profiles: Array.isArray(profiles) ? profiles : [profiles],
  };
}

function buildDigest(hits, env) {
  const label = env.ACCOUNT_NAME ? ` [${env.ACCOUNT_NAME}]` : "";
  const norm = hits.map(normalize);

  const blocked = norm.filter((h) => h.action === "block" || h.action === "blocked");
  const allowed = norm.filter((h) => !(h.action === "block" || h.action === "blocked"));

  const subject =
    `DLP${label}: ${hits.length} match(es) — ` +
    `${blocked.length} blocked, ${allowed.length} allowed`;

  const section = (title, items) => {
    if (!items.length) return { html: "", text: "" };
    const rowsHtml = items
      .map(
        (h) => `<tr>
          <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.when)}</td>
          <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.user)}</td>
          <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.host)}</td>
          <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.profiles.join(", "))}</td>
          <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.policy)}</td>
        </tr>`
      )
      .join("");
    const rowsText = items
      .map(
        (h) =>
          `  ${h.when} | ${h.user} | ${h.host} | [${h.profiles.join(", ")}] | policy=${h.policy || "-"}`
      )
      .join("\n");
    return {
      html: `<h3 style="margin:16px 0 4px;">${title} (${items.length})</h3>
        <table style="border-collapse:collapse;font:13px monospace;width:100%;">
          <tr style="text-align:left;color:#f6821f;">
            <th style="padding:4px 8px;">Time</th><th style="padding:4px 8px;">User</th>
            <th style="padding:4px 8px;">Host</th><th style="padding:4px 8px;">DLP Profile(s)</th>
            <th style="padding:4px 8px;">Policy</th>
          </tr>${rowsHtml}
        </table>`,
      text: `${title} (${items.length}):\n${rowsText}\n`,
    };
  };

  const bSec = section("🚫 Blocked", blocked);
  const aSec = section("⚠️ Allowed (DLP triggered, policy action = allow)", allowed);

  const html = `<div style="font-family:system-ui,sans-serif;color:#e5e5e5;background:#1a1a1a;padding:16px;">
    <h2 style="color:#f6821f;margin:0 0 8px;">Cloudflare DLP notification${label}</h2>
    <p style="margin:0 0 12px;color:#aaa;">${hits.length} DLP profile match(es) detected in Gateway HTTP traffic.</p>
    ${bSec.html}${aSec.html}
    <p style="margin-top:16px;font-size:12px;color:#888;">
      Note: this alert reports that a DLP profile matched. To view the matched
      <em>content</em> (the sensitive value itself), use DLP Payload Logging.
    </p>
  </div>`;

  const text =
    `Cloudflare DLP notification${label}\n` +
    `${hits.length} DLP profile match(es) in Gateway HTTP traffic.\n\n` +
    `${bSec.text}\n${aSec.text}\n` +
    `Note: reports THAT a DLP profile matched. For the matched content, use DLP Payload Logging.\n`;

  return { subject, html, text };
}

async function sendOne(env, to, subject, html, text) {
  // Cloudflare Email Sending binding — object API (see cloudflare-email-service).
  await env.EMAIL.send({
    to,
    from: env.FROM_NAME
      ? { email: env.FROM_ADDRESS, name: env.FROM_NAME }
      : { email: env.FROM_ADDRESS },
    subject,
    html,
    text,
  });
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}
