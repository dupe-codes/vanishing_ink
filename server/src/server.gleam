//// Vanishing Ink server entry point. Configures Wisp logging, starts the
//// Mist HTTP listener on port 3000, and hands incoming requests to the
//// router. The Erlang VM is parked with `process.sleep_forever` so the
//// server stays up after `main` returns.

import gleam/erlang/process
import gleam/string
import mist
import server/router
import wisp
import wisp/wisp_mist

const port = 3000

pub fn main() -> Nil {
  wisp.configure_logger()

  // In a real deployment this would be loaded from the environment so the
  // key survives restarts. A fresh random key is fine for hello world.
  let secret_key_base = wisp.random_string(64)

  let start_result =
    router.handle_request
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  case start_result {
    Ok(_) -> process.sleep_forever()
    Error(reason) -> {
      // Port-already-in-use is the realistic failure during dev iteration —
      // log the structured reason before we panic so the operator sees what
      // actually went wrong rather than a bare stack trace.
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
