//// Reading-session statistics shared between the Vanishing Ink server
//// (BEAM) and client (JavaScript). Per-book and library-wide
//// aggregates live here so the encoder on the server and the decoder
//// on the client read from one source of truth — a drift on either
//// side surfaces as a decode failure in tests rather than as a silent
//// data-shape mismatch at runtime.
////
//// Everything in this module is target-agnostic Gleam (no FFI), so
//// the same compiled code links into both packages via the shared
//// path dependency.

import gleam/dynamic/decode
import gleam/json

/// Per-book session aggregates. Returned by `GET /api/books/:id/stats`
/// and shown alongside the book on the library card and the future
/// reader header. The four fields together describe the reader's
/// engagement with one book:
///
/// * `total_words_read` — sum of `words_read` across every session.
///   Excludes Jump Lock-In words, which ride on `total_words_skipped`.
/// * `total_words_skipped` — sum of `words_skipped`. Recorded
///   separately so the UI can describe Lock-In progress honestly
///   ("you skipped 12k words to chapter 7") rather than conflating
///   it with words the reader actually consumed.
/// * `total_duration_seconds` — sum of `duration_seconds` per session.
///   Wall-clock time between session start and end, not engagement
///   time; pauses, idle taps, and tab-hidden time all count.
/// * `session_count` — number of recorded sessions, including any
///   that are still in flight (no `ended_at`). The library view uses
///   this as a coarse measure of "how often did the reader return?".
pub type BookStats {
  BookStats(
    total_words_read: Int,
    total_words_skipped: Int,
    total_duration_seconds: Int,
    session_count: Int,
  )
}

/// Library-wide session aggregates. Returned by `GET /api/stats` and
/// rendered into the library's stats overlay. Computing these
/// server-side keeps the response a constant-size payload regardless
/// of how many sessions the reader has accumulated.
///
/// * `total_words_read` — sum across every recorded session, every
///   book. Pairs with `total_duration_seconds` to surface an effective
///   words-per-minute trend without the client having to re-derive it.
/// * `total_duration_seconds` — sum of every session's wall-clock
///   duration. Used directly for the "total reading time" tile.
/// * `books_completed` — count of books whose recorded sessions
///   cover at least the full word count. A book counts as completed
///   when SUM(words_read + words_skipped) across its sessions meets or
///   exceeds the book's `word_count`; Lock-In jumps inflate
///   `words_skipped`, so a reader who jumped past every word still
///   gets credit for finishing.
/// * `current_streak_days` — number of consecutive calendar days
///   ending at the most recent session day on which at least one
///   session was started. Computed in Gleam against the distinct
///   session-day list returned by the server.
pub type LibraryStats {
  LibraryStats(
    total_words_read: Int,
    total_duration_seconds: Int,
    books_completed: Int,
    current_streak_days: Int,
  )
}

/// One sample in the reading-speed trend. Returned by
/// `GET /api/stats/speed` as a list of recent sessions in
/// reverse-chronological order (most-recent first, mirroring the SQL
/// `ORDER BY started_at DESC LIMIT N`). The client reverses the list
/// on render so the rendered polyline reads left-to-right in
/// chronological order.
///
/// * `date` — the session's `started_at` timestamp verbatim. ISO 8601
///   wall-clock string; the client renders it as a tooltip / x-axis
///   label only and does not parse it back into a date.
/// * `wpm` — effective words-per-minute, computed server-side as
///   `words_read * 60 / duration_seconds` so the client never has to
///   re-derive the rate. Integer division — fractional rates aren't
///   meaningful at the visual resolution of a 200×40 sparkline.
pub type SessionSpeed {
  SessionSpeed(date: String, wpm: Int)
}

/// Encode `BookStats` as a JSON object. Field names mirror the record
/// fields verbatim so the encoder and decoder stay symmetrical — a
/// drift on either side surfaces in tests rather than as a silent
/// shape mismatch at runtime.
pub fn book_stats_to_json(stats: BookStats) -> json.Json {
  json.object([
    #("total_words_read", json.int(stats.total_words_read)),
    #("total_words_skipped", json.int(stats.total_words_skipped)),
    #("total_duration_seconds", json.int(stats.total_duration_seconds)),
    #("session_count", json.int(stats.session_count)),
  ])
}

/// Encode one `(book_id, BookStats)` pair as a JSON object the bulk
/// per-book stats endpoint uses. The flat shape (`book_id` at the
/// top level alongside the aggregate fields) keeps the wire form a
/// single object per book, which the client can drop into a `Dict`
/// keyed by id without an intermediate `stats` nesting level.
pub fn book_stats_entry_to_json(entry: #(String, BookStats)) -> json.Json {
  let #(book_id, stats) = entry
  json.object([
    #("book_id", json.string(book_id)),
    #("total_words_read", json.int(stats.total_words_read)),
    #("total_words_skipped", json.int(stats.total_words_skipped)),
    #("total_duration_seconds", json.int(stats.total_duration_seconds)),
    #("session_count", json.int(stats.session_count)),
  ])
}

