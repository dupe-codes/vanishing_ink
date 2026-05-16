//// HTTP handlers for `/api/books/:id/state`. Lifted out of
//// `server/router` so the routing module stays under the file
//// budget and the reading-state axis of change lives behind one
//// module boundary.
////
//// The PUT handler is the canonical decode → validate → write
//// pattern documented elsewhere in the codebase: it pairs the
//// `reading_state` upsert with the `books.last_read_at` stamp inside
//// one SQLite transaction, and both writes are guarded by the SQL-
//// level last-write-wins predicate so a stale PUT cannot regress
//// either view.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{Get, Put}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/clock
import server/db
import server/types.{type ReadingState, ReadingState}
import server/web.{type Context}
import shared
import wisp.{type Request, type Response}

/// Closed vocabulary for `reading_state.mode`. The schema defaults to
/// `'manual'` and the empty-state synthesis emits `"manual"`; new
/// values must be added here before the router will accept them.
const reading_state_modes: List(String) = ["manual", "ghost"]

/// Dispatcher for `/api/books/:id/state`. Routes GET / PUT to the
/// matching handler and returns 405 for anything else.
pub fn handle(req: Request, ctx: Context, id: String) -> Response {
  case req.method {
    Put -> put_reading_state_handler(req, ctx, id)
    Get -> get_reading_state_handler(ctx, id)
    _ -> wisp.method_not_allowed([Get, Put])
  }
}

