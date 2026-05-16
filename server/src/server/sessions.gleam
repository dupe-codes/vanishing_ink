//// HTTP handlers for the reading-sessions surface and the
//// per-book / library-wide statistics derived from it. Lifted out
//// of `server/router` so the routing module stays under the file
//// budget — and so the "sessions axis of change" lives behind one
//// module boundary.
////
//// Endpoints owned here:
////
////   * `POST   /api/books/:id/sessions`                — open a session
////   * `PUT    /api/books/:id/sessions/:session_id`    — close / update
////   * `GET    /api/books/:id/stats`                   — per-book aggregate
////   * `GET    /api/stats`                             — library aggregate
////
//// Each handler follows the canonical decode → validate → write
//// pattern the rest of the router uses; failures map to crisp 4xx /
//// 5xx responses through `web.describe_decode_errors` /
//// `web.db_error_response`.

import gleam/dynamic/decode
import gleam/http.{Get, Post, Put}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/clock
import server/db
import server/db_sessions
import server/types.{ReadingSession}
import server/web.{type Context}
import shared
import shared/stats
import wisp.{type Request, type Response}

// ---------------------------------------------------------------------------
// Collection — POST /api/books/:id/sessions
// ---------------------------------------------------------------------------

/// Dispatcher for `/api/books/:id/sessions`. Only POST is wired — a
/// `GET` of all sessions for a book is not exposed yet because the
/// only consumer (the library stats overlay) reads the aggregate
/// endpoint instead, and dragging a potentially long per-session
/// list over the wire on every refresh would be wasteful.
pub fn collection(req: Request, ctx: Context, book_id: String) -> Response {
  case req.method {
    Post -> post_session_handler(req, ctx, book_id)
    _ -> wisp.method_not_allowed([Post])
  }
}

/// Dispatcher for `/api/books/:id/sessions/:session_id`. The PUT closes
/// (or updates) an in-flight session. POST is accepted with the same
/// shape as PUT so the client's `pagehide`/`sendBeacon` durability
/// path can flush the closing counters — `navigator.sendBeacon` only
/// supports POST, but the handler logic is identical so the two
/// methods share one code path. There is no DELETE — sessions are
/// append-only; the client closes a session by PUTting (or POSTing
/// via the beacon path) the final counters, never by removing the row.
pub fn item(
  req: Request,
  ctx: Context,
  book_id: String,
  session_id: String,
) -> Response {
  case req.method {
    Put -> put_session_handler(req, ctx, book_id, session_id)
    Post -> put_session_handler(req, ctx, book_id, session_id)
    _ -> wisp.method_not_allowed([Put, Post])
  }
}

/// Dispatcher for `/api/books/:id/stats`. GET-only.
pub fn book_stats(req: Request, ctx: Context, book_id: String) -> Response {
  case req.method {
    Get -> get_book_stats_handler(ctx, book_id)
    _ -> wisp.method_not_allowed([Get])
  }
}

/// Dispatcher for `/api/stats`. GET-only — the library aggregates are
/// a read-only projection over `reading_sessions`.
pub fn library_stats(req: Request, ctx: Context) -> Response {
  case req.method {
    Get -> get_library_stats_handler(ctx)
    _ -> wisp.method_not_allowed([Get])
  }
}

/// Dispatcher for `/api/stats/books`. GET-only — returns one entry per
/// book with at least one recorded session so the library view can
/// surface per-card stats without N round-trips.
pub fn book_stats_collection(req: Request, ctx: Context) -> Response {
  case req.method {
    Get -> get_book_stats_collection_handler(ctx)
    _ -> wisp.method_not_allowed([Get])
  }
}

/// Dispatcher for `/api/stats/speed`. GET-only — returns the most
/// recent N session speeds (default 20) for the library stats
/// overlay's sparkline tile.
pub fn speed_trend(req: Request, ctx: Context) -> Response {
  case req.method {
    Get -> get_speed_trend_handler(ctx)
    _ -> wisp.method_not_allowed([Get])
  }
}

// ---------------------------------------------------------------------------
// Open session
// ---------------------------------------------------------------------------

type StartSessionInput {
  StartSessionInput(id: String, started_at: String)
}

fn start_session_decoder() -> decode.Decoder(StartSessionInput) {
  use id <- decode.field("id", decode.string)
  use started_at <- decode.field("started_at", decode.string)
  decode.success(StartSessionInput(id: id, started_at: started_at))
}

fn post_session_handler(
  req: Request,
  ctx: Context,
  book_id: String,
) -> Response {
  use body <- wisp.require_json(req)

  case decode.run(body, start_session_decoder()) {
    Error(errors) -> wisp.bad_request(web.describe_decode_errors(errors))
    Ok(input) ->
      case validate_start_session(input) {
        Error(detail) -> wisp.bad_request(detail)
        Ok(validated) -> persist_new_session(ctx, book_id, validated)
      }
  }
}

