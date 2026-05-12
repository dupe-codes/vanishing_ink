//// Shared types and helpers used by both the Vanishing Ink server (BEAM)
//// and client (JavaScript). Everything in this module must stay
//// target-agnostic — no Erlang- or JS-only FFI, only pure Gleam and
//// portable stdlib calls — so the same code can be linked into both
//// builds via the local path dependency.

import gleam/dynamic/decode
import gleam/json

/// Stable identifier for a book in the user's library. Treated as an
/// opaque string at this layer; the server is the source of truth for
/// generation and uniqueness.
pub type BookId =
  String

/// Wrap a raw string as a `BookId`. Provided as a named constructor so
/// call sites read intentionally even though the underlying type is a
/// transparent alias.
pub fn book_id(value: String) -> BookId {
  value
}

/// Encode a `BookId` as a JSON string value. The wire format is just the
/// raw string — keep it that way so future schema migrations can layer
/// on top without churning every payload.
pub fn book_id_to_json(id: BookId) -> json.Json {
  json.string(id)
}

/// Decoder for a JSON-encoded `BookId`. Pairs with `book_id_to_json` so
/// the encoder/decoder round-trip is reachable from both targets; the
/// decoder is what lets the JavaScript client parse a payload generated
/// by the BEAM server.
pub fn book_id_decoder() -> decode.Decoder(BookId) {
  decode.string
}
