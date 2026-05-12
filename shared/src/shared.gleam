//// Shared types and helpers used by both the Vanishing Ink server (BEAM)
//// and client (JavaScript). Everything in this module must stay
//// target-agnostic — no Erlang- or JS-only FFI, only pure Gleam and
//// portable stdlib calls — so the same code can be linked into both
//// builds via the local path dependency.

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
