/**
 * Minimal SMTP client for Cloudflare Workers, using the cloudflare:sockets API.
 *
 * Supports submission ports with auth:
 *   - 587 STARTTLS  (SMTP_TLS=starttls, default)
 *   - 465 implicit TLS (SMTP_TLS=tls)
 *   - plaintext (SMTP_TLS=none)  — testing only, never over the internet
 *
 * HARD LIMIT: Cloudflare blocks outbound TCP port 25 from Workers. Relay must be
 * a submission port (587/465) on the customer's mail server. AUTH LOGIN /
 * AUTH PLAIN supported. No port-25 MTA delivery.
 *
 * This is a compact, dependency-free implementation — nodemailer does not run on
 * the Workers runtime.
 */

export async function sendSmtp(env, { from, fromName, to, subject, html, text }) {
  const { connect } = await import("cloudflare:sockets");

  const host = env.SMTP_HOST;
  const port = Number(env.SMTP_PORT || 587);
  const mode = (env.SMTP_TLS || "starttls").toLowerCase(); // starttls | tls | none
  const user = env.SMTP_USER || "";
  const pass = env.SMTP_PASS || "";
  const helo = env.SMTP_EHLO || "workers-email.dlp-notifier";
  const recipients = Array.isArray(to) ? to : [to];

  if (!host) throw new Error("SMTP_HOST not set");

  let socket = connect(
    { hostname: host, port },
    { secureTransport: mode === "tls" ? "on" : "starttls", allowHalfOpen: false }
  );

  const enc = new TextEncoder();
  const dec = new TextDecoder();
  let reader = socket.readable.getReader();
  let writer = socket.writable.getWriter();
  let buf = "";

  async function readReply() {
    // An SMTP reply ends on a line "NNN " (code followed by a space, not '-').
    while (true) {
      const lines = buf.split("\r\n").filter((l) => l.length > 0);
      const last = lines[lines.length - 1];
      if (last && /^\d{3} /.test(last)) {
        const code = parseInt(last.slice(0, 3), 10);
        const text = lines.join("\n");
        buf = "";
        return { code, text };
      }
      const { value, done } = await reader.read();
      if (done) {
        const code = 0;
        const text = buf;
        buf = "";
        return { code, text };
      }
      buf += dec.decode(value, { stream: true });
    }
  }

  async function cmd(line, expect) {
    if (line !== null) await writer.write(enc.encode(line + "\r\n"));
    const reply = await readReply();
    if (expect && !expect.includes(reply.code)) {
      throw new Error(`SMTP ${line ? line.split(" ")[0] : "<greeting>"} failed: ${reply.code} ${reply.text}`);
    }
    return reply;
  }

  try {
    await cmd(null, [220]); // server greeting
    await cmd(`EHLO ${helo}`, [250]);

    if (mode === "starttls") {
      await cmd("STARTTLS", [220]);
      // Upgrade the connection and rebind the streams.
      reader.releaseLock();
      writer.releaseLock();
      socket = socket.startTls();
      reader = socket.readable.getReader();
      writer = socket.writable.getWriter();
      buf = "";
      await cmd(`EHLO ${helo}`, [250]);
    }

    if (user) {
      // AUTH LOGIN (widely supported).
      await cmd("AUTH LOGIN", [334]);
      await cmd(b64(user), [334]);
      await cmd(b64(pass), [235]);
    }

    const envelopeFrom = from;
    await cmd(`MAIL FROM:<${envelopeFrom}>`, [250]);
    for (const rcpt of recipients) {
      await cmd(`RCPT TO:<${rcpt}>`, [250, 251]);
    }
    await cmd("DATA", [354]);

    const mime = buildMime({ from, fromName, to: recipients, subject, html, text });
    // Dot-stuff: any line starting with '.' must be doubled.
    const stuffed = mime.replace(/\r\n\./g, "\r\n..");
    await writer.write(enc.encode(stuffed + "\r\n.\r\n"));
    await cmd(null, [250]); // DATA accepted

    await cmd("QUIT", [221]).catch(() => {}); // some servers drop before 221
  } finally {
    try { reader.releaseLock(); } catch {}
    try { writer.releaseLock(); } catch {}
    try { await socket.close(); } catch {}
  }
}

function b64(s) {
  return btoa(unescape(encodeURIComponent(s)));
}

function buildMime({ from, fromName, to, subject, html, text }) {
  const boundary = "b_" + Math.random().toString(36).slice(2);
  const fromHdr = fromName ? `${mimeWord(fromName)} <${from}>` : from;
  const toHdr = (Array.isArray(to) ? to : [to]).join(", ");
  const date = new Date().toUTCString();
  const msgId = `<${crypto.randomUUID()}@workers-email>`;
  return [
    `From: ${fromHdr}`,
    `To: ${toHdr}`,
    `Subject: ${mimeWord(subject)}`,
    `Message-ID: ${msgId}`,
    `Date: ${date}`,
    `MIME-Version: 1.0`,
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    ``,
    `--${boundary}`,
    `Content-Type: text/plain; charset="utf-8"`,
    `Content-Transfer-Encoding: 8bit`,
    ``,
    text,
    ``,
    `--${boundary}`,
    `Content-Type: text/html; charset="utf-8"`,
    `Content-Transfer-Encoding: 8bit`,
    ``,
    html,
    ``,
    `--${boundary}--`,
    ``,
  ].join("\r\n");
}

// RFC 2047 encode a header value if it has non-ASCII, so subjects/names survive.
function mimeWord(s) {
  if (/^[\x20-\x7E]*$/.test(s)) return s;
  return `=?UTF-8?B?${b64(s)}?=`;
}
