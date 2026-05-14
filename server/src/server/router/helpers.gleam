//// Shared helpers for the HTTP router. `describe_decode_errors` and
//// `db_error_response` were carved out of `server/router.gleam` when
//// per-feature submodules under `server/router/` started to need them
//// too — keeping them in the dispatcher would force submodules to
//// import the dispatcher, which closes an import cycle.

import gleam/dynamic/decode
import gleam/list
import gleam/string
import sqlight
import wisp.{type Response}

/// Render every decode failure on a single line. Reporting only the
/// first error meant a client missing two fields had to fix one,
/// re-request, then learn about the second; rolling them all up
/// removes that round-trip.
pub fn describe_decode_errors(errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> "invalid JSON body"
    _ ->
      errors
      |> list.map(describe_decode_error)
      |> string.join("; ")
  }
}

fn describe_decode_error(error: decode.DecodeError) -> String {
  let decode.DecodeError(expected, found, path) = error
  let path_str = case path {
    [] -> "<root>"
    _ -> string.join(path, ".")
  }
  "expected " <> expected <> " at " <> path_str <> " but found " <> found
}

/// Log a SQLite error with operator-visible context, then return the
/// generic 500. Centralised so every call site has the same shape
/// (operation tag plus a structured Sqlight error inspection) and no
/// future error path can silently drop the trail.
pub fn db_error_response(operation: String, error: sqlight.Error) -> Response {
  wisp.log_error(operation <> " failed: " <> string.inspect(error))
  wisp.internal_server_error()
}
