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

import gleam/dynamic/decode
import gleam/list
import gleam/string
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

/// Render every decode failure on a single line. Reporting only the
/// first error meant a client missing two fields had to fix one,
/// re-request, then learn about the second; rolling them all up
/// removes that round-trip. Lifted out of `router` so the sibling
/// `sessions` handler module shares the same error-shape contract.
pub fn describe_decode_errors(errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> "invalid JSON body"
    _ ->
      errors
      |> list.map(describe_decode_error)
      |> string.join("; ")
  }
}

fn describe_decode_error(error: decode.DecodeError) -> String {
  let decode.DecodeError(expected, found, path) = error
  let path_str = case path {
    [] -> "<root>"
    _ -> string.join(path, ".")
  }
  "expected " <> expected <> " at " <> path_str <> " but found " <> found
}

/// Log a SQLite error with operator-visible context, then return the
/// generic 500. Centralised so every call site has the same shape
/// (operation tag plus a structured Sqlight error inspection) and no
/// future error path can silently drop the trail.
pub fn db_error_response(
  operation: String,
  error: sqlight.Error,
) -> wisp.Response {
  wisp.log_error(operation <> " failed: " <> string.inspect(error))
  wisp.internal_server_error()
}
