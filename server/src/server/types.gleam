//// Server-side domain types and their JSON encoders. These types live on
//// the BEAM only — they describe rows persisted in SQLite and the shapes
//// the HTTP API hands back over the wire. The cross-target `BookId`
//// alias from `shared` is the one identifier shared with the client; the
//// rest is server-only because the client doesn't care about row layout.

import gleam/bit_array
import gleam/json
import gleam/option.{type Option}
import shared

/// Lightweight book record used by list views: no raw text and no
/// segmented payload. The full `Book` record is fetched on demand via
/// `GET /api/books/:id`.
pub type BookMeta {
  BookMeta(
    id: shared.BookId,
    title: String,
    author: Option(String),
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
    updated_at: Option(String),
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
    #("updated_at", json.nullable(state.updated_at, json.string)),
  ])
}

fn bit_array_to_json(bytes: BitArray) -> json.Json {
  json.string(bit_array.base64_encode(bytes, True))
}
