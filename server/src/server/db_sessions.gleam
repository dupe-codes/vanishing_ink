//// SQLite query layer for the `reading_sessions` table and its
//// derived aggregates. Lifted out of `server/db` so the central DB
//// module stays within the file budget while the schema /
//// transaction helpers / cascade convention continue to live in one
//// place.
////
//// The schema for `reading_sessions` is owned by `server/db`
//// (`schema_sql`) — every query here addresses columns by their
//// position-in-SELECT or by parameter binding, matching the
//// column-order decode contract documented at the top of
//// `server/db`. The cascade in `server/db.delete_book` purges rows
//// here before the parent `books` row.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import server/types.{type ReadingSession, ReadingSession}
import shared
import shared/stats.{type BookStats, type LibraryStats, BookStats, LibraryStats}
import sqlight

/// Insert a fresh `reading_sessions` row. The id is supplied by the
/// caller — the client generates a UUID before issuing the POST so the
/// follow-up PUT (and the visibilitychange-triggered end-of-session
/// PUT) can target the same row without waiting for the POST response
/// to land. A duplicate id surfaces as a SQLite `Constraint` error
/// rather than overwriting the existing row.
pub fn insert_reading_session(
  connection: sqlight.Connection,
  session: ReadingSession,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "INSERT INTO reading_sessions (
      id, book_id, started_at, ended_at,
      words_read, words_skipped, pages_turned, duration_seconds
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [
        sqlight.text(session.id),
        sqlight.text(session.book_id),
        sqlight.text(session.started_at),
        sqlight.nullable(sqlight.text, session.ended_at),
        sqlight.int(session.words_read),
        sqlight.int(session.words_skipped),
        sqlight.int(session.pages_turned),
        sqlight.int(session.duration_seconds),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// Stamp the end-of-session fields on an existing `reading_sessions`
/// row. The row must already exist — a missing id surfaces as a
/// successful zero-row update, which the caller detects via a
/// follow-up `get_reading_session` and maps to a 404. Every field
/// is overwritten unconditionally; a half-rolled session that
/// briefly disconnects and re-PUTs always sees the latest counters.
pub fn update_reading_session(
  connection: sqlight.Connection,
  id id: String,
  ended_at ended_at: Option(String),
  words_read words_read: Int,
  words_skipped words_skipped: Int,
  pages_turned pages_turned: Int,
  duration_seconds duration_seconds: Int,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "UPDATE reading_sessions SET
       ended_at = ?,
       words_read = ?,
       words_skipped = ?,
       pages_turned = ?,
       duration_seconds = ?
     WHERE id = ?;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [
        sqlight.nullable(sqlight.text, ended_at),
        sqlight.int(words_read),
        sqlight.int(words_skipped),
        sqlight.int(pages_turned),
        sqlight.int(duration_seconds),
        sqlight.text(id),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// Fetch one `reading_sessions` row by id. `Ok(None)` indicates no
/// matching row — the caller decides whether that maps to a 404.
pub fn get_reading_session(
  connection: sqlight.Connection,
  id: String,
) -> Result(Option(ReadingSession), sqlight.Error) {
  let sql =
    "SELECT id, book_id, started_at, ended_at,
            words_read, words_skipped, pages_turned, duration_seconds
       FROM reading_sessions
      WHERE id = ?;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [sqlight.text(id)],
      expecting: reading_session_decoder(),
    )
  {
    Ok([session, ..]) -> Ok(Some(session))
    Ok([]) -> Ok(None)
    Error(error) -> Error(error)
  }
}

/// Aggregate session counters for one book. Returns the all-zero
/// `BookStats` when no sessions exist; SQLite's `COALESCE(SUM, 0)`
/// folds an empty group into the same shape the populated case
/// returns, so the caller never has to branch on "any rows?".
pub fn get_book_stats(
  connection: sqlight.Connection,
  book_id: shared.BookId,
) -> Result(BookStats, sqlight.Error) {
  let sql =
    "SELECT
       COALESCE(SUM(words_read), 0),
       COALESCE(SUM(words_skipped), 0),
       COALESCE(SUM(duration_seconds), 0),
       COUNT(*)
     FROM reading_sessions
     WHERE book_id = ?;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [sqlight.text(book_id)],
      expecting: book_stats_decoder(),
    )
  {
    Ok([row, ..]) -> Ok(row)
    Ok([]) -> Ok(BookStats(0, 0, 0, 0))
    Error(error) -> Error(error)
  }
}

/// Total `(words_read, duration_seconds)` across every recorded
/// session. Aggregated server-side so a library with thousands of
/// sessions stays a constant-size payload.
pub fn get_library_session_totals(
  connection: sqlight.Connection,
) -> Result(#(Int, Int), sqlight.Error) {
  let sql =
    "SELECT
       COALESCE(SUM(words_read), 0),
       COALESCE(SUM(duration_seconds), 0)
     FROM reading_sessions;"
  let decoder = {
    use words_read <- decode.field(0, decode.int)
    use duration_seconds <- decode.field(1, decode.int)
    decode.success(#(words_read, duration_seconds))
  }
  case sqlight.query(sql, on: connection, with: [], expecting: decoder) {
    Ok([row, ..]) -> Ok(row)
    Ok([]) -> Ok(#(0, 0))
    Error(error) -> Error(error)
  }
}

/// Count of books whose recorded sessions cover at least their full
/// word count. A book counts as completed when the sum of words read
/// AND skipped across every session for that book meets or exceeds
/// `books.word_count` — Lock-In jumps inflate `words_skipped`, and a
/// reader who skipped past every word of a book has functionally
/// finished it for the purposes of this metric.
pub fn get_books_completed_count(
  connection: sqlight.Connection,
) -> Result(Int, sqlight.Error) {
  let sql =
    "SELECT COUNT(*) FROM (
       SELECT b.id
         FROM books b
         JOIN reading_sessions s ON s.book_id = b.id
        GROUP BY b.id
       HAVING COALESCE(SUM(s.words_read + s.words_skipped), 0) >= b.word_count
     );"
  let decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  case sqlight.query(sql, on: connection, with: [], expecting: decoder) {
    Ok([row, ..]) -> Ok(row)
    Ok([]) -> Ok(0)
    Error(error) -> Error(error)
  }
}

/// Per-book session aggregates for every book that has at least one
/// recorded session. Returned as `(book_id, BookStats)` pairs so the
/// caller can drop them into a `Dict` keyed by id. Books with no
/// sessions are excluded — the client treats their absence as the
/// all-zero default rather than dragging an empty row over the wire.
pub fn get_all_book_stats(
  connection: sqlight.Connection,
) -> Result(List(#(shared.BookId, BookStats)), sqlight.Error) {
  let sql =
    "SELECT
       book_id,
       COALESCE(SUM(words_read), 0),
       COALESCE(SUM(words_skipped), 0),
       COALESCE(SUM(duration_seconds), 0),
       COUNT(*)
     FROM reading_sessions
     GROUP BY book_id;"
  let decoder = {
    use book_id <- decode.field(0, decode.string)
    use words_read <- decode.field(1, decode.int)
    use words_skipped <- decode.field(2, decode.int)
    use duration_seconds <- decode.field(3, decode.int)
    use session_count <- decode.field(4, decode.int)
    decode.success(#(
      book_id,
      BookStats(
        total_words_read: words_read,
        total_words_skipped: words_skipped,
        total_duration_seconds: duration_seconds,
        session_count: session_count,
      ),
    ))
  }
  sqlight.query(sql, on: connection, with: [], expecting: decoder)
}

/// Distinct YYYY-MM-DD strings of every started session, descending.
/// Returned as raw strings so the streak computation can stay in
/// pure Gleam — date arithmetic in SQLite is uneven across dialects
/// and the in-Gleam version is straightforward to unit-test.
pub fn get_session_days(
  connection: sqlight.Connection,
) -> Result(List(String), sqlight.Error) {
  let sql =
    "SELECT DISTINCT substr(started_at, 1, 10) AS day
       FROM reading_sessions
      ORDER BY day DESC;"
  let decoder = {
    use day <- decode.field(0, decode.string)
    decode.success(day)
  }
  sqlight.query(sql, on: connection, with: [], expecting: decoder)
}

/// Aggregate `(words_read, duration_seconds, books_completed)` plus
/// the streak count given a pre-computed value. Lifted onto a single
/// helper so the router builds a `LibraryStats` from one round-trip
/// per aggregate query rather than threading the four primitives
/// through the response handler by hand.
pub fn build_library_stats(
  connection: sqlight.Connection,
  current_streak_days: Int,
) -> Result(LibraryStats, sqlight.Error) {
  use #(words_read, duration_seconds) <- result.try(get_library_session_totals(
    connection,
  ))
  use books_completed <- result.try(get_books_completed_count(connection))
  Ok(LibraryStats(
    total_words_read: words_read,
    total_duration_seconds: duration_seconds,
    books_completed: books_completed,
    current_streak_days: current_streak_days,
  ))
}

fn reading_session_decoder() -> decode.Decoder(ReadingSession) {
  use id <- decode.field(0, decode.string)
  use book_id <- decode.field(1, decode.string)
  use started_at <- decode.field(2, decode.string)
  use ended_at <- decode.field(3, decode.optional(decode.string))
  use words_read <- decode.field(4, decode.int)
  use words_skipped <- decode.field(5, decode.int)
  use pages_turned <- decode.field(6, decode.int)
  use duration_seconds <- decode.field(7, decode.int)
  decode.success(ReadingSession(
    id: id,
    book_id: book_id,
    started_at: started_at,
    ended_at: ended_at,
    words_read: words_read,
    words_skipped: words_skipped,
    pages_turned: pages_turned,
    duration_seconds: duration_seconds,
  ))
}

fn book_stats_decoder() -> decode.Decoder(BookStats) {
  use words_read <- decode.field(0, decode.int)
  use words_skipped <- decode.field(1, decode.int)
  use duration_seconds <- decode.field(2, decode.int)
  use session_count <- decode.field(3, decode.int)
  decode.success(BookStats(
    total_words_read: words_read,
    total_words_skipped: words_skipped,
    total_duration_seconds: duration_seconds,
    session_count: session_count,
  ))
}
