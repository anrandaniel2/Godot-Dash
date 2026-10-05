/**
 * Godot Dash — hosted CORS relay for the HTML5 build.
 *
 * WHY THIS EXISTS
 * ---------------
 * A browser only hands a page the body of a cross-origin response when that
 * server opts in with `Access-Control-Allow-Origin`. None of the hosts the Web
 * build needs do:
 *
 *   www.boomlings.com                 (RobTop) no CORS headers, and it answers
 *                                     403 to any request that carries an
 *                                     `Origin` header - which every browser
 *                                     attaches to a cross-origin POST.
 *   history.geometrydash.eu           no CORS headers on the API or the
 *                                     level-file download.
 *   geometrydashcontent.b-cdn.net,
 *   geometrydashfiles.b-cdn.net       BunnyCDN, no CORS headers.
 *   audio.ngfiles.com                 Newgrounds song files (the URL
 *                                     getGJSongInfo.php returns), no CORS.
 *
 * So the request has to be made server-side. This Worker performs it and
 * answers the browser with CORS headers, body and status intact.
 *
 * DEPLOY
 * ------
 *   npx wrangler deploy tools/web_relay_worker.js --name gdash-relay
 *
 * then point the game at it, so an exported build ships with the relay:
 *
 *   project.godot:
 *     [network]
 *     cors_proxy="https://gdash-relay.<your-subdomain>.workers.dev/?url="
 *
 * (or the per-user `Internet/cors_proxy` value in `user://config.cfg`).
 * `tools/serve_web.py` implements the same `?url=` contract for localhost
 * exports, which the game picks up automatically.
 *
 * The game appends the percent-encoded target to whatever prefix is configured
 * (see NativeCore.resolve_proxy_url), so this Worker accepts:
 *
 *   GET/POST /?url=<percent-encoded absolute URL>
 *   GET/POST /<absolute URL>            (path style, like serve_web.py)
 */

// Only these hosts are relayed; anything else is refused so a deployed Worker
// cannot be used as an open proxy.
const ALLOWED_HOSTS = new Set([
  "www.boomlings.com",
  "boomlings.com",
  "history.geometrydash.eu",
  "geometrydashcontent.b-cdn.net",
  "geometrydashfiles.b-cdn.net",
  "www.newgrounds.com",
  "newgrounds.com",
  // Newgrounds' audio host: getGJSongInfo.php returns song URLs here.
  "audio.ngfiles.com",
  "cvolton.eu",
  "www.cvolton.eu",
]);

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, HEAD, OPTIONS",
  "Access-Control-Allow-Headers": "*",
  "Access-Control-Max-Age": "86400",
};

function textResponse(status, message) {
  return new Response(message, {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "text/plain; charset=utf-8" },
  });
}

function targetFromRequest(url) {
  const query = url.searchParams.get("url");
  if (query) return query;
  // Path style: /cors-proxy/https://... or /https://...
  let raw = url.pathname.replace(/^\/+/, "");
  if (raw.startsWith("cors-proxy/")) raw = raw.slice("cors-proxy/".length);
  try {
    raw = decodeURIComponent(raw);
  } catch {
    return "";
  }
  return raw.startsWith("http://") || raw.startsWith("https://") ? raw : "";
}

export default {
  async fetch(request) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const target = targetFromRequest(new URL(request.url));
    if (!target) {
      return textResponse(400, "Missing target URL: use /?url=<percent-encoded URL>.");
    }

    let targetUrl;
    try {
      targetUrl = new URL(target);
    } catch {
      return textResponse(400, "Target URL could not be parsed.");
    }
    if (targetUrl.protocol !== "https:" && targetUrl.protocol !== "http:") {
      return textResponse(400, "Only http(s) targets are relayed.");
    }
    if (!ALLOWED_HOSTS.has(targetUrl.hostname)) {
      return textResponse(403, `Host is not relayed by this Worker: ${targetUrl.hostname}`);
    }

    const upstreamHeaders = new Headers();
    const contentType = request.headers.get("Content-Type");
    if (contentType) upstreamHeaders.set("Content-Type", contentType);
    if (targetUrl.hostname.endsWith("boomlings.com")) {
      // RobTop requires an empty User-Agent; a browser cannot set that header,
      // which is one of the reasons the request has to happen here.
      upstreamHeaders.set("User-Agent", "");
    } else {
      upstreamHeaders.set("User-Agent", "Godot-Dash-Web/1.0");
    }

    // Request bodies here are small form payloads (the level files come back as
    // responses), so buffer them instead of forwarding the duplex stream.
    let requestBody;
    if (request.method !== "GET" && request.method !== "HEAD") {
      requestBody = await request.arrayBuffer();
    }

    let upstream;
    try {
      upstream = await fetch(targetUrl.toString(), {
        method: request.method,
        headers: upstreamHeaders,
        body: requestBody,
        redirect: "follow",
      });
    } catch (error) {
      return textResponse(502, `Relay could not reach ${targetUrl.hostname}: ${error}`);
    }

    // Return the upstream bytes untouched (level strings and .mp3 files are
    // binary-safe), with the status kept so the client can still see 404s.
    const headers = new Headers(CORS_HEADERS);
    const upstreamType = upstream.headers.get("Content-Type");
    if (upstreamType) headers.set("Content-Type", upstreamType);
    // Content-Length is deliberately not copied: the runtime computes it for
    // the returned body, and a stale value would truncate the level string or
    // the song file.
    headers.set("Cache-Control", "no-store");

    return new Response(upstream.body, { status: upstream.status, headers });
  },
};
