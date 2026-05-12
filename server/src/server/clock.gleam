//// Wall-clock helpers. Wrap Erlang's `calendar:system_time_to_rfc3339`
//// and `calendar:rfc3339_to_system_time` so the rest of the server can
//// stamp and validate ISO 8601 UTC timestamps without spreading FFI
//// boilerplate. The FFI lives in `vanishing_ink_time_ffi.erl` alongside
//// the Gleam sources.

/// Current wall-clock time, formatted as an ISO 8601 UTC string
/// (`"2026-05-12T14:33:07Z"`). Used for `uploaded_at` stamps and any
/// other server-generated timestamp.
@external(erlang, "vanishing_ink_time_ffi", "now_iso8601")
pub fn now_iso8601() -> String

/// Parse a client-supplied ISO 8601 / RFC 3339 timestamp into the
/// canonical `YYYY-MM-DDTHH:MM:SS.sssZ` form (millisecond precision,
/// always emitted regardless of the input's sub-second width). Returns
/// `Error(Nil)` for anything that isn't a valid timestamp — including
/// the literal `"ZZZZ"`, gibberish, and out-of-range dates.
///
/// Canonicalisation here is load-bearing: `reading_state.updated_at`
/// is compared lexicographically inside the last-write-wins SQL guard,
/// so every accepted timestamp must share the same width and zero-
/// padding for the comparison to match chronological order. Preserving
/// milliseconds keeps two writes that differ only in their sub-second
/// component distinguishable, which a client tracking strict
/// monotonicity of `updated_at` would otherwise be silently fooled by.
@external(erlang, "vanishing_ink_time_ffi", "parse_iso8601")
pub fn parse_iso8601(value: String) -> Result(String, Nil)
