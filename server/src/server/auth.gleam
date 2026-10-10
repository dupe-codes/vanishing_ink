import gleam/bit_array
import gleam/crypto
import gleam/http.{Get, Head}
import gleam/http/response
import gleam/int
import gleam/result
import gleam/string
import wisp

pub const cookie_name = "vi_session"

pub const session_lifetime = 5_184_000

pub opaque type Verifier {
  Verifier(salt: BitArray, digest: BitArray, fingerprint: String)
}

pub type Throttle

@external(erlang, "vanishing_ink_auth_ffi", "new_throttle")
pub fn new_throttle() -> Throttle

@external(erlang, "vanishing_ink_auth_ffi", "admit")
pub fn admit(throttle: Throttle) -> Bool

@external(erlang, "vanishing_ink_auth_ffi", "now_seconds")
pub fn now_seconds() -> Int

@external(erlang, "vanishing_ink_auth_ffi", "derive_bounded")
fn derive_bounded(
  password: String,
  salt: BitArray,
  throttle: Throttle,
) -> Result(BitArray, Nil)

pub fn parse_verifier(raw: String) -> Result(Verifier, Nil) {
  case string.split(raw, "$") {
    ["pbkdf2-sha256", "600000", salt, digest] -> {
      use salt <- result.try(bit_array.base64_decode(salt))
      use digest <- result.try(bit_array.base64_decode(digest))
      case bit_array.byte_size(salt), bit_array.byte_size(digest) {
        16, 32 -> {
          let fingerprint =
            crypto.hash(crypto.Sha256, bit_array.append(salt, digest))
            |> bit_array.base64_url_encode(False)
          Ok(Verifier(salt, digest, fingerprint))
        }
        _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

pub fn verify_login(
  password: String,
  verifier: Verifier,
  throttle: Throttle,
) -> Result(Bool, Nil) {
  case string.byte_size(password) {
    0 -> Ok(False)
    size if size > 1024 -> Ok(False)
    _ -> {
      use digest <- result.try(derive_bounded(password, verifier.salt, throttle))
      Ok(crypto.secure_compare(digest, verifier.digest))
    }
  }
}

pub fn session_payload(verifier: Verifier, issued_at: Int) -> String {
  "v1:" <> int.to_string(issued_at) <> ":" <> verifier.fingerprint
}

pub fn valid_payload(payload: String, verifier: Verifier, now: Int) -> Bool {
  case string.split(payload, ":") {
    ["v1", issued_at, fingerprint] if fingerprint == verifier.fingerprint ->
      case int.parse(issued_at) {
        Ok(issued_at) if issued_at < 0 -> False
        Ok(issued_at) if issued_at > now -> False
        Ok(issued_at) -> now - issued_at < session_lifetime
        _ -> False
      }
    _ -> False
  }
}

pub fn authenticated(req: wisp.Request, verifier: Verifier) -> Bool {
  case wisp.get_cookie(req, cookie_name, wisp.Signed) {
    Ok(payload) -> valid_payload(payload, verifier, now_seconds())
    Error(_) -> False
  }
}

pub fn require_auth(
  req: wisp.Request,
  verifier: Verifier,
  next: fn() -> wisp.Response,
) -> wisp.Response {
  let outcome = case wisp.path_segments(req), req.method {
    ["login"], _ -> next()
    ["api", "status"], Get | ["api", "status"], Head -> next()
    _, _ ->
      case authenticated(req, verifier) {
        True -> next()
        False ->
          case wisp.path_segments(req) {
            ["api", ..] ->
              wisp.json_response("{\"error\":\"unauthorized\"}", 401)
            _ -> wisp.redirect("/login")
          }
      }
  }
  response.set_header(outcome, "cache-control", "private, no-store")
}
