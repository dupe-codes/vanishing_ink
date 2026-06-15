//// Server-side domain types and their JSON encoders. These types live on
//// the BEAM only — they describe rows persisted in SQLite and the shapes
//// the HTTP API hands back over the wire. The cross-target `BookId`
//// alias from `shared` is the one identifier shared with the client; the
//// rest is server-only because the client doesn't care about row layout.

import gleam/bit_array
import gleam/json
import gleam/option.{type Option, None}
import shared

/// Lightweight book record used by list views: no raw text and no
/// segmented payload. The full `Book` record is fetched on demand via
/// `GET /api/books/:id`.
pub type BookMeta {
  BookMeta(
    id: shared.BookId,
    title: String,
    author: Option(String),
    genre: Option(String),
    word_count: Int,
    sentence_count: Int,
    uploaded_at: String,
    last_read_at: Option(String),
  )
}

/// Full book record. `segments_json` stores the segmenter output as a
/// raw JSON string exactly as written at upload time — the encode-once,
/// decode-on-read contract keeps the structured payload byte-for-byte
/// stable across reads.
pub type Book {
  Book(
    id: shared.BookId,
    title: String,
    author: Option(String),
    genre: Option(String),
    raw_text: String,
    segments_json: String,
    word_count: Int,
    sentence_count: Int,
    uploaded_at: String,
    last_read_at: Option(String),
  )
}

/// User-wide reader preferences. A single row backs this in SQLite
/// (`user_settings` with a fixed `id = 'default'`), but the wire format
/// surfaces it as a flat object — the row id is an implementation
/// detail.
pub type UserSettings {
  UserSettings(
    font_size: Int,
    line_spacing: Float,
    dark_mode: Bool,
    ghost_mode: Bool,
    ghost_opacity: Float,
    default_wpm: Int,
    default_paragraph_delay_ms: Int,
    default_page_delay_ms: Int,
  )
}

/// Per-book reader overrides. Every field is `Option` because a
/// missing override means "use the global default" — the SQLite row
/// stores `NULL` for the column, the wire form emits `null`, and the
/// client merges the result against `UserSettings` at apply time.
///
/// Only the four pacing / ghost-opacity fields are overridable; the
/// visual fields (font size, line spacing, theme) ride on
/// `UserSettings` alone because they represent a reader-wide
/// preference rather than a per-text choice.
pub type BookSettings {
  BookSettings(
    wpm: Option(Int),
    paragraph_delay_ms: Option(Int),
    page_delay_ms: Option(Int),
    ghost_opacity: Option(Float),
  )
}

/// All-`None` `BookSettings` — the canonical "no overrides for this
/// book" record. Returned by the router as the synthesised body when
/// `book_settings` has no row for the requested id, used as the
/// neutral starting point for partial-update synthesis, and reused by
/// the test suite as the all-null reset baseline. Centralised here
/// so the empty shape has one source of truth across router + tests
/// (the client mirrors the same constant in `client.gleam` because
/// the type lives on the BEAM only).
pub fn empty_book_settings() -> BookSettings {
  BookSettings(
    wpm: None,
    paragraph_delay_ms: None,
    page_delay_ms: None,
    ghost_opacity: None,
  )
}

