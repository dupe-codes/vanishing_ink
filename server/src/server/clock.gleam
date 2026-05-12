//// Wall-clock helper. Wraps Erlang's `calendar:system_time_to_rfc3339`
//// so the rest of the server can stamp timestamps as ISO 8601 UTC
//// strings without spreading FFI boilerplate. The FFI lives in
//// `vanishing_ink_time_ffi.erl` alongside the Gleam sources.

/// Current wall-clock time, formatted as an ISO 8601 UTC string
/// (`"2026-05-12T14:33:07Z"`). Used for `uploaded_at` stamps and any
/// other server-generated timestamp.
@external(erlang, "vanishing_ink_time_ffi", "now_iso8601")
pub fn now_iso8601() -> String
