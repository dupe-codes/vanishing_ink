//// Client-side wire types for the books API. The server's
//// `server/types.gleam` is the authority on the on-the-wire JSON
//// shape; this module mirrors the fields the client actually uses
//// (no `raw_text` — the client never re-renders the source string)
//// and pairs each type with a `gleam/dynamic/decode` decoder.
////
//// The decoders are organised so the three endpoints in
//// `server/router.gleam` each have a one-liner entry point:
////
//// * `GET /api/books`        → `decode.list(book_meta_decoder())`
//// * `GET /api/books/:id`    → `book_with_segments_decoder()`
//// * `POST /api/books`       → `create_book_response_decoder()`

import gleam/dynamic/decode
import gleam/option.{type Option}

import shared/segmenter.{type SegmentedText}

/// Lightweight book record used by the library grid and the hero
/// card. Mirrors `server/types.gleam:BookMeta` on the wire — the
/// `id` and timestamp fields stay opaque strings because the client
/// only displays and forwards them, never parses or mutates them.
///
/// `last_read_at` is `None` for a freshly-uploaded book that nobody
/// has opened yet; the library sort uses that to demote unread books
/// below ones the reader is in the middle of.
pub type BookMeta {
  BookMeta(
    id: String,
    title: String,
    author: Option(String),
    genre: Option(String),
    word_count: Int,
    sentence_count: Int,
    uploaded_at: String,
    last_read_at: Option(String),
  )
}

/// Decoder for one `BookMeta` JSON object. Pairs field-for-field
/// with `server/types.gleam:book_meta_to_json`; a drift in either
/// direction (server adds/removes a field, client renames a field)
/// surfaces as a decode failure in tests rather than as a silent
/// data-shape mismatch at runtime.
pub fn book_meta_decoder() -> decode.Decoder(BookMeta) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use author <- decode.field("author", decode.optional(decode.string))
  use genre <- decode.field("genre", decode.optional(decode.string))
  use word_count <- decode.field("word_count", decode.int)
  use sentence_count <- decode.field("sentence_count", decode.int)
  use uploaded_at <- decode.field("uploaded_at", decode.string)
  use last_read_at <- decode.field(
    "last_read_at",
    decode.optional(decode.string),
  )
  decode.success(BookMeta(
    id: id,
    title: title,
    author: author,
    genre: genre,
    word_count: word_count,
    sentence_count: sentence_count,
    uploaded_at: uploaded_at,
    last_read_at: last_read_at,
  ))
}

