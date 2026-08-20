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
 *   env.NOTIFY_MODE    transport: "log" | "cf_email" | "smtp"
 *   env.EMAIL          send_email binding (only for cf_email transport)
 *   env.FROM_ADDRESS   sender address, e.g. dlp-alerts@yourdomain.com
 *   env.FROM_NAME      display name for the sender
 *   env.RECIPIENTS     comma-separated list of notification recipients
 *   env.SHARED_SECRET  optional; if set, Logpush must present it (see below)
 *   env.ACCOUNT_NAME   optional label shown in the subject/body
 *   -- SMTP transport (relay through the customer's own mail server) --
 *   env.SMTP_HOST      submission host (587/465). NOTE: CF blocks port 25.
 *   env.SMTP_PORT      587 (STARTTLS, default) | 465 (implicit TLS)
 *   env.SMTP_TLS       "starttls" (default) | "tls" | "none"
 *   env.SMTP_USER      auth username (optional; enables AUTH LOGIN)
 *   env.SMTP_PASS      auth password (secret_text)
 *   env.SMTP_EHLO      EHLO hostname (optional)
 *
 * The Worker source contains ZERO hardcoded account values, so the same file
 * redeploys on any account with only a new terraform.tfvars.
 */

import { sendSmtp } from "./smtp.js";

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

    // Detect the log source and keep only DLP-relevant rows.
    //  - Gateway HTTP dataset: row has DLPProfiles[] (non-empty = a DLP match).
    //  - AI Gateway (ai_gateway_events) dataset: a DLP block surfaces as
    //    StatusCode 424 (the prompt was blocked by an AI Gateway DLP policy).
    //    Note: the Logpush dataset has NO dlp_action/profile field in plaintext —
    //    those live in the ENCRYPTED Metadata. So here we alert on the 424 signal;
    //    profile-level detail requires decrypting Metadata (future enhancement).
    const isAiGateway = rows.some((r) => "Gateway" in r || "StatusCode" in r);

    let hits;
    if (isAiGateway) {
      hits = rows
        .filter((r) => Number(r.StatusCode) === 424)
        .map((r) => ({
          source: "ai_gateway",
          when: r.Datetime ?? r.EdgeStartTimestamp ?? "",
          gateway: r.Gateway ?? "",
          model: r.Model ?? "",
          provider: r.Provider ?? "",
          endpoint: r.Endpoint ?? "",
          status: r.StatusCode,
        }));
    } else {
      hits = rows
        .filter((r) => {
          const p = r.DLPProfiles ?? r.dlp_profiles ?? [];
          return Array.isArray(p) && p.length > 0;
        })
        .map((r) => ({ source: "gateway_http", ...r }));
    }

    if (hits.length === 0) {
      return new Response("ok: no DLP matches in batch", { status: 200 });
    }

    const { subject, html, text } = isAiGateway
      ? buildAiGatewayDigest(hits, env)
      : buildDigest(hits, env);
    const mode = (env.NOTIFY_MODE || "log").toLowerCase();

    // log mode → don't send; return the digest so Worker + Logpush + DLP
    // filtering can be verified without any email onboarding.
    if (mode === "log") {
      console.log(`DLP notify [log mode]: ${hits.length} match(es)\n${text}`);
      return new Response(
        JSON.stringify({ mode: "log", matches: hits.length, subject, text }, null, 2),
        { status: 200, headers: { "content-type": "application/json" } }
      );
    }

    const recipients = (env.RECIPIENTS || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);

    if (recipients.length === 0) {
      return new Response("no recipients configured (env.RECIPIENTS empty)", { status: 500 });
    }

    const from = env.FROM_ADDRESS;
    const fromName = env.FROM_NAME || "";

    let ok = 0;
    let failCount = 0;

    if (mode === "smtp") {
      // One SMTP session, all recipients in the envelope (efficient relay).
      try {
        await sendSmtp(env, { from, fromName, to: recipients, subject, html, text });
        ok = recipients.length;
      } catch (err) {
        failCount = recipients.length;
        console.error("SMTP send failed:", String(err));
      }
    } else if (mode === "cf_email") {
      if (!env.EMAIL) {
        return new Response("cf_email mode but no EMAIL binding attached", { status: 500 });
      }
      const results = await Promise.allSettled(
        recipients.map((to) => sendCfEmail(env, to, subject, html, text))
      );
      failCount = results.filter((r) => r.status === "rejected").length;
      ok = recipients.length - failCount;
      if (failCount) {
        console.error(
          "cf_email failures:",
          results.filter((r) => r.status === "rejected").map((f) => String(f.reason))
        );
      }
    } else {
      return new Response(`unknown NOTIFY_MODE: ${mode}`, { status: 500 });
    }

    console.log(`DLP notify [${mode}]: ${hits.length} match(es), ${ok}/${recipients.length} recipients ok`);

    // Always 200 on partial success so Logpush doesn't retry the whole batch.
    return new Response(
      `ok: ${hits.length} DLP match(es), ${mode} notified ${ok}/${recipients.length}`,
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

function buildAiGatewayDigest(hits, env) {
  const label = env.ACCOUNT_NAME ? ` [${env.ACCOUNT_NAME}]` : "";
  const subject = `AI Gateway DLP${label}: ${hits.length} prompt(s) blocked`;

  const rowsHtml = hits
    .map(
      (h) => `<tr>
        <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.when)}</td>
        <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.gateway)}</td>
        <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.provider)}</td>
        <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.model)}</td>
        <td style="padding:4px 8px;border-bottom:1px solid #333;">${esc(h.status)}</td>
      </tr>`
    )
    .join("");

  const html = `<div style="font-family:system-ui,sans-serif;color:#e5e5e5;background:#1a1a1a;padding:16px;">
    <h2 style="color:#f6821f;margin:0 0 8px;">AI Gateway DLP block${label}</h2>
    <p style="margin:0 0 12px;color:#aaa;">${hits.length} prompt(s) blocked by an AI Gateway DLP policy (HTTP 424).</p>
    <h3 style="margin:16px 0 4px;">🚫 Blocked prompts (${hits.length})</h3>
    <table style="border-collapse:collapse;font:13px monospace;width:100%;">
      <tr style="text-align:left;color:#f6821f;">
        <th style="padding:4px 8px;">Time</th><th style="padding:4px 8px;">Gateway</th>
        <th style="padding:4px 8px;">Provider</th><th style="padding:4px 8px;">Model</th>
        <th style="padding:4px 8px;">Status</th>
      </tr>${rowsHtml}
    </table>
    <p style="margin-top:16px;font-size:12px;color:#888;">
      Note: this reports that AI Gateway DLP blocked a prompt (HTTP 424). The
      matched DLP profile and prompt content live in the encrypted log Metadata —
      decrypt with your Logpush private key to view them.
    </p>
  </div>`;

  const text =
    `AI Gateway DLP block${label}\n` +
    `${hits.length} prompt(s) blocked by an AI Gateway DLP policy (HTTP 424).\n\n` +
    hits
      .map(
        (h) =>
          `  ${h.when} | gateway=${h.gateway} | ${h.provider}/${h.model} | status=${h.status}`
      )
      .join("\n") +
    `\n\nNote: matched profile + prompt content are in the encrypted log Metadata (decrypt with your Logpush private key).\n`;

  return { subject, html, text };
}

async function sendCfEmail(env, to, subject, html, text) {
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
