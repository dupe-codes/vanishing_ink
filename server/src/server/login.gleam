import gleam/http.{Get, Post}
import gleam/http/response
import gleam/list
import server/auth
import wisp

pub fn handle(
  req: wisp.Request,
  verifier: auth.Verifier,
  throttle: auth.Throttle,
) -> wisp.Response {
  let result = case req.method {
    Get -> form(200, "")
    Post -> submit(req, verifier, throttle)
    _ -> wisp.method_not_allowed([Get, Post])
  }
  result
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
  )
  |> response.set_header("referrer-policy", "same-origin")
}

fn submit(
  req: wisp.Request,
  verifier: auth.Verifier,
  throttle: auth.Throttle,
) -> wisp.Response {
  case auth.admit(throttle) {
    False -> throttled()
    True -> {
      let req =
        req
        |> wisp.set_max_body_size(4096)
        |> wisp.set_read_chunk_size(4096)
      use <- wisp.require_content_type(req, "application/x-www-form-urlencoded")
      use form_data <- wisp.require_form(req)
      case list.key_find(form_data.values, "password") {
        Ok(password) ->
          case auth.verify_login(password, verifier, throttle) {
            Ok(True) ->
              wisp.redirect("/")
              |> wisp.set_cookie(
                req,
                auth.cookie_name,
                auth.session_payload(verifier, auth.now_seconds()),
                wisp.Signed,
                auth.session_lifetime,
              )
            Ok(False) -> form(401, "Incorrect password.")
            Error(_) -> throttled()
          }
        Error(_) -> form(400, "Enter your password.")
      }
    }
  }
}

fn throttled() -> wisp.Response {
  form(429, "Wait a moment before trying again.")
  |> response.set_header("retry-after", "2")
}

fn form(status: Int, message: String) -> wisp.Response {
  wisp.html_response(
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Sign in — Vanishing Ink</title><style>body{font-family:system-ui;background:#faf8f4;color:#28231d;max-width:24rem;margin:15vh auto;padding:1.5rem}label,input,button{display:block;width:100%;box-sizing:border-box}input,button{font:inherit;padding:.8rem;margin:.7rem 0}button{background:#28231d;color:white;border:0;border-radius:.4rem}p{min-height:1.5em}</style></head><body><h1>Vanishing Ink</h1><form method=\"post\" action=\"/login\"><label for=\"password\">Password</label><input id=\"password\" name=\"password\" type=\"password\" autocomplete=\"current-password\" required autofocus><button type=\"submit\">Sign in</button><p role=\"alert\">"
      <> message
      <> "</p></form></body></html>",
    status,
  )
}
