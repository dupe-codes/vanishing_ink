import server/auth
import server/router
import server/web
import wisp
import wisp/simulate

pub fn verifier() -> auth.Verifier {
  let assert Ok(value) =
    auth.parse_verifier(
      "pbkdf2-sha256$600000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    )
  value
}

pub fn handle_request(req: wisp.Request, ctx: web.Context) -> wisp.Response {
  let issued =
    wisp.ok()
    |> wisp.set_cookie(
      req,
      auth.cookie_name,
      auth.session_payload(ctx.auth_verifier, auth.now_seconds()),
      wisp.Signed,
      auth.session_lifetime,
    )
  let authenticated = simulate.session(req, req, issued)
  router.handle_request(authenticated, ctx)
}
