//// Unit tests for `server/config`. These exercise the `parse_port`
//// seam in isolation: the env-parse branching used to be inlined in
//// `server.main` and had no test coverage, so the three meaningful
//// cases — unset, malformed, out-of-range — went unverified. The
//// function takes the raw `Result(String, Nil)` directly, so no
//// environment manipulation is needed and the tests stay deterministic.

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