/// Per-book reading state. The bitsets are raw bytes addressing
/// sentences / words by their global index as assigned by the
/// segmenter; on the wire they go out as base64 so JSON stays
/// transport-safe.
///
/// `updated_at` is `Option` rather than `String` because a `GET` for a
/// book that has never been written to surfaces an empty default — the
/// wire shape should be honest about the absence (`null`) rather than
/// hand a 1970 sentinel back to the client.
pub type ReadingState {
  ReadingState(
    book_id: shared.BookId,
    mode: String,
    sentence_bitset: Option(BitArray),
    word_bitset: Option(BitArray),
    current_page: Int,
    /// `global_index` of the first sentence on the reader's current
    /// page — the device-independent reading-position anchor.
    ///
    /// `current_page` alone cannot survive a device change: pagination
    /// depends on viewport, font size, and line spacing, so page N on a
    /// phone is not page N on a desktop. A sentence's `global_index`, by
    /// contrast, is assigned by the segmenter over the full text and is
    /// stable across every pagination — the same identity space the
    /// `erased` / `erased_words` bitsets already key on. Pagination runs
    /// over the *full* text (erasure is only a render overlay), so this
    /// anchor always resolves to a page regardless of erase state, with
    /// no "next visible unit" fallback needed.
    ///
    /// `-1` is the "no anchor" sentinel for rows persisted before this
    /// field existed; the client falls back to `current_page` then.
    /// `current_page` is kept in the payload as a same-device fast-path
    /// and that back-compat fallback, but the anchor wins whenever it is
    /// present (`>= 0`).
    anchor_sentence_index: Int,
    /// Document-position progress percentage in `[0, 100]`. Computed
    /// client-side as `(last_read_sentence_index + 1) / total_sentence_count
    /// * 100` — the `+ 1` counts the last sentence on the saved page as
    /// read, so the final page lands on a clean `100.0`. The server stores
    /// the value the client last PUT and echoes it verbatim on the read;
    /// the GET handler is a pure mirror of the on-disk row, no derivation.
    /// Stored as a `REAL` in `reading_state.percent_progress`, defaulting
    /// to `0.0` for rows created before the page-based-progress quest.
    ///
    /// Note this is the *persisted* document-position figure, derived from
    /// the last read sentence — not the in-reader progress bar, which the
    /// client renders from page position via `helpers.progress_percentage`.
    /// The two coincide only at the 0% / 100% endpoints.
    ///
    /// Deriving from document position rather than the old
    /// `(current_page + 1) / total_pages` makes the figure
    /// pagination-independent: a reader who saves at 40% on a phone sees
    /// the same 40% when the library card is rendered on a desktop,
    /// because the numerator (a sentence's document index) and the
    /// denominator (the total sentence count) are both viewport-agnostic.
    /// Mirrors `client/types.gleam:ReadingState.percent_progress`; see
    /// `state/helpers.gleam:document_progress_percentage` for the formula.
    percent_progress: Float,
    /// Random destructive deletion settings, persisted per book. The
    /// page-per-page toggle and the once-per-book full-sweep guard are
    /// stored as `INTEGER` booleans; granularity and intensity as a
    /// closed `TEXT` vocabulary the router validates on write. Columns
    /// land on fresh databases via `schema_sql` and on existing ones via
    /// `db.ensure_reading_state_random_delete_columns`, defaulting to
    /// "feature off, gentlest settings".
    random_page_delete_on: Bool,
    deletion_granularity: String,
    deletion_intensity: String,
    full_sweep_applied: Bool,
    updated_at: Option(String),
  )
}

/// One row in the `reading_sessions` table. The client generates the
/// `id` (a `crypto.randomUUID()`-shaped string) before issuing the
/// POST so the follow-up PUT — and the visibilitychange-triggered
/// end-of-session PUT — can target the same row without waiting for
/// the POST response to land.
///
/// `ended_at` is `Option` because a session is live until the client
/// PUTs the end timestamp. The four counters default to zero so the
/// initial POST can omit them; the closing PUT supplies the final
/// values, which always overwrite whatever the row carries.
pub type ReadingSession {
  ReadingSession(
    id: String,
    book_id: shared.BookId,
    started_at: String,
    ended_at: Option(String),
    words_read: Int,
    words_skipped: Int,
    pages_turned: Int,
    duration_seconds: Int,
  )
}

// ---------------------------------------------------------------------------
// JSON encoders
// ---------------------------------------------------------------------------

/// Encode a `BookMeta` as a JSON object. Field names mirror the SQLite
/// columns so callers don't have to translate between the storage and
/// wire representations.
pub fn book_meta_to_json(meta: BookMeta) -> json.Json {
  json.object([
    #("id", json.string(meta.id)),
    #("title", json.string(meta.title)),
    #("author", json.nullable(meta.author, json.string)),
    #("genre", json.nullable(meta.genre, json.string)),
    #("word_count", json.int(meta.word_count)),
    #("sentence_count", json.int(meta.sentence_count)),
    #("uploaded_at", json.string(meta.uploaded_at)),
    #("last_read_at", json.nullable(meta.last_read_at, json.string)),
  ])
}

