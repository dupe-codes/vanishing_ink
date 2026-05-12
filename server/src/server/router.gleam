//// HTTP request router. For the foundation milestone the only route is
//// `GET /`, which returns a JSON liveness payload. The handler also
//// touches the shared `BookId` type so the cross-target path dependency
//// is exercised at build time.

import gleam/http.{Get}
import gleam/json
import server/web
import shared
import wisp.{type Request, type Response}

pub fn handle_request(req: Request) -> Response {
  use req <- web.middleware(req)

  case wisp.path_segments(req) {
    [] -> status(req)
    _ -> wisp.not_found()
  }
}

fn status(req: Request) -> Response {
  use <- wisp.require_method(req, Get)

  // Exercise the shared dependency from the BEAM side. The value is
  // discarded — the goal is to prove the type is reachable across the
  // worktree boundary, not to do anything meaningful with it yet.
  let _: shared.BookId = shared.book_id("placeholder")

  let body =
    json.object([#("status", json.string("ok"))])
    |> json.to_string

  wisp.json_response(body, 200)
}
