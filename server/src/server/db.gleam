//// SQLite persistence layer for Vanishing Ink. Owns the schema, the
//// migration on-open, and every typed query the router needs. All SQL
//// runs through `sqlight.query` with parameter binding — never string
//// interpolation — and every CRUD wrapper returns a precise result
//// type so the router layer can stay free of decode boilerplate.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import server/types.{
  type Book, type BookMeta, type ReadingState, type UserSettings, Book, BookMeta,
  ReadingState, UserSettings,
}
import shared
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
-- `books(id)` without an `ON DELETE CASCADE` clause. There is no book
-- deletion endpoint today, but when one lands the foreign keys must
-- gain `ON DELETE CASCADE` (or the delete handler must purge the
-- dependent rows first) or the delete will fail with a FK violation
-- under `PRAGMA foreign_keys = ON`.
--
-- SCAFFOLDING: `book_settings` is declared up front but has no Gleam
-- reader or writer yet. It exists to back a not-yet-implemented
-- per-book override feature (custom WPM, paragraph/page delays, and
-- ghost opacity for a single book, overriding `user_settings`). Adding
-- the schema now keeps the eventual migration to a populated table
-- additive — handler additions only — rather than mixing a schema
-- change into the feature work.
CREATE TABLE IF NOT EXISTS book_settings (
  book_id TEXT PRIMARY KEY REFERENCES books(id),
  wpm INTEGER,
  paragraph_delay_ms INTEGER,
  page_delay_ms INTEGER,
  ghost_opacity REAL
);

CREATE TABLE IF NOT EXISTS reading_state (
  book_id TEXT PRIMARY KEY REFERENCES books(id),
  mode TEXT NOT NULL DEFAULT 'manual',
  sentence_bitset BLOB,
  word_bitset BLOB,
  current_page INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
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
// ordinal (`decode.field(0, ...)` etc.), so the `SELECT` column lists
// in `list_books`, `get_book`, `get_reading_state`, `get_settings`, and
// `update_settings` MUST match their corresponding decoders position
// for position. Adding a column means appending it to both the SELECT
// list and the decoder in the same order. The test suite covers a
// round-trip of every field, which catches a mis-ordering as a value
// mismatch on the changed field.

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
