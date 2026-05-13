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