/// Encode a full `Book`. `segments` is parsed from the stored JSON
/// string and re-embedded as a structured object so the response is a
/// single well-formed JSON document, not a JSON-inside-a-JSON-string.
/// `parsed_segments` is the result of running `segmenter.decoder()` on
/// the stored `segments_json`; the caller does the decode so this
/// module stays storage-agnostic.
pub fn book_to_json(book: Book, parsed_segments: json.Json) -> json.Json {
  json.object([
    #("id", json.string(book.id)),
    #("title", json.string(book.title)),
    #("author", json.nullable(book.author, json.string)),
    #("genre", json.nullable(book.genre, json.string)),
    #("raw_text", json.string(book.raw_text)),
    #("word_count", json.int(book.word_count)),
    #("sentence_count", json.int(book.sentence_count)),
    #("uploaded_at", json.string(book.uploaded_at)),
    #("last_read_at", json.nullable(book.last_read_at, json.string)),
    #("segments", parsed_segments),
  ])
}

/// Encode user settings as a flat JSON object.
pub fn user_settings_to_json(settings: UserSettings) -> json.Json {
  json.object([
    #("font_size", json.int(settings.font_size)),
    #("line_spacing", json.float(settings.line_spacing)),
    #("dark_mode", json.bool(settings.dark_mode)),
    #("ghost_mode", json.bool(settings.ghost_mode)),
    #("ghost_opacity", json.float(settings.ghost_opacity)),
    #("default_wpm", json.int(settings.default_wpm)),
    #(
      "default_paragraph_delay_ms",
      json.int(settings.default_paragraph_delay_ms),
    ),
    #("default_page_delay_ms", json.int(settings.default_page_delay_ms)),
  ])
}

/// Encode per-book settings as a flat JSON object. Every field is
/// nullable on the wire — `None` round-trips as JSON `null`, which
/// the client reads as "no override, use the global default".
pub fn book_settings_to_json(settings: BookSettings) -> json.Json {
  json.object([
    #("wpm", json.nullable(settings.wpm, json.int)),
    #(
      "paragraph_delay_ms",
      json.nullable(settings.paragraph_delay_ms, json.int),
    ),
    #("page_delay_ms", json.nullable(settings.page_delay_ms, json.int)),
    #("ghost_opacity", json.nullable(settings.ghost_opacity, json.float)),
  ])
}

/// Encode reading state. Bitsets become base64 strings on the wire so
/// JSON consumers don't have to deal with binary framing.
pub fn reading_state_to_json(state: ReadingState) -> json.Json {
  json.object([
    #("book_id", json.string(state.book_id)),
    #("mode", json.string(state.mode)),
    #(
      "sentence_bitset",
      json.nullable(state.sentence_bitset, bit_array_to_json),
    ),
    #("word_bitset", json.nullable(state.word_bitset, bit_array_to_json)),
    #("current_page", json.int(state.current_page)),
    #("anchor_sentence_index", json.int(state.anchor_sentence_index)),
    #("percent_progress", json.float(state.percent_progress)),
    #("random_page_delete_on", json.bool(state.random_page_delete_on)),
    #("deletion_granularity", json.string(state.deletion_granularity)),
    #("deletion_intensity", json.string(state.deletion_intensity)),
    #("full_sweep_applied", json.bool(state.full_sweep_applied)),
    #("updated_at", json.nullable(state.updated_at, json.string)),
  ])
}

fn bit_array_to_json(bytes: BitArray) -> json.Json {
  json.string(bit_array.base64_encode(bytes, True))
}

/// Encode a `ReadingSession` as a JSON object. Field names mirror the
/// SQLite columns so the wire shape is a faithful surface of the
/// stored row — `ended_at` rides as `null` until the client closes
/// the session.
pub fn reading_session_to_json(session: ReadingSession) -> json.Json {
  json.object([
    #("id", json.string(session.id)),
    #("book_id", json.string(session.book_id)),
    #("started_at", json.string(session.started_at)),
    #("ended_at", json.nullable(session.ended_at, json.string)),
    #("words_read", json.int(session.words_read)),
    #("words_skipped", json.int(session.words_skipped)),
    #("pages_turned", json.int(session.pages_turned)),
    #("duration_seconds", json.int(session.duration_seconds)),
  ])
}
