//// Vanishing Ink server entry point. Opens the SQLite database, runs
//// the schema migration, configures Wisp logging, starts the Mist HTTP
//// listener on the configured port (3000 by default), and hands
//// incoming requests to the router
//// with the database connection and client asset directory baked into
//// the context. The BEAM server is the single HTTP origin — it serves
//// both the API and the Lustre client bundle. The Erlang VM is parked
//// with `process.sleep_forever` so the server stays up after `main`
//// returns.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/result
import gleam/string
import mist
import server/db
import server/router
import server/web
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  // Configuration is read from the environment so the same binary runs
  // in dev and in production. Each value falls back to the historical
  // hardcoded default, so `just run` is unchanged with no env set.
  //
  // `envoy.get` returns `Result(String, Nil)`; `int.parse` also fails
  // with `Nil`, so the PORT chain composes with `result.try`. An
  // unparseable PORT silently falls back to 3000 — acceptable for dev
  // ergonomics; production sets a valid value via fly.toml.
  let port = envoy.get("PORT") |> result.try(int.parse) |> result.unwrap(3000)

  // `0.0.0.0` listens on all network interfaces so the app is reachable
  // from other devices on the LAN (e.g. a phone on the same WiFi).
  let host = envoy.get("HOST") |> result.unwrap("0.0.0.0")

  // SQLite database file. Relative to the server's working directory in
  // dev; an absolute path on a mounted volume in production.
  let database_path =
    envoy.get("DATABASE_PATH") |> result.unwrap("./vanishing_ink.db")

  // Path to the Lustre client build output. Relative in dev; an
  // absolute path baked into the container image in production.
  let static_dir = envoy.get("STATIC_DIR") |> result.unwrap("../client/dist")

  let connection = case db.initialize(database_path) {
    Ok(connection) -> connection
    Error(error) -> {
      wisp.log_error(
        "failed to initialize SQLite at "
        <> database_path
        <> ": "
        <> string.inspect(error),
      )
      panic as "db.initialize failed; see the logged reason above"
    }
  }
  let context = web.Context(db: connection, static_dir: static_dir)

  // Loaded from the environment so signed-cookie keys survive restarts
  // and scale-to-zero. In dev (no env set) a fresh random key per boot
  // is fine; in production a stable key is injected as a Fly secret.
  let secret_key_base =
    envoy.get("SECRET_KEY_BASE") |> result.unwrap(wisp.random_string(64))

  let start_result =
    router.handle_request(_, context)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.bind(host)
    |> mist.start

  case start_result {
    Ok(_) -> process.sleep_forever()
    Error(reason) -> {
      // Port-already-in-use is the realistic failure during dev
      // iteration — log the structured reason before we panic so the
      // operator sees what actually went wrong rather than a bare
      // stack trace.
      wisp.log_error(
        "mist failed to bind port "
        <> string.inspect(port)
        <> ": "
        <> string.inspect(reason),
      )
      panic as "mist.start failed; see the logged reason above"
    }
  }
}
