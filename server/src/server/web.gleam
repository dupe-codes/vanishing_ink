//// Default middleware stack applied to every request. Mirrors the
//// composition recommended by the upstream Wisp hello-world example —
//// method override, request logging, crash rescue, HEAD rewriting, and
//// CSRF protection — so new routes inherit safe defaults.

import wisp

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
