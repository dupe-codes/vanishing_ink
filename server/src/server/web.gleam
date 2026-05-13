//// Default middleware stack applied to every request. Mirrors the
//// composition recommended by the upstream Wisp hello-world example —
//// method override, request logging, crash rescue, HEAD rewriting, and
//// CSRF protection — plus `wisp.serve_static` for the Lustre client
//// bundle so the BEAM server is the single HTTP origin during dev.
////
//// Also defines the application `Context` — the shared resource bundle
//// the router threads through every handler. Today that's the SQLite
//// connection and the client dist directory; new long-lived state
//// (caches, config) should land here so the routing layer stays a thin
//// pattern-matcher.

import sqlight
import wisp

/// Application-wide context handed to every request handler. Owned by
/// `main` and partially applied into the request handler so each call
/// arrives carrying the same connection.
///
/// `static_dir` points to the Lustre build output (`client/dist/`) so
/// the BEAM server can serve JS, CSS, and the SPA shell alongside the
/// API — one origin, no proxy, no CORS.
pub type Context {
  Context(db: sqlight.Connection, static_dir: String)
}

pub fn middleware(
  req: wisp.Request,
  ctx: Context,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use req <- wisp.csrf_known_header_protection(req)

  // Serve client assets (client.js, styles.css, etc.) from the Lustre
  // build output. Requests that don't match a file fall through to the
  // router. The `under: "/"` prefix means `/client.js` resolves to
  // `<static_dir>/client.js` — matching the root-relative paths in the
  // generated index.html.
  use <- wisp.serve_static(req, under: "/", from: ctx.static_dir)

  handle_request(req)
}
