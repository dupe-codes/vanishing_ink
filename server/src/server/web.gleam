//// Default middleware stack applied to every request. Mirrors the
//// composition recommended by the upstream Wisp hello-world example —
//// method override, request logging, crash rescue, HEAD rewriting, and
//// CSRF protection — so new routes inherit safe defaults.
////
//// Also defines the application `Context` — the shared resource bundle
//// the router threads through every handler. Today that's just the
//// SQLite connection, but new long-lived state (caches, config) should
//// land here so the routing layer stays a thin pattern-matcher.

import sqlight
import wisp

/// Application-wide context handed to every request handler. Owned by
/// `main` and partially applied into the request handler so each call
/// arrives carrying the same connection.
pub type Context {
  Context(db: sqlight.Connection)
}

pub fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use req <- wisp.csrf_known_header_protection(req)

  handle_request(req)
}