/// Decoder for `GET /api/books/:id`. The server returns the full
/// `Book` row plus an inlined `segments` object; the client peels
/// the metadata fields back into a `BookMeta` (the `raw_text` field
/// is intentionally dropped — the reader works against the
/// pre-segmented payload, never against the source string) and
/// hands the segmenter sub-tree off to its own decoder.
pub fn book_with_segments_decoder() -> decode.Decoder(
  #(BookMeta, SegmentedText),
) {
  use meta <- decode.then(book_meta_decoder())
  use segments <- decode.field("segments", segmenter.decoder())
  decode.success(#(meta, segments))
}

/// Decoder for the `POST /api/books` response body. The server
/// returns `{ "book": <BookMeta>, "segments": <SegmentedText> }`
/// so the client can drop the metadata into its library list and
/// (optionally) jump straight into reading without a second GET.
pub fn create_book_response_decoder() -> decode.Decoder(
  #(BookMeta, SegmentedText),
) {
  use meta <- decode.field("book", book_meta_decoder())
  use segments <- decode.field("segments", segmenter.decoder())
  decode.success(#(meta, segments))
}

/// Global user-wide reader settings. Mirrors
/// `server/types.gleam:UserSettings`; the same fields ride on `Model`
/// at the top level, but a self-contained record is what the
/// `/api/settings` decoder produces and what the matching encoder
/// reads back when the client persists a change.
///
/// Field names mirror the server's JSON keys exactly so the encoder
/// and decoder stay symmetrical — a drift on either side surfaces
/// in tests rather than as a silent shape mismatch at runtime.
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
/// missing override means "use the global default" — the server
/// stores SQL `NULL` for those columns and the wire form emits
/// `null`, so the typed mirror is `None`.
///
/// Only the four fields below are overridable on a per-book basis:
/// the visual settings (font size, line spacing, theme) ride on the
/// global preferences alone.
pub type BookSettings {
  BookSettings(
    wpm: Option(Int),
    paragraph_delay_ms: Option(Int),
    page_delay_ms: Option(Int),
    ghost_opacity: Option(Float),
  )
}

/// Decoder for `GET /api/settings`. Pairs field-for-field with the
/// server's `user_settings_to_json` encoder.
pub fn user_settings_decoder() -> decode.Decoder(UserSettings) {
  use font_size <- decode.field("font_size", decode.int)
  use line_spacing <- decode.field("line_spacing", decode.float)
  use dark_mode <- decode.field("dark_mode", decode.bool)
  use ghost_mode <- decode.field("ghost_mode", decode.bool)
  use ghost_opacity <- decode.field("ghost_opacity", decode.float)
  use default_wpm <- decode.field("default_wpm", decode.int)
  use default_paragraph_delay_ms <- decode.field(
    "default_paragraph_delay_ms",
    decode.int,
  )
  use default_page_delay_ms <- decode.field("default_page_delay_ms", decode.int)
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

/// Decoder for `GET /api/books/:id/settings`. The server emits
/// `null` for a column that has no override; the typed mirror is
/// `None`, so each field decodes through `decode.optional`.
pub fn book_settings_decoder() -> decode.Decoder(BookSettings) {
  use wpm <- decode.field("wpm", decode.optional(decode.int))
  use paragraph_delay_ms <- decode.field(
    "paragraph_delay_ms",
    decode.optional(decode.int),
  )
  use page_delay_ms <- decode.field(
    "page_delay_ms",
    decode.optional(decode.int),
  )
  use ghost_opacity <- decode.field(
    "ghost_opacity",
    decode.optional(decode.float),
  )
  decode.success(BookSettings(
    wpm: wpm,
    paragraph_delay_ms: paragraph_delay_ms,
    page_delay_ms: page_delay_ms,
    ghost_opacity: ghost_opacity,
  ))
}

/// Per-book reading progress. Mirrors `server/types.gleam:ReadingState`
/// field-for-field, with one wire concession: the bitsets ride as
/// `Option(String)` here rather than `Option(BitArray)`. The server
/// emits base64 on the wire (so JSON consumers stay transport-safe) and
/// the client decodes them lazily — the `Set(Int)` projection lives in
/// the reducer rather than the decoder so the wire shape stays close
/// to the JSON literally received.
///
/// `mode` is a closed vocabulary on the server side (`"manual"` /
/// `"ghost"`); the decoder accepts any string and the reducer maps it
/// to the typed `Mode` variant so an unknown value can fall back to a
/// safe default rather than failing the decode.
///
/// `updated_at` is `Option` because a `GET` for a book that has never
/// been written to surfaces an empty default — the wire shape emits
/// `null` rather than a 1970 sentinel.
pub type ReadingState {
  ReadingState(
    book_id: String,
    mode: String,
    sentence_bitset: Option(String),
    word_bitset: Option(String),
    current_page: Int,
    updated_at: Option(String),
  )
}

/// Decoder for `GET /api/books/:id/state`. Pairs field-for-field with
/// `server/types.gleam:reading_state_to_json`; a drift in either
/// direction surfaces as a decode failure in tests rather than as a
/// silent shape mismatch at runtime.
pub fn reading_state_decoder() -> decode.Decoder(ReadingState) {
  use book_id <- decode.field("book_id", decode.string)
  use mode <- decode.field("mode", decode.string)
  use sentence_bitset <- decode.field(
    "sentence_bitset",
    decode.optional(decode.string),
  )
  use word_bitset <- decode.field("word_bitset", decode.optional(decode.string))
  use current_page <- decode.field("current_page", decode.int)
  use updated_at <- decode.field("updated_at", decode.optional(decode.string))
  decode.success(ReadingState(
    book_id: book_id,
    mode: mode,
    sentence_bitset: sentence_bitset,
    word_bitset: word_bitset,
    current_page: current_page,
    updated_at: updated_at,
  ))
}
