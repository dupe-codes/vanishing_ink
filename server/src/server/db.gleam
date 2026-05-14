//// SQLite persistence layer for Vanishing Ink. Owns the schema, the
//// migration on-open, and every typed query the router needs. All SQL
//// runs through `sqlight.query` with parameter binding — never string
//// interpolation — and every CRUD wrapper returns a precise result
//// type so the router layer can stay free of decode boilerplate.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import server/types.{
  type Book, type BookMeta, type BookSettings, type ReadingSession,
  type ReadingState, type UserSettings, Book, BookMeta, BookSettings,
  ReadingSession, ReadingState, UserSettings,
}
import shared
import shared/stats.{type BookStats, type LibraryStats, BookStats, LibraryStats}
import sqlight

/// Default `user_settings` row id. The settings table is a single-row
/// table — using a fixed id keeps the upsert SQL simple and lets new
/// fields ride along with `ALTER TABLE` additions later.
const default_settings_id = "default"

/// Open a SQLite connection, enable WAL, and run the schema migration.
///
/// WAL gives us concurrent reads alongside a writer and survives crashes
/// better than rollback-journal mode, which is the right default for a
/// single-process desktop-style app like this one.
pub fn initialize(path: String) -> Result(sqlight.Connection, sqlight.Error) {
  use connection <- result.try(sqlight.open(path))
  use _ <- result.try(sqlight.exec(pragmas_sql, connection))
  use _ <- result.try(sqlight.exec(schema_sql, connection))
  use _ <- result.try(ensure_default_settings(connection))
  Ok(connection)
}

const pragmas_sql = "
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
"

const schema_sql = "
CREATE TABLE IF NOT EXISTS books (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT,
  raw_text TEXT NOT NULL,
  segments_json TEXT NOT NULL,
  word_count INTEGER NOT NULL,
  sentence_count INTEGER NOT NULL,
  uploaded_at TEXT NOT NULL,
  last_read_at TEXT
);

CREATE TABLE IF NOT EXISTS user_settings (
  id TEXT PRIMARY KEY DEFAULT 'default',
  font_size INTEGER NOT NULL DEFAULT 18,
  line_spacing REAL NOT NULL DEFAULT 1.6,
  dark_mode INTEGER NOT NULL DEFAULT 1,
  ghost_mode INTEGER NOT NULL DEFAULT 0,
  ghost_opacity REAL NOT NULL DEFAULT 0.06,
  default_wpm INTEGER NOT NULL DEFAULT 200,
  default_paragraph_delay_ms INTEGER NOT NULL DEFAULT 1000,
  default_page_delay_ms INTEGER NOT NULL DEFAULT 2000
);

-- NOTE: `book_settings.book_id` and `reading_state.book_id` reference
-- `books(id)` WITHOUT `ON DELETE CASCADE`. The cascade is performed
-- manually in `db.delete_book`, which deletes dependent rows before
-- the parent under a single SQLite transaction. Any NEW table that
-- adds `REFERENCES books(id)` MUST be added to `delete_book` — there
-- is no compile-time check, and `PRAGMA foreign_keys = ON` will
-- surface the omission only at runtime as a FK violation. The
-- unenforced-convention hazard is filed for a future migration that
-- moves these FKs to `ON DELETE CASCADE`.
CREATE TABLE IF NOT EXISTS book_settings (
  -- See the cascade note above the `book_settings` table: dependent
  -- rows are purged in `db.delete_book` ahead of the parent row.
  book_id TEXT PRIMARY KEY REFERENCES books(id),
  wpm INTEGER,
  paragraph_delay_ms INTEGER,
  page_delay_ms INTEGER,
  ghost_opacity REAL
);