/// Decoder for one element of the bulk per-book stats response.
/// Symmetric with `book_stats_entry_to_json`.
pub fn book_stats_entry_decoder() -> decode.Decoder(#(String, BookStats)) {
  use book_id <- decode.field("book_id", decode.string)
  use total_words_read <- decode.field("total_words_read", decode.int)
  use total_words_skipped <- decode.field("total_words_skipped", decode.int)
  use total_duration_seconds <- decode.field(
    "total_duration_seconds",
    decode.int,
  )
  use session_count <- decode.field("session_count", decode.int)
  decode.success(#(
    book_id,
    BookStats(
      total_words_read: total_words_read,
      total_words_skipped: total_words_skipped,
      total_duration_seconds: total_duration_seconds,
      session_count: session_count,
    ),
  ))
}

/// Encode `LibraryStats` as a JSON object. Mirrors `book_stats_to_json`
/// in shape and convention.
pub fn library_stats_to_json(stats: LibraryStats) -> json.Json {
  json.object([
    #("total_words_read", json.int(stats.total_words_read)),
    #("total_duration_seconds", json.int(stats.total_duration_seconds)),
    #("books_completed", json.int(stats.books_completed)),
    #("current_streak_days", json.int(stats.current_streak_days)),
  ])
}

/// Decoder for `BookStats`. Used by the client; symmetric with
/// `book_stats_to_json` so a future schema migration only has to
/// touch one paired set of fields.
pub fn book_stats_decoder() -> decode.Decoder(BookStats) {
  use total_words_read <- decode.field("total_words_read", decode.int)
  use total_words_skipped <- decode.field("total_words_skipped", decode.int)
  use total_duration_seconds <- decode.field(
    "total_duration_seconds",
    decode.int,
  )
  use session_count <- decode.field("session_count", decode.int)
  decode.success(BookStats(
    total_words_read: total_words_read,
    total_words_skipped: total_words_skipped,
    total_duration_seconds: total_duration_seconds,
    session_count: session_count,
  ))
}

/// Decoder for `LibraryStats`. Symmetric with `library_stats_to_json`.
pub fn library_stats_decoder() -> decode.Decoder(LibraryStats) {
  use total_words_read <- decode.field("total_words_read", decode.int)
  use total_duration_seconds <- decode.field(
    "total_duration_seconds",
    decode.int,
  )
  use books_completed <- decode.field("books_completed", decode.int)
  use current_streak_days <- decode.field("current_streak_days", decode.int)
  decode.success(LibraryStats(
    total_words_read: total_words_read,
    total_duration_seconds: total_duration_seconds,
    books_completed: books_completed,
    current_streak_days: current_streak_days,
  ))
}

/// Encode a `SessionSpeed` sample as a JSON object. Field names mirror
/// the record fields verbatim so the encoder and decoder stay
/// symmetrical — a drift on either side surfaces in tests rather than
/// as a silent shape mismatch at runtime.
pub fn session_speed_to_json(sample: SessionSpeed) -> json.Json {
  json.object([
    #("date", json.string(sample.date)),
    #("wpm", json.int(sample.wpm)),
  ])
}

/// Decoder for `SessionSpeed`. Symmetric with `session_speed_to_json`.
pub fn session_speed_decoder() -> decode.Decoder(SessionSpeed) {
  use date <- decode.field("date", decode.string)
  use wpm <- decode.field("wpm", decode.int)
  decode.success(SessionSpeed(date: date, wpm: wpm))
}

/// Compute the current reading streak from a list of distinct session
/// days (YYYY-MM-DD) and today's date. The streak is the longest run
/// of consecutive calendar days ending at the most recent session day
/// — if today has a session it extends the run, and if today is the
/// day after the most recent session day the streak still counts
/// because the reader hasn't broken it yet. A gap of two or more days
/// drops the streak to zero.
///
/// `session_days` must be sorted descending (most recent first), which
/// matches the order returned by `db.get_session_days`. `today` is the
/// `YYYY-MM-DD` prefix of the wall-clock day at handler time.
///
/// Pure Gleam so the streak calculation can be unit-tested without
/// standing up a database. Date arithmetic for "is X the day after
/// Y?" is supplied by the caller through `is_next_day`, keeping this
/// module free of target-specific FFI; the server passes the Erlang
/// `calendar` wrapper, the client (today, never) would pass a JS
/// equivalent.
pub fn compute_current_streak_days(
  session_days session_days: List(String),
  today today: String,
  is_next_day is_next_day: fn(String, String) -> Bool,
) -> Int {
  case session_days {
    [] -> 0
    [most_recent, ..rest] -> {
      // The streak counts only when the most recent session day is
      // today or yesterday. A gap of two or more days breaks the run
      // — the reader didn't read yesterday, so they have no live
      // streak to continue.
      case most_recent == today || is_next_day(most_recent, today) {
        True -> 1 + count_consecutive_days(most_recent, rest, is_next_day)
        False -> 0
      }
    }
  }
}

/// Walk a descending list of session days, counting how many are
/// consecutive going back from `anchor`. Stops at the first gap.
fn count_consecutive_days(
  anchor: String,
  remaining: List(String),
  is_next_day: fn(String, String) -> Bool,
) -> Int {
  case remaining {
    [] -> 0
    [next, ..rest] ->
      case is_next_day(next, anchor) {
        True -> 1 + count_consecutive_days(next, rest, is_next_day)
        False -> 0
      }
  }
}
