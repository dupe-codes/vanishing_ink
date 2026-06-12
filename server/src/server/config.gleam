//// Server configuration loaded from the environment. The same binary
//// runs in dev and in production; every value falls back to the
//// historical hardcoded default so `just run` is unchanged with no env
//// set. Parsing lives here, behind a pure `parse_port` seam and a thin
//// `load_config` wire-up, so the env-parse branching is unit-testable
//// rather than buried inline in `server.main`.

import envoy
import gleam/int
import gleam/result
import wisp

// Historical hardcoded defaults. Each is the value the server used
// before configuration moved to the environment, so an unset variable
// preserves the previous behaviour exactly.
const default_port = 3000

const default_host = "0.0.0.0"

const default_database_path = "./vanishing_ink.db"

const default_static_dir = "../client/dist"

// Resolved server configuration. A small record so `main` is a thin
// wire-up over a single value rather than a sequence of inline env reads.
pub type Config {
  Config(
    port: Int,
    host: String,
    database_path: String,
    static_dir: String,
    secret_key_base: String,
  )
}

// Parse the `PORT` environment variable into a validated TCP port.
//
// The three cases are kept distinct on purpose, because they mean
// different things and the house rule forbids conflating "unset" with
// "invalid":
//   - unset            -> fall back to the dev default (not an error).
//   - set but garbage  -> fail fast; a production `PORT="80a0"` must not
//                          silently bind 3000.
//   - set, out of range-> fail fast; `int.parse("0")` is `Ok(0)` and
//                          `mist.port(0)` would request an OS-ephemeral
//                          port, which is nonsense in production.
//
// `raw` is the `Result(String, Nil)` that `envoy.get` returns, passed in
// rather than read here so the function stays pure and testable.
pub fn parse_port(raw: Result(String, Nil)) -> Result(Int, String) {
  case raw {
    Error(Nil) -> Ok(default_port)
    Ok(value) ->
      case int.parse(value) {
        Error(Nil) -> Error("PORT is not an integer: " <> value)
        Ok(port) -> validate_port_range(port, value)
      }
  }
}

// Confirm a parsed port sits in the usable TCP range 1..65535. The two
// bounds are checked as nested conditions (per TigerStyle: no compound
// boolean) so each failing edge is unambiguous. `raw` is echoed back in
// the error so the operator sees what they actually set.
fn validate_port_range(port: Int, raw: String) -> Result(Int, String) {
  case port >= 1 {
    False -> Error("PORT must be in 1..65535, got: " <> raw)
    True ->
      case port <= 65_535 {
        False -> Error("PORT must be in 1..65535, got: " <> raw)
        True -> Ok(port)
      }
  }
}

// Read configuration from the environment. The only failure mode is an
// explicitly-set-but-invalid `PORT`; every other value has a safe
// default, so this returns `Error` only when production config is
// genuinely wrong and the server should refuse to boot.
pub fn load_config() -> Result(Config, String) {
  use port <- result.try(parse_port(envoy.get("PORT")))

  // `0.0.0.0` listens on all interfaces so the app is reachable from
  // other devices on the LAN (e.g. a phone on the same WiFi).
  let host = envoy.get("HOST") |> result.unwrap(default_host)

  // SQLite database file. Relative to the working directory in dev; an
  // absolute path on a mounted volume in production.
  let database_path =
    envoy.get("DATABASE_PATH") |> result.unwrap(default_database_path)

  // Path to the Lustre client build output. Relative in dev; an absolute
  // path baked into the container image in production.
  let static_dir = envoy.get("STATIC_DIR") |> result.unwrap(default_static_dir)

  // Signed-cookie key. Loaded from the environment so it survives
  // restarts and scale-to-zero. `lazy_unwrap` mints the random dev
  // default only when `SECRET_KEY_BASE` is unset — Gleam is strict, so
  // an eager `unwrap` would draw 64 random bytes on every boot even in
  // production where the env var is always set.
  let secret_key_base =
    envoy.get("SECRET_KEY_BASE")
    |> result.lazy_unwrap(fn() { wisp.random_string(64) })

  Ok(Config(
    port: port,
    host: host,
    database_path: database_path,
    static_dir: static_dir,
    secret_key_base: secret_key_base,
  ))
}
