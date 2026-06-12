//// Vanishing Ink server entry point. Opens the SQLite database, runs
//// the schema migration, configures Wisp logging, starts the Mist HTTP
//// listener on the configured port (3000 by default), and hands
//// incoming requests to the router
//// with the database connection and client asset directory baked into
//// the context. The BEAM server is the single HTTP origin — it serves
//// both the API and the Lustre client bundle. The Erlang VM is parked
//// with `process.sleep_forever` so the server stays up after `main`
//// returns.

import gleam/erlang/process
import gleam/string
import mist
import server/config
import server/db
import server/router
import server/web
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  // Configuration is read from the environment so the same binary runs
  // in dev and in production; see `server/config`. A malformed `PORT`
  // (or any other invalid production config) fails fast here rather than
  // silently binding a default, so the operator gets a signal instead of
  // a wrong-but-running server.
  let config = case config.load_config() {
    Ok(config) -> config
    Error(reason) -> {
      wisp.log_error("invalid server configuration: " <> reason)
      panic as "config.load_config failed; see the logged reason above"
    }
  }

  let connection = case db.initialize(config.database_path) {
    Ok(connection) -> connection
    Error(error) -> {
      wisp.log_error(
        "failed to initialize SQLite at "
        <> config.database_path
        <> ": "
        <> string.inspect(error),
      )
      panic as "db.initialize failed; see the logged reason above"
    }
  }
  let context = web.Context(db: connection, static_dir: config.static_dir)

  let start_result =
    router.handle_request(_, context)
    |> wisp_mist.handler(config.secret_key_base)
    |> mist.new
    |> mist.port(config.port)
    |> mist.bind(config.host)
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
        <> string.inspect(config.port)
        <> ": "
        <> string.inspect(reason),
      )
      panic as "mist.start failed; see the logged reason above"
    }
  }
}
