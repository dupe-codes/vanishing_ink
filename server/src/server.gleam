//// Vanishing Ink server entry point. Configures Wisp logging, starts the
//// Mist HTTP listener on port 3000, and hands incoming requests to the
//// router. The Erlang VM is parked with `process.sleep_forever` so the
//// server stays up after `main` returns.

import gleam/erlang/process
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

  let assert Ok(_) =
    router.handle_request
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
