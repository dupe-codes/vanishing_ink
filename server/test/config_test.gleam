//// Unit tests for `server/config`. These exercise the pure parse seams
//// in isolation: the env-parse branching used to be inlined in
//// `server.main` and had no test coverage. Each seam takes the raw
//// `Result(String, Nil)` directly, so no environment manipulation is
//// needed and the tests stay deterministic.
////
//// Coverage spans three seams, each with the same fail-fast contract
//// (unset -> default, set-but-invalid -> Error, set-valid -> value):
////   - `parse_port`           — unset, valid, both range edges,
////                              malformed, zero, negative, too-large.
////   - `parse_non_empty`      — unset, explicitly-empty, set value.
////   - `parse_secret_key_base`— unset (random mint), empty, set value.

import server/config

// An unset PORT (`envoy.get` returns `Error(Nil)`) falls back to the
// historical dev default of 3000 rather than erroring.
pub fn parse_port_unset_uses_default_test() {
  assert config.parse_port(Error(Nil)) == Ok(3000)
}

// A well-formed numeric PORT inside the valid range parses through.
pub fn parse_port_valid_test() {
  assert config.parse_port(Ok("8080")) == Ok(8080)
}

// The lower and upper edges of the TCP range are accepted.
pub fn parse_port_boundaries_test() {
  assert config.parse_port(Ok("1")) == Ok(1)
  assert config.parse_port(Ok("65535")) == Ok(65_535)
}

// A non-numeric PORT fails fast instead of silently binding the default.
// The offending value is echoed back so the operator can see what they
// set.
pub fn parse_port_malformed_test() {
  assert config.parse_port(Ok("80a0")) == Error("PORT is not an integer: 80a0")
}

// Zero parses as an integer but is not a usable bind port — `mist.port(0)`
// would request an OS-ephemeral port, nonsense in production — so it is
// rejected as out of range.
pub fn parse_port_zero_rejected_test() {
  assert config.parse_port(Ok("0")) == Error("PORT must be in 1..65535, got: 0")
}

// A negative PORT is below the valid range.
pub fn parse_port_negative_rejected_test() {
  assert config.parse_port(Ok("-1"))
    == Error("PORT must be in 1..65535, got: -1")
}

// A PORT above the 16-bit ceiling is rejected.
pub fn parse_port_too_large_rejected_test() {
  assert config.parse_port(Ok("70000"))
    == Error("PORT must be in 1..65535, got: 70000")
}

// An unset string var falls back to its supplied default rather than
// erroring — this is the path `load_config` takes in dev with no env set.
pub fn parse_non_empty_unset_uses_default_test() {
  assert config.parse_non_empty("HOST", Error(Nil), "0.0.0.0") == Ok("0.0.0.0")
}

// An explicitly-empty value fails fast instead of passing through to blow
// up later (e.g. at `mist.bind`). The var name is echoed so the operator
// can see which one is wrong.
pub fn parse_non_empty_empty_rejected_test() {
  assert config.parse_non_empty("HOST", Ok(""), "0.0.0.0")
    == Error("HOST must not be empty")
}

// A non-empty set value is used as-is, overriding the default.
pub fn parse_non_empty_set_test() {
  assert config.parse_non_empty("HOST", Ok("127.0.0.1"), "0.0.0.0")
    == Ok("127.0.0.1")
}

// An unset SECRET_KEY_BASE mints a random dev key. The value is random so
// it cannot be asserted exactly; we assert only that a non-empty key is
// produced, which is the property that matters for signing cookies.
pub fn parse_secret_key_base_unset_mints_random_test() {
  let assert Ok(secret) = config.parse_secret_key_base(Error(Nil))
  assert secret != ""
}

// An explicitly-empty SECRET_KEY_BASE is a security hole, not a usable
// default, so it fails fast rather than minting one or passing through.
pub fn parse_secret_key_base_empty_rejected_test() {
  assert config.parse_secret_key_base(Ok(""))
    == Error("SECRET_KEY_BASE must not be empty")
}

// A set SECRET_KEY_BASE is used as-is so it survives restarts.
pub fn parse_secret_key_base_set_test() {
  assert config.parse_secret_key_base(Ok("deadbeef")) == Ok("deadbeef")
}
