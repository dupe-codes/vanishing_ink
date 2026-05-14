//// Vanishing Ink server entry point. Opens the SQLite database, runs
//// the schema migration, configures Wisp logging, starts the Mist HTTP
//// listener on port 3000, and hands incoming requests to the router
//// with the database connection and client asset directory baked into
//// the context. The BEAM server is the single HTTP origin — it serves
//// both the API and the Lustre client bundle. The Erlang VM is parked
//// with `process.sleep_forever` so the server stays up after `main`
//// returns.

import gleam/erlang/process
import gleam/string
import mist
import server/db
import server/router
import server/web
import wisp
import wisp/wisp_mist

const port = 3000

/// Bind address. `0.0.0.0` listens on all network interfaces so the
/// app is reachable from other devices on the LAN (e.g. a phone on
/// the same WiFi).
const host = "0.0.0.0"

/// SQLite database file. Relative to the server's working directory so
/// development and production runs both end up with a co-located store.
const database_path = "./vanishing_ink.db"

/// Path to the Lustre client build output, relative to the server's
/// working directory.
const static_dir = "../client/dist"

pub fn main() -> Nil {
  wisp.configure_logger()

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

  // In a real deployment this would be loaded from the environment so
  // session keys survive restarts. A fresh random key is fine for the
  // single-process hello-world stage.
  let secret_key_base = wisp.random_string(64)

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