CREATE TABLE IF NOT EXISTS reading_state (
  -- Mirrors `book_settings.book_id`: no `ON DELETE CASCADE`, manually
  -- purged in `db.delete_book` ahead of the parent `books` row.
  book_id TEXT PRIMARY KEY REFERENCES books(id),
  mode TEXT NOT NULL DEFAULT 'manual',
  sentence_bitset BLOB,
  word_bitset BLOB,
  current_page INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS reading_sessions (
  -- Mirrors the cascade note above the dependent tables. The `book_id`
  -- references `books(id)` without `ON DELETE CASCADE`; `db.delete_book`
  -- purges dependent rows manually so adding a new dependent table is
  -- a deliberate, audited change rather than a silent surprise.
  id TEXT PRIMARY KEY,
  book_id TEXT NOT NULL REFERENCES books(id),
  started_at TEXT NOT NULL,
  ended_at TEXT,
  words_read INTEGER NOT NULL DEFAULT 0,
  words_skipped INTEGER NOT NULL DEFAULT 0,
  pages_turned INTEGER NOT NULL DEFAULT 0,
  duration_seconds INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS reading_sessions_book_id_idx
  ON reading_sessions(book_id);
"

fn ensure_default_settings(
  connection: sqlight.Connection,
) -> Result(Nil, sqlight.Error) {
  // INSERT OR IGNORE: every column in `user_settings` has a SQLite
  // DEFAULT, so naming only the id keeps the row a single source of
  // truth without us having to hard-code the defaults in two places.
  let sql = "INSERT OR IGNORE INTO user_settings (id) VALUES (?);"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [sqlight.text(default_settings_id)],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

// ---------------------------------------------------------------------------
// Books
// ---------------------------------------------------------------------------
//
// COLUMN-ORDER CONTRACT: the decoders below address row columns by
// ordinal (`decode.field(0, ...)` etc.), so the `SELECT` (or `INSERT`
// column-list) sites MUST match their corresponding decoders position
// for position. Participants today: `list_books`, `get_book`,
// `get_reading_state`, `get_settings`, `update_settings`,
// `get_book_settings`, and `upsert_book_settings`. Adding a column
// means appending it to both the column list and the decoder in the
// same order. The test suite covers a round-trip of every field,
// which catches a mis-ordering as a value mismatch on the changed
// field.

/// Insert a new book row. `uploaded_at` is supplied by the caller so
/// request handlers can stamp the time once and tests can pass a fixed
/// value — the db layer never reads the clock for itself.
pub fn create_book(
  connection: sqlight.Connection,
  id id: shared.BookId,
  title title: String,
  author author: Option(String),
  raw_text raw_text: String,
  segments_json segments_json: String,
  word_count word_count: Int,
  sentence_count sentence_count: Int,
  uploaded_at uploaded_at: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "INSERT INTO books (
      id, title, author, raw_text, segments_json,
      word_count, sentence_count, uploaded_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [
        sqlight.text(id),
        sqlight.text(title),
        sqlight.nullable(sqlight.text, author),
        sqlight.text(raw_text),
        sqlight.text(segments_json),
        sqlight.int(word_count),
        sqlight.int(sentence_count),
        sqlight.text(uploaded_at),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// Return every book's metadata in upload order (newest first). The
/// raw text and segments are deliberately not selected — list views
/// don't need them and dragging the full payload back on every render
/// would dominate the response time once books are long.
pub fn list_books(
  connection: sqlight.Connection,
) -> Result(List(BookMeta), sqlight.Error) {
  let sql =
    "SELECT id, title, author, word_count, sentence_count,
            uploaded_at, last_read_at
       FROM books
   ORDER BY uploaded_at DESC;"
  sqlight.query(sql, on: connection, with: [], expecting: book_meta_decoder())
}

/// Fetch a single book by id, including the raw text and segments JSON.
/// Returns `Ok(None)` when no row matches — the caller decides whether
/// that maps to a 404.
pub fn get_book(
  connection: sqlight.Connection,
  id: shared.BookId,
) -> Result(Option(Book), sqlight.Error) {
  let sql =
    "SELECT id, title, author, raw_text, segments_json,
            word_count, sentence_count, uploaded_at, last_read_at
       FROM books
      WHERE id = ?;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [sqlight.text(id)],
      expecting: book_decoder(),
    )
  {
    Ok([book, ..]) -> Ok(Some(book))
    Ok([]) -> Ok(None)
    Error(error) -> Error(error)
  }
}

/// Stamp `books.last_read_at` for the given book with last-write-wins
/// semantics that mirror the `reading_state.updated_at` guard. A write
/// older than the value already on disk is a no-op — without this
/// gate, a stale `update_reading_state` (which the SQL guard correctly
/// rejects) would still cause `books.last_read_at` to regress, leaving
/// the two persisted views of "when the user last touched this book"
/// silently disagreeing. Returns `Ok(Nil)` whether the row was touched
/// or not; the caller has already verified the book exists.
pub fn set_book_last_read_at(
  connection: sqlight.Connection,
  id id: shared.BookId,
  last_read_at last_read_at: String,
) -> Result(Nil, sqlight.Error) {
  // Lexicographic comparison is faithful because `last_read_at` is
  // only ever written via the same canonicalised ISO 8601 path that
  // `reading_state.updated_at` uses.
  let sql =
    "UPDATE books
        SET last_read_at = ?
      WHERE id = ?
        AND (last_read_at IS NULL OR last_read_at <= ?);"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [
        sqlight.text(last_read_at),
        sqlight.text(id),
        sqlight.text(last_read_at),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// Delete a book and its dependent rows (`reading_state`, `book_settings`)
/// inside a transaction. Returns `Ok(True)` when the book existed and was
/// deleted, `Ok(False)` when the id was not found, and `Error(error)` on
/// any SQLite failure.
///
/// Dependent rows are deleted first because `PRAGMA foreign_keys = ON` is
/// set at connection time — deleting the `books` row first would raise a
/// constraint violation. The manual cascade is explicit by design; the
/// schema intentionally omits `ON DELETE CASCADE` so future tables that
/// reference `books(id)` have to opt in.
pub fn delete_book(
  connection: sqlight.Connection,
  id: shared.BookId,
) -> Result(Bool, sqlight.Error) {
  use <- transaction(connection)
  // The `reading_sessions` rows are purged ahead of the parent `books`
  // row alongside `reading_state` and `book_settings`. Same manual
  // cascade convention — see the header comment on `schema_sql`.
  use _ <- result.try(sqlight.query(
    "DELETE FROM reading_sessions WHERE book_id = ?;",
    on: connection,
    with: [sqlight.text(id)],
    expecting: decode.dynamic,
  ))
  use _ <- result.try(sqlight.query(
    "DELETE FROM reading_state WHERE book_id = ?;",
    on: connection,
    with: [sqlight.text(id)],
    expecting: decode.dynamic,
  ))
  use _ <- result.try(sqlight.query(
    "DELETE FROM book_settings WHERE book_id = ?;",
    on: connection,
    with: [sqlight.text(id)],
    expecting: decode.dynamic,
  ))
  use _ <- result.try(sqlight.query(
    "DELETE FROM books WHERE id = ?;",
    on: connection,
    with: [sqlight.text(id)],
    expecting: decode.dynamic,
  ))
  // `changes()` reports how many rows the immediately preceding DML
  // statement touched — 1 if the book existed, 0 if the id was unknown.
  let count_decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  sqlight.query(
    "SELECT changes();",
    on: connection,
    with: [],
    expecting: count_decoder,
  )
  |> result.map(fn(rows) {
    case rows {
      [count, ..] -> count > 0
      [] -> False
    }
  })
}

/// Run a closure inside a SQLite transaction. On `Ok` the transaction
/// commits; on `Error` (or a panic that escapes the closure) it rolls
/// back. `BEGIN IMMEDIATE` acquires the write lock up front so a slow
/// commit can't be wedged behind a concurrent reader-turned-writer.
///
/// Used to tie the two reading-state writes together: the
/// `reading_state` upsert and the `books.last_read_at` stamp must
/// either both apply or both abort, so disk pressure on the second
/// statement can never leave the row pair in a half-written state.
pub fn transaction(
  connection: sqlight.Connection,
  body: fn() -> Result(a, sqlight.Error),
) -> Result(a, sqlight.Error) {
  use _ <- result.try(sqlight.exec("BEGIN IMMEDIATE;", connection))
  case body() {
    Ok(value) -> {
      use _ <- result.try(sqlight.exec("COMMIT;", connection))
      Ok(value)
    }
    Error(error) -> {
      // Best-effort rollback. If the rollback itself fails we still
      // surface the original error — the transaction is doomed either
      // way, and the original cause is more useful for diagnosis.
      let _ = sqlight.exec("ROLLBACK;", connection)
      Error(error)
    }
  }
}

fn book_meta_decoder() -> decode.Decoder(BookMeta) {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use author <- decode.field(2, decode.optional(decode.string))
  use word_count <- decode.field(3, decode.int)
  use sentence_count <- decode.field(4, decode.int)
  use uploaded_at <- decode.field(5, decode.string)
  use last_read_at <- decode.field(6, decode.optional(decode.string))
  decode.success(BookMeta(
    id: id,
    title: title,
    author: author,
    word_count: word_count,
    sentence_count: sentence_count,
    uploaded_at: uploaded_at,
    last_read_at: last_read_at,
  ))
}

fn book_decoder() -> decode.Decoder(Book) {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use author <- decode.field(2, decode.optional(decode.string))
  use raw_text <- decode.field(3, decode.string)
  use segments_json <- decode.field(4, decode.string)
  use word_count <- decode.field(5, decode.int)
  use sentence_count <- decode.field(6, decode.int)
  use uploaded_at <- decode.field(7, decode.string)
  use last_read_at <- decode.field(8, decode.optional(decode.string))
  decode.success(Book(
    id: id,
    title: title,
    author: author,
    raw_text: raw_text,
    segments_json: segments_json,
    word_count: word_count,
    sentence_count: sentence_count,
    uploaded_at: uploaded_at,
    last_read_at: last_read_at,
  ))
}

// ---------------------------------------------------------------------------
// Reading state
// ---------------------------------------------------------------------------

/// Upsert a row in `reading_state` with last-write-wins semantics. The
/// `WHERE excluded.updated_at >= reading_state.updated_at` predicate
/// makes a stale write (one whose timestamp is older than the row on
/// disk) a no-op — the on-disk row stays unchanged. Returns `Ok(Nil)`
/// whether the row was written or skipped; the caller can re-`get` to
/// observe the canonical state.
pub fn update_reading_state(
  connection: sqlight.Connection,
  book_id book_id: shared.BookId,
  mode mode: String,
  sentence_bitset sentence_bitset: Option(BitArray),
  word_bitset word_bitset: Option(BitArray),
  current_page current_page: Int,
  updated_at updated_at: String,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "INSERT INTO reading_state
       (book_id, mode, sentence_bitset, word_bitset, current_page, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(book_id) DO UPDATE SET
       mode = excluded.mode,
       sentence_bitset = excluded.sentence_bitset,
       word_bitset = excluded.word_bitset,
       current_page = excluded.current_page,
       updated_at = excluded.updated_at
     WHERE excluded.updated_at >= reading_state.updated_at;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [
        sqlight.text(book_id),
        sqlight.text(mode),
        sqlight.nullable(sqlight.blob, sentence_bitset),
        sqlight.nullable(sqlight.blob, word_bitset),
        sqlight.int(current_page),
        sqlight.text(updated_at),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// Look up the reading state for a given book. `Ok(None)` indicates no
/// row has been written yet — fresh books default to "no progress",
/// which the caller can synthesise rather than persist.
pub fn get_reading_state(
  connection: sqlight.Connection,
  book_id: shared.BookId,
) -> Result(Option(ReadingState), sqlight.Error) {
  let sql =
    "SELECT book_id, mode, sentence_bitset, word_bitset,
            current_page, updated_at
       FROM reading_state
      WHERE book_id = ?;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [sqlight.text(book_id)],
      expecting: reading_state_decoder(),
    )
  {
    Ok([state, ..]) -> Ok(Some(state))
    Ok([]) -> Ok(None)
    Error(error) -> Error(error)
  }
}

fn reading_state_decoder() -> decode.Decoder(ReadingState) {
  use book_id <- decode.field(0, decode.string)
  use mode <- decode.field(1, decode.string)
  use sentence_bitset <- decode.field(2, decode.optional(decode.bit_array))
  use word_bitset <- decode.field(3, decode.optional(decode.bit_array))
  use current_page <- decode.field(4, decode.int)
  // The column is `NOT NULL` so the value is always present; wrap in
  // `Some` to match the `Option(String)` shape of `ReadingState.updated_at`,
  // which the wire layer needs to distinguish a persisted row from a
  // synthesised empty default.
  use updated_at <- decode.field(5, decode.string)
  decode.success(ReadingState(
    book_id: book_id,
    mode: mode,
    sentence_bitset: sentence_bitset,
    word_bitset: word_bitset,
    current_page: current_page,
    updated_at: Some(updated_at),
  ))
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// Read the single `user_settings` row. `initialize` guarantees the
/// row exists, so a missing row here would be a corrupted database and
/// we surface that as a synthetic Sqlight error rather than silently
/// returning defaults.
pub fn get_settings(
  connection: sqlight.Connection,
) -> Result(UserSettings, sqlight.Error) {
  let sql =
    "SELECT font_size, line_spacing, dark_mode, ghost_mode,
            ghost_opacity, default_wpm, default_paragraph_delay_ms,
            default_page_delay_ms
       FROM user_settings
      WHERE id = ?;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [sqlight.text(default_settings_id)],
      expecting: user_settings_decoder(),
    )
  {
    Ok([settings, ..]) -> Ok(settings)
    Ok([]) ->
      // The default row is inserted by `initialize`; treating this as
      // a corrupt-database error is the right shape — we don't want to
      // mask a real loss of state by returning compiled-in defaults.
      Error(sqlight.SqlightError(
        code: sqlight.Notfound,
        message: "user_settings row 'default' is missing",
        offset: -1,
      ))
    Error(error) -> Error(error)
  }
}

/// Update the single `user_settings` row. All fields are overwritten —
/// there is no partial update, which mirrors how the client sends the
/// full settings object back on every save.
pub fn update_settings(
  connection: sqlight.Connection,
  settings: UserSettings,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "UPDATE user_settings SET
       font_size = ?,
       line_spacing = ?,
       dark_mode = ?,
       ghost_mode = ?,
       ghost_opacity = ?,
       default_wpm = ?,
       default_paragraph_delay_ms = ?,
       default_page_delay_ms = ?
     WHERE id = ?;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [
        sqlight.int(settings.font_size),
        sqlight.float(settings.line_spacing),
        sqlight.bool(settings.dark_mode),
        sqlight.bool(settings.ghost_mode),
        sqlight.float(settings.ghost_opacity),
        sqlight.int(settings.default_wpm),
        sqlight.int(settings.default_paragraph_delay_ms),
        sqlight.int(settings.default_page_delay_ms),
        sqlight.text(default_settings_id),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

// ---------------------------------------------------------------------------
// Book settings
// ---------------------------------------------------------------------------

/// Look up the per-book settings row. `Ok(None)` indicates no row
/// has been written yet — fresh books have no overrides, which the
/// caller surfaces as an all-null default rather than persisting an
/// empty row up front.
pub fn get_book_settings(
  connection: sqlight.Connection,
  book_id: shared.BookId,
) -> Result(Option(BookSettings), sqlight.Error) {
  let sql =
    "SELECT wpm, paragraph_delay_ms, page_delay_ms, ghost_opacity
       FROM book_settings
      WHERE book_id = ?;"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [sqlight.text(book_id)],
      expecting: book_settings_decoder(),
    )
  {
    Ok([settings, ..]) -> Ok(Some(settings))
    Ok([]) -> Ok(None)
    Error(error) -> Error(error)
  }
}

/// Insert or replace the per-book settings row. Every field is
/// nullable — a `None` clears the override and lets the global
/// default win on the next read. `INSERT OR REPLACE` matches the
/// "full record overwrite" semantics the HTTP layer uses for the
/// global settings PUT, so partial-update reasoning never leaks
/// into the SQL.
pub fn upsert_book_settings(
  connection: sqlight.Connection,
  book_id book_id: shared.BookId,
  settings settings: BookSettings,
) -> Result(Nil, sqlight.Error) {
  let sql =
    "INSERT OR REPLACE INTO book_settings
       (book_id, wpm, paragraph_delay_ms, page_delay_ms, ghost_opacity)
       VALUES (?, ?, ?, ?, ?);"
  case
    sqlight.query(
      sql,
      on: connection,
      with: [
        sqlight.text(book_id),
        sqlight.nullable(sqlight.int, settings.wpm),
        sqlight.nullable(sqlight.int, settings.paragraph_delay_ms),
        sqlight.nullable(sqlight.int, settings.page_delay_ms),
        sqlight.nullable(sqlight.float, settings.ghost_opacity),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

fn book_settings_decoder() -> decode.Decoder(BookSettings) {
  use wpm <- decode.field(0, decode.optional(decode.int))
  use paragraph_delay_ms <- decode.field(1, decode.optional(decode.int))
  use page_delay_ms <- decode.field(2, decode.optional(decode.int))
  use ghost_opacity <- decode.field(3, decode.optional(decode.float))
  decode.success(BookSettings(
    wpm: wpm,
    paragraph_delay_ms: paragraph_delay_ms,
    page_delay_ms: page_delay_ms,
    ghost_opacity: ghost_opacity,
  ))
}

fn user_settings_decoder() -> decode.Decoder(UserSettings) {
  use font_size <- decode.field(0, decode.int)
  use line_spacing <- decode.field(1, decode.float)
  use dark_mode <- decode.field(2, sqlight.decode_bool())
  use ghost_mode <- decode.field(3, sqlight.decode_bool())
  use ghost_opacity <- decode.field(4, decode.float)
  use default_wpm <- decode.field(5, decode.int)
  use default_paragraph_delay_ms <- decode.field(6, decode.int)
  use default_page_delay_ms <- decode.field(7, decode.int)
  decode.success(UserSettings(
    font_size: font_size,
    line_spacing: line_spacing,
    dark_mode: dark_mode,
    ghost_mode: ghost_mode,
    ghost_opacity: ghost_opacity,
    default_wpm: default_wpm,
    default_paragraph_delay_ms: default_paragraph_delay_ms,
    default_page_delay_ms: default_page_delay_ms,
  ))
}

// ---------------------------------------------------------------------------
// Reading sessions
// ---------------------------------------------------------------------------

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