/// Reject inputs that the SQL layer would otherwise accept silently:
/// `id` must be non-empty (we won't let the client persist an
/// anonymous primary key) and `started_at` must canonicalise through
/// `clock.parse_iso8601` so the day-prefix slicing in
/// `db_sessions.get_session_days` produces a valid `YYYY-MM-DD`.
fn validate_start_session(
  input: StartSessionInput,
) -> Result(StartSessionInput, String) {
  use id <- result.try(validate_session_id(input.id))
  use started_at <- result.try(validate_iso8601("started_at", input.started_at))
  Ok(StartSessionInput(id: id, started_at: started_at))
}

fn validate_session_id(id: String) -> Result(String, String) {
  case string.trim(id) {
    "" -> Error("id must not be empty")
    trimmed -> Ok(trimmed)
  }
}

fn validate_iso8601(field: String, value: String) -> Result(String, String) {
  case clock.parse_iso8601(value) {
    Ok(canonical) -> Ok(canonical)
    Error(_) -> Error(field <> " must be an ISO 8601 timestamp")
  }
}

fn persist_new_session(
  ctx: Context,
  book_id: String,
  input: StartSessionInput,
) -> Response {
  // Existence-check the book first so the FK violation never reaches
  // the SQLite layer — and so a missing book maps to a clean 404
  // instead of an opaque 500.
  case db.get_book(ctx.db, book_id) {
    Error(error) -> web.db_error_response("db.get_book", error)
    Ok(None) -> wisp.not_found()
    Ok(Some(_)) -> {
      let session =
        ReadingSession(
          id: input.id,
          book_id: shared.book_id(book_id),
          started_at: input.started_at,
          ended_at: None,
          words_read: 0,
          words_skipped: 0,
          pages_turned: 0,
          duration_seconds: 0,
        )
      case db_sessions.insert_reading_session(ctx.db, session) {
        Error(error) ->
          web.db_error_response("db_sessions.insert_reading_session", error)
        Ok(Nil) -> {
          let body =
            types.reading_session_to_json(session)
            |> json.to_string
          wisp.json_response(body, 201)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Close / update session
// ---------------------------------------------------------------------------

type EndSessionInput {
  EndSessionInput(
    ended_at: Option(String),
    words_read: Int,
    words_skipped: Int,
    pages_turned: Int,
    duration_seconds: Int,
  )
}

fn end_session_decoder() -> decode.Decoder(EndSessionInput) {
  use ended_at <- decode.optional_field(
    "ended_at",
    None,
    decode.optional(decode.string),
  )
  use words_read <- decode.field("words_read", decode.int)
  use words_skipped <- decode.field("words_skipped", decode.int)
  use pages_turned <- decode.field("pages_turned", decode.int)
  use duration_seconds <- decode.field("duration_seconds", decode.int)
  decode.success(EndSessionInput(
    ended_at: ended_at,
    words_read: words_read,
    words_skipped: words_skipped,
    pages_turned: pages_turned,
    duration_seconds: duration_seconds,
  ))
}

fn put_session_handler(
  req: Request,
  ctx: Context,
  book_id: String,
  session_id: String,
) -> Response {
  use body <- wisp.require_json(req)

  case decode.run(body, end_session_decoder()) {
    Error(errors) -> wisp.bad_request(web.describe_decode_errors(errors))
    Ok(input) ->
      case validate_end_session(input) {
        Error(detail) -> wisp.bad_request(detail)
        Ok(validated) ->
          persist_session_update(ctx, book_id, session_id, validated)
      }
  }
}

/// Validate the counters and the optional `ended_at`. All four
/// counters are non-negative; `ended_at` (when present) must
/// canonicalise through `clock.parse_iso8601` so the wire form
/// stays a single shape regardless of the input's offset width.
fn validate_end_session(
  input: EndSessionInput,
) -> Result(EndSessionInput, String) {
  use _ <- result.try(require_non_negative("words_read", input.words_read))
  use _ <- result.try(require_non_negative("words_skipped", input.words_skipped))
  use _ <- result.try(require_non_negative("pages_turned", input.pages_turned))
  use _ <- result.try(require_non_negative(
    "duration_seconds",
    input.duration_seconds,
  ))
  use ended_at <- result.try(validate_optional_iso8601(
    "ended_at",
    input.ended_at,
  ))
  Ok(EndSessionInput(..input, ended_at: ended_at))
}

fn require_non_negative(field: String, value: Int) -> Result(Nil, String) {
  case value >= 0 {
    True -> Ok(Nil)
    False -> Error(field <> " must be a non-negative integer")
  }
}

fn validate_optional_iso8601(
  field: String,
  value: Option(String),
) -> Result(Option(String), String) {
  case value {
    None -> Ok(None)
    Some(raw) ->
      case clock.parse_iso8601(raw) {
        Ok(canonical) -> Ok(Some(canonical))
        Error(_) -> Error(field <> " must be an ISO 8601 timestamp")
      }
  }
}

fn persist_session_update(
  ctx: Context,
  book_id: String,
  session_id: String,
  input: EndSessionInput,
) -> Response {
  // The PUT requires both the book and the session to exist. The book
  // is checked first so a deleted-book path maps to 404 rather than
  // surfacing a row from a still-extant session against a missing
  // parent. The session check then catches an unknown id (the open-
  // POST may have been dropped, or the client raced a delete).
  case db.get_book(ctx.db, book_id) {
    Error(error) -> web.db_error_response("db.get_book", error)
    Ok(None) -> wisp.not_found()
    Ok(Some(_)) ->
      case db_sessions.get_reading_session(ctx.db, session_id) {
        Error(error) ->
          web.db_error_response("db_sessions.get_reading_session", error)
        Ok(None) -> wisp.not_found()
        Ok(Some(existing)) ->
          case existing.book_id == book_id {
            // Reject a PUT whose URL `book_id` does not match the
            // row's stored `book_id`. Without this guard a client
            // mistake (or a stale URL) could mutate a session that
            // belongs to a different book — the row's parent is
            // immutable once written.
            False -> wisp.not_found()
            True -> {
              let result =
                db_sessions.update_reading_session(
                  ctx.db,
                  id: session_id,
                  ended_at: input.ended_at,
                  words_read: input.words_read,
                  words_skipped: input.words_skipped,
                  pages_turned: input.pages_turned,
                  duration_seconds: input.duration_seconds,
                )
              case result {
                Error(error) ->
                  web.db_error_response(
                    "db_sessions.update_reading_session",
                    error,
                  )
                Ok(Nil) -> {
                  let updated =
                    ReadingSession(
                      ..existing,
                      ended_at: input.ended_at,
                      words_read: input.words_read,
                      words_skipped: input.words_skipped,
                      pages_turned: input.pages_turned,
                      duration_seconds: input.duration_seconds,
                    )
                  let body =
                    types.reading_session_to_json(updated)
                    |> json.to_string
                  wisp.json_response(body, 200)
                }
              }
            }
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Per-book aggregate
// ---------------------------------------------------------------------------

fn get_book_stats_handler(ctx: Context, book_id: String) -> Response {
  // Existence-check the book first so a missing id maps to a clean
  // 404 rather than the all-zero stats payload that a no-row aggregate
  // would otherwise surface. The all-zero record means "book exists,
  // no sessions yet" — distinguishing the two cases helps the client
  // distinguish a deleted book from an untouched one.
  case db.get_book(ctx.db, book_id) {
    Error(error) -> web.db_error_response("db.get_book", error)
    Ok(None) -> wisp.not_found()
    Ok(Some(_)) ->
      case db_sessions.get_book_stats(ctx.db, book_id) {
        Error(error) ->
          web.db_error_response("db_sessions.get_book_stats", error)
        Ok(stats_record) -> {
          let body =
            stats.book_stats_to_json(stats_record)
            |> json.to_string
          wisp.json_response(body, 200)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Library aggregate
// ---------------------------------------------------------------------------

fn get_book_stats_collection_handler(ctx: Context) -> Response {
  case db_sessions.get_all_book_stats(ctx.db) {
    Error(error) ->
      web.db_error_response("db_sessions.get_all_book_stats", error)
    Ok(entries) -> {
      let body =
        json.array(entries, stats.book_stats_entry_to_json)
        |> json.to_string
      wisp.json_response(body, 200)
    }
  }
}

/// Cap the response size at twenty recent sessions. Two dozen samples
/// is plenty to read a trend across a 200×40-pixel sparkline; beyond
/// that the polyline starts compressing into a horizontal line and the
/// payload size grows for no visual benefit.
const speed_trend_limit: Int = 20

fn get_speed_trend_handler(ctx: Context) -> Response {
  case db_sessions.get_recent_session_speeds(ctx.db, speed_trend_limit) {
    Error(error) ->
      web.db_error_response("db_sessions.get_recent_session_speeds", error)
    Ok(samples) -> {
      let body =
        json.array(samples, stats.session_speed_to_json)
        |> json.to_string
      wisp.json_response(body, 200)
    }
  }
}

fn get_library_stats_handler(ctx: Context) -> Response {
  let today = clock.today_iso8601_date()
  case db_sessions.get_session_days(ctx.db) {
    Error(error) -> web.db_error_response("db_sessions.get_session_days", error)
    Ok(days) -> {
      let streak =
        stats.compute_current_streak_days(
          session_days: days,
          today: today,
          is_next_day: clock.is_next_day,
        )
      case db_sessions.build_library_stats(ctx.db, streak) {
        Error(error) ->
          web.db_error_response("db_sessions.build_library_stats", error)
        Ok(record) -> {
          let body =
            stats.library_stats_to_json(record)
            |> json.to_string
          wisp.json_response(body, 200)
        }
      }
    }
  }
}