fn put_reading_state_handler(
  req: Request,
  ctx: Context,
  id: String,
) -> Response {
  use body <- wisp.require_json(req)

  case decode.run(body, reading_state_input_decoder()) {
    Error(errors) -> wisp.bad_request(web.describe_decode_errors(errors))
    Ok(input) ->
      case validate_reading_state_input(input) {
        Error(detail) -> wisp.bad_request(detail)
        Ok(validated) ->
          case decode_bitsets(validated) {
            Error(detail) -> wisp.bad_request(detail)
            Ok(#(sentence_bitset, word_bitset)) ->
              persist_reading_state(
                ctx,
                id,
                validated.mode,
                sentence_bitset,
                word_bitset,
                validated.current_page,
                validated.percent_progress,
                validated.updated_at,
              )
          }
      }
  }
}

/// Refuse inputs that the SQL layer would otherwise accept silently:
/// `mode` must come from the closed vocabulary, `updated_at` must be
/// a parseable ISO 8601 timestamp, and `current_page` must be a
/// non-negative integer. The returned record carries the CANONICALISED
/// `updated_at` (`YYYY-MM-DDTHH:MM:SSZ`) so the SQL-side lexicographic
/// comparison in `update_reading_state` matches chronological order
/// regardless of how the client formatted the input — and so a
/// malformed value like `"ZZZZ"` cannot wedge the row.
fn validate_reading_state_input(
  input: ReadingStateInput,
) -> Result(ReadingStateInput, String) {
  use mode <- result.try(validate_mode(input.mode))
  use updated_at <- result.try(validate_updated_at(input.updated_at))
  use current_page <- result.try(validate_current_page(input.current_page))
  use percent_progress <- result.try(validate_percent_progress(
    input.percent_progress,
  ))
  Ok(
    ReadingStateInput(
      ..input,
      mode: mode,
      updated_at: updated_at,
      current_page: current_page,
      percent_progress: percent_progress,
    ),
  )
}

fn validate_mode(mode: String) -> Result(String, String) {
  case list.contains(reading_state_modes, mode) {
    True -> Ok(mode)
    False ->
      Error("mode must be one of: " <> string.join(reading_state_modes, ", "))
  }
}

fn validate_updated_at(updated_at: String) -> Result(String, String) {
  case clock.parse_iso8601(updated_at) {
    Ok(canonical) -> Ok(canonical)
    Error(_) -> Error("updated_at must be an ISO 8601 timestamp")
  }
}

fn validate_current_page(current_page: Int) -> Result(Int, String) {
  case current_page >= 0 {
    True -> Ok(current_page)
    False -> Error("current_page must be a non-negative integer")
  }
}

/// Refuse `percent_progress` values outside `[0.0, 100.0]`. The
/// client computes the percentage as `(current_page + 1) / total_pages
/// * 100`, which is mathematically inside the range, but the wire is
/// untrusted — a future bug (or a hand-crafted PUT) that posted a
/// negative or > 100 value would otherwise persist a garbage figure
/// that the library card would happily render. Clamping at the
/// boundary keeps the on-disk value within the same `[0, 100]` scale
/// the rest of the surface assumes.
///
/// The two range conditions are split into nested `case` arms (rather
/// than checked with a compound `&&`) so the structure matches the
/// adjacent validators (`validate_current_page`,
/// `validate_updated_at`) and aligns with the TigerStyle preference
/// for single-condition arms — every test the validator runs lives on
/// its own line and fails to its own error path.
fn validate_percent_progress(percent_progress: Float) -> Result(Float, String) {
  case percent_progress >=. 0.0 {
    False -> Error("percent_progress must be a float in the range [0, 100]")
    True ->
      case percent_progress <=. 100.0 {
        False -> Error("percent_progress must be a float in the range [0, 100]")
        True -> Ok(percent_progress)
      }
  }
}

fn persist_reading_state(
  ctx: Context,
  id: String,
  mode: String,
  sentence_bitset: Option(BitArray),
  word_bitset: Option(BitArray),
  current_page: Int,
  percent_progress: Float,
  updated_at: String,
) -> Response {
  // Existence-check the book first so the FK violation never reaches
  // the SQLite layer — and so a missing book maps to a clean 404
  // instead of an opaque 500.
  case db.get_book(ctx.db, id) {
    Error(error) -> web.db_error_response("db.get_book", error)
    Ok(None) -> wisp.not_found()
    Ok(Some(_)) -> {
      // Tie the `reading_state` upsert and the `books.last_read_at`
      // stamp together: both writes either land or both abort.
      // Without the transaction, a failed second write would leave a
      // freshly-upserted reading_state row alongside a stale
      // `books.last_read_at`. The LWW guard in
      // `db.set_book_last_read_at` additionally protects against the
      // stale-write case — when the `reading_state` upsert is rejected
      // for being older than the on-disk row, the books stamp is also
      // rejected, so the two views can never disagree.
      let write_result =
        db.transaction(ctx.db, fn() {
          use _ <- result.try(db.update_reading_state(
            ctx.db,
            book_id: id,
            mode: mode,
            sentence_bitset: sentence_bitset,
            word_bitset: word_bitset,
            current_page: current_page,
            percent_progress: percent_progress,
            updated_at: updated_at,
          ))
          db.set_book_last_read_at(ctx.db, id: id, last_read_at: updated_at)
        })
      case write_result {
        Error(error) -> web.db_error_response("db.persist_reading_state", error)
        Ok(Nil) ->
          // Re-read so the client sees the authoritative state — if
          // the last-write-wins guard rejected the write, the
          // response still reflects whatever's on disk.
          case db.get_reading_state(ctx.db, id) {
            Error(error) -> web.db_error_response("db.get_reading_state", error)
            Ok(None) -> {
              wisp.log_error(
                "reading_state vanished immediately after upsert for book "
                <> id,
              )
              wisp.internal_server_error()
            }
            Ok(Some(state)) -> {
              let body =
                types.reading_state_to_json(state)
                |> json.to_string
              wisp.json_response(body, 200)
            }
          }
      }
    }
  }
}

fn get_reading_state_handler(ctx: Context, id: String) -> Response {
  case db.get_book(ctx.db, id) {
    Error(error) -> web.db_error_response("db.get_book", error)
    Ok(None) -> wisp.not_found()
    Ok(Some(_)) ->
      case db.get_reading_state(ctx.db, id) {
        Error(error) -> web.db_error_response("db.get_reading_state", error)
        // A book with no recorded reading state surfaces as an empty
        // default; that's simpler for the client than a 404 because
        // every book starts with no reading progress.
        Ok(None) -> {
          let body =
            types.reading_state_to_json(empty_reading_state(id))
            |> json.to_string
          wisp.json_response(body, 200)
        }
        Ok(Some(state)) -> {
          let body =
            types.reading_state_to_json(state)
            |> json.to_string
          wisp.json_response(body, 200)
        }
      }
  }
}

/// Synthesised "fresh book" reading state. `updated_at` is `None`
/// because nothing has been written yet — emitting `null` on the wire
/// is more honest than the previous `"1970-01-01T00:00:00Z"` sentinel,
/// which the client would have to know about (or echo back verbatim,
/// risking a real-but-stale persisted timestamp).
fn empty_reading_state(book_id: shared.BookId) -> ReadingState {
  ReadingState(
    book_id: book_id,
    mode: "manual",
    sentence_bitset: None,
    word_bitset: None,
    current_page: 0,
    percent_progress: 0.0,
    updated_at: None,
  )
}

type ReadingStateInput {
  ReadingStateInput(
    mode: String,
    sentence_bitset: Option(String),
    word_bitset: Option(String),
    current_page: Int,
    percent_progress: Float,
    updated_at: String,
  )
}

fn reading_state_input_decoder() -> decode.Decoder(ReadingStateInput) {
  use mode <- decode.field("mode", decode.string)
  use sentence_bitset <- decode.optional_field(
    "sentence_bitset",
    None,
    decode.optional(decode.string),
  )
  use word_bitset <- decode.optional_field(
    "word_bitset",
    None,
    decode.optional(decode.string),
  )
  use current_page <- decode.field("current_page", decode.int)
  // `optional_field` with `0.0` as the default keeps the API
  // backwards-compatible during the page-based-progress rollout: an
  // older client that hasn't been redeployed yet can still PUT a
  // reading state, and the server will persist `percent_progress = 0`
  // until the next save from a newer client overwrites it.
  use percent_progress <- decode.optional_field(
    "percent_progress",
    0.0,
    decode.float,
  )
  use updated_at <- decode.field("updated_at", decode.string)
  decode.success(ReadingStateInput(
    mode: mode,
    sentence_bitset: sentence_bitset,
    word_bitset: word_bitset,
    current_page: current_page,
    percent_progress: percent_progress,
    updated_at: updated_at,
  ))
}

fn decode_bitsets(
  input: ReadingStateInput,
) -> Result(#(Option(BitArray), Option(BitArray)), String) {
  use sentence_bitset <- result.try(decode_optional_base64(
    "sentence_bitset",
    input.sentence_bitset,
  ))
  use word_bitset <- result.try(decode_optional_base64(
    "word_bitset",
    input.word_bitset,
  ))
  Ok(#(sentence_bitset, word_bitset))
}

fn decode_optional_base64(
  field_name: String,
  value: Option(String),
) -> Result(Option(BitArray), String) {
  case value {
    None -> Ok(None)
    Some(encoded) ->
      case bit_array.base64_decode(encoded) {
        Ok(bytes) -> Ok(Some(bytes))
        Error(_) -> Error(field_name <> " is not valid base64")
      }
  }
}
