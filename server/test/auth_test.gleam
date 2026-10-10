import authenticated_router
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response
import gleam/list
import gleam/string
import server/auth
import server/config
import server/db
import server/router
import server/web
import sqlight
import wisp
import wisp/simulate

const encoded_verifier = "pbkdf2-sha256$600000$AAECAwQFBgcICQoLDA0ODw==$yunIATdFlvF95Iuk7XBhaStdCrQzkyp9PN9pjf2Ls+g="

fn verifier() -> auth.Verifier {
  let assert Ok(value) = auth.parse_verifier(encoded_verifier)
  value
}

@external(erlang, "atomics", "put")
fn set_throttle_slot(throttle: auth.Throttle, slot: Int, value: Int) -> Nil

pub fn password_derivation_concurrency_guard_test() {
  let throttle = auth.new_throttle()
  set_throttle_slot(throttle, 2, 1)
  assert auth.verify_login("test-password", verifier(), throttle) == Error(Nil)
  set_throttle_slot(throttle, 2, 0)
  assert auth.verify_login("test-password", verifier(), throttle) == Ok(True)
  assert auth.verify_login("wrong", verifier(), throttle) == Ok(False)
}

pub fn oversized_password_rejected_without_cookie_test() {
  with_context(fn(ctx) {
    let req =
      request(http.Post, "/login")
      |> simulate.form_body([#("password", string.repeat("x", 1025))])
    let result = router.handle_request(req, ctx)
    assert result.status == 401
    assert response.get_header(result, "set-cookie") == Error(Nil)
  })
}

pub fn local_http_cookie_test() {
  with_context(fn(ctx) {
    let base = request(http.Post, "/login")
    let req =
      http_request.Request(..base, host: "localhost", scheme: http.Http)
      |> simulate.form_body([#("password", "test-password")])
      |> simulate.header("origin", "http://localhost")
      |> simulate.header("host", "localhost")
    let result = router.handle_request(req, ctx)
    assert result.status == 303
    let assert Ok(cookie) = response.get_header(result, "set-cookie")
    assert !string.contains(cookie, "Secure")
    assert string.contains(cookie, "HttpOnly")
  })
}

fn with_context(run: fn(web.Context) -> Nil) -> Nil {
  let assert Ok(conn) = db.initialize(":memory:")
  let ctx = web.Context(conn, "test/fixtures", verifier(), auth.new_throttle())
  run(ctx)
  let assert Ok(_) = sqlight.close(conn)
  Nil
}

fn request(method: http.Method, path: String) -> wisp.Request {
  simulate.browser_request(method, path)
}

fn signed_request(req: wisp.Request, payload: String) -> wisp.Request {
  let issued =
    wisp.ok()
    |> wisp.set_cookie(
      req,
      auth.cookie_name,
      payload,
      wisp.Signed,
      auth.session_lifetime,
    )
  simulate.session(req, req, issued)
}

pub fn verifier_encoding_and_password_test() {
  let throttle = auth.new_throttle()
  assert auth.verify_login("test-password", verifier(), throttle) == Ok(True)
  assert auth.verify_login("wrong-password", verifier(), throttle) == Ok(False)
  assert auth.verify_login("", verifier(), throttle) == Ok(False)
  assert auth.verify_login(string.repeat("x", 1025), verifier(), throttle)
    == Ok(False)
}

pub fn verifier_malformed_inputs_test() {
  list.each(
    [
      "",
      "sha256$abc",
      "pbkdf2-sha256$1$AA==$AA==",
      "pbkdf2-sha256$600000$!$!",
      "pbkdf2-sha256$600000$AA==$AA==",
      encoded_verifier <> "$extra",
    ],
    fn(value) {
      assert auth.parse_verifier(value) == Error(Nil)
    },
  )
}

pub fn config_missing_and_invalid_are_rejected_test() {
  assert config.parse_auth_password_hash(Error(Nil))
    == Error("AUTH_PASSWORD_HASH is required")
  assert config.parse_auth_password_hash(Ok("private-invalid-value"))
    == Error("AUTH_PASSWORD_HASH is not a valid PBKDF2 verifier")
  let assert Ok(_) = config.parse_auth_password_hash(Ok(encoded_verifier))
}

pub fn payload_expiry_boundaries_test() {
  let v = verifier()
  let payload = auth.session_payload(v, 100)
  assert auth.valid_payload(payload, v, 100)
  assert auth.valid_payload(payload, v, 100 + auth.session_lifetime - 1)
  assert !auth.valid_payload(payload, v, 100 + auth.session_lifetime)
  assert !auth.valid_payload(payload, v, 99)
  assert !auth.valid_payload(auth.session_payload(v, -1), v, 100)
  assert !auth.valid_payload("1", v, 100)
  assert !auth.valid_payload(payload <> ":extra", v, 100)
  assert !auth.valid_payload(payload, authenticated_router.verifier(), 100)
}

pub fn throttle_atomic_admission_test() {
  let throttle = auth.new_throttle()
  let subject = process.new_subject()
  list.each(list.repeat(Nil, 40), fn(_) {
    process.spawn(fn() { process.send(subject, auth.admit(throttle)) })
    Nil
  })
  let admitted =
    list.filter_map(list.repeat(Nil, 40), fn(_) {
      let assert Ok(result) = process.receive(subject, 1000)
      case result {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
    })
  assert list.length(admitted) == 1
  assert !auth.admit(throttle)
  process.sleep(2001)
  assert auth.admit(throttle)
}

pub fn unauthenticated_pages_and_assets_redirect_test() {
  with_context(fn(ctx) {
    list.each(
      [
        "/",
        "/index.html",
        "/client.js",
        "/styles.css",
        "/manifest.json",
        "/icon-192.png",
        "/reader/book",
      ],
      fn(path) {
        let result = router.handle_request(request(http.Get, path), ctx)
        assert result.status == 303
        assert response.get_header(result, "location") == Ok("/login")
        assert response.get_header(result, "cache-control")
          == Ok("private, no-store")
      },
    )
  })
}

pub fn unauthenticated_api_methods_rejected_test() {
  with_context(fn(ctx) {
    list.each(
      [http.Get, http.Post, http.Put, http.Patch, http.Delete, http.Head],
      fn(method) {
        let result = router.handle_request(request(method, "/api/books"), ctx)
        assert result.status == 401
      },
    )
    let result = router.handle_request(request(http.Get, "/api/settings"), ctx)
    assert simulate.read_body(result) == "{\"error\":\"unauthorized\"}"
    assert router.handle_request(request(http.Get, "/api/status/extra"), ctx).status
      == 401
    assert router.handle_request(request(http.Post, "/api/status"), ctx).status
      == 401
  })
}

pub fn public_health_probe_test() {
  with_context(fn(ctx) {
    let result = router.handle_request(request(http.Get, "/api/status"), ctx)
    assert result.status == 200
    assert simulate.read_body(result) == "{\"status\":\"ok\"}"
    let head = router.handle_request(request(http.Head, "/api/status"), ctx)
    assert head.status == 200
  })
}

pub fn login_form_public_and_self_contained_test() {
  with_context(fn(ctx) {
    let result = router.handle_request(request(http.Get, "/login"), ctx)
    assert result.status == 200
    assert response.get_header(result, "referrer-policy") == Ok("same-origin")
    assert string.contains(
      simulate.read_body(result),
      "autocomplete=\"current-password\"",
    )
    assert response.get_header(result, "content-security-policy") != Error(Nil)
    assert router.handle_request(request(http.Delete, "/login"), ctx).status
      == 405
  })
}

pub fn login_success_grants_access_and_secure_cookie_test() {
  with_context(fn(ctx) {
    let req =
      request(http.Post, "/login")
      |> simulate.form_body([#("password", "test-password")])
    let result = router.handle_request(req, ctx)
    assert result.status == 303
    assert response.get_header(result, "location") == Ok("/")
    let assert Ok(cookie) = response.get_header(result, "set-cookie")
    assert string.contains(cookie, "HttpOnly")
    assert string.contains(cookie, "Secure")
    assert string.contains(cookie, "SameSite=Lax")
    assert string.contains(cookie, "Max-Age=5184000")
    let authenticated =
      simulate.session(request(http.Get, "/api/books"), req, result)
    assert router.handle_request(authenticated, ctx).status == 200
    let page = simulate.session(request(http.Get, "/index.html"), req, result)
    assert router.handle_request(page, ctx).status == 200
  })
}

pub fn login_failure_then_throttle_test() {
  with_context(fn(ctx) {
    let req =
      request(http.Post, "/login")
      |> simulate.form_body([#("password", "wrong")])
    let result = router.handle_request(req, ctx)
    assert result.status == 401
    assert response.get_header(result, "set-cookie") == Error(Nil)
    let req =
      request(http.Post, "/login")
      |> simulate.form_body([#("password", "test-password")])
    let result = router.handle_request(req, ctx)
    assert result.status == 429
    assert response.get_header(result, "retry-after") == Ok("2")
    assert response.get_header(result, "set-cookie") == Error(Nil)
  })
}

pub fn login_missing_field_test() {
  with_context(fn(ctx) {
    let req = request(http.Post, "/login") |> simulate.form_body([])
    assert router.handle_request(req, ctx).status == 400
  })
}

pub fn login_body_limit_test() {
  with_context(fn(ctx) {
    let req =
      request(http.Post, "/login")
      |> simulate.form_body([#("password", string.repeat("x", 5000))])
    assert router.handle_request(req, ctx).status == 413
  })
}

pub fn login_rejects_multipart_test() {
  with_context(fn(ctx) {
    let req =
      request(http.Post, "/login")
      |> simulate.header("content-type", "multipart/form-data; boundary=test")
    assert router.handle_request(req, ctx).status == 415
  })
}

pub fn cross_origin_login_rejected_test() {
  with_context(fn(ctx) {
    let req =
      request(http.Post, "/login")
      |> simulate.form_body([#("password", "test-password")])
      |> simulate.header("origin", "https://evil.example")
    assert router.handle_request(req, ctx).status == 400
  })
}

pub fn null_origin_login_rejected_test() {
  with_context(fn(ctx) {
    let req =
      request(http.Post, "/login")
      |> simulate.form_body([#("password", "test-password")])
      |> simulate.header("origin", "null")
    let result = router.handle_request(req, ctx)
    assert result.status == 400
    assert response.get_header(result, "set-cookie") == Error(Nil)
  })
}

pub fn scripted_writes_require_origin_or_referer_test() {
  with_context(fn(ctx) {
    let payload = auth.session_payload(ctx.auth_verifier, auth.now_seconds())
    let req =
      simulate.request(http.Put, "/api/settings")
      |> signed_request(payload)
    assert router.handle_request(req, ctx).status == 401
    let req =
      simulate.request(http.Put, "/api/settings")
      |> signed_request(payload)
      |> simulate.header("origin", "https://wisp.example.com")
    assert router.handle_request(req, ctx).status == 415
    let req =
      simulate.request(http.Put, "/api/settings")
      |> signed_request(payload)
      |> simulate.header("referer", "https://wisp.example.com/reader")
    assert router.handle_request(req, ctx).status == 415
  })
}

pub fn invalid_signed_cookies_rejected_test() {
  with_context(fn(ctx) {
    let now = auth.now_seconds()
    list.each(
      [
        "1",
        auth.session_payload(ctx.auth_verifier, now - auth.session_lifetime),
        auth.session_payload(ctx.auth_verifier, now + 1000),
        auth.session_payload(authenticated_router.verifier(), now),
      ],
      fn(payload) {
        let req = signed_request(request(http.Get, "/api/books"), payload)
        assert router.handle_request(req, ctx).status == 401
      },
    )
    let req =
      request(http.Get, "/api/books")
      |> simulate.header("cookie", "vi_session=tampered")
    assert router.handle_request(req, ctx).status == 401
    let req =
      signed_request(
        request(http.Get, "/api/books"),
        auth.session_payload(ctx.auth_verifier, now),
      )
      |> wisp.set_secret_key_base(string.repeat("y", 64))
    assert router.handle_request(req, ctx).status == 401
  })
}
