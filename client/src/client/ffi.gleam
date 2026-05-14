//// JavaScript FFI boundary for the Lustre reader. Wraps a small
//// surface of browser APIs — viewport size, DOM element measurement,
//// resize events, keyboard navigation, system preferences, and CSS
//// custom property mutation — behind typed Gleam signatures so the
//// pagination engine and the reader's update loop stay JS-free.
////
//// The companion `ffi.ffi.mjs` colocated next to this module returns
//// runtime-shaped Gleam values (`Ok`/`Error`, `List`, plain
//// two-element arrays for `#(Int, Float)` tuples) so calls round-trip
//// cleanly back into `gleam` code on the JS target.

/// Window inner height in CSS pixels. Read directly from the live
/// browser viewport at call time.
@external(javascript, "./ffi.ffi.mjs", "get_viewport_height")
pub fn get_viewport_height() -> Float

/// Rendered height in CSS pixels of the first DOM element matching
/// `selector`, sourced from `getBoundingClientRect`. Returns
/// `Error(Nil)` when the selector matches no element.
@external(javascript, "./ffi.ffi.mjs", "get_element_height")
pub fn get_element_height(selector: String) -> Result(Float, Nil)

/// Walk every descendant of `container_selector` that carries a
/// `data-paragraph-global-index` attribute and return their
/// `(global_index, rendered_height)` pairs. Element order matches
/// document order; entries with a non-integer index are skipped.
///
/// Heights are sourced from `getBoundingClientRect().height`. For the
/// values to be accurate, the measured elements must establish a block
/// formatting context — the `.page-paragraph` wrappers in `client.gleam`
/// satisfy this via `display: flow-root` (see `styles.css`), which
/// contains inner margins and makes the reported height equal the actual
/// vertical page budget consumed by that paragraph.
@external(javascript, "./ffi.ffi.mjs", "measure_paragraphs")
pub fn measure_paragraphs(container_selector: String) -> List(#(Int, Float))

/// Walk every `[data-global-index]` descendant of `container_selector`,
/// group them by their visual line (rounded `getBoundingClientRect().top`),
/// and return one tuple per line in document order:
/// `#(relative_top, height, first_word_global_index, last_word_global_index)`.
///
/// `relative_top` is the line's distance from the container's top edge in
/// CSS pixels (the JS side subtracts the container's own
/// `getBoundingClientRect().top` from each word's). The caller drops
/// the tuple directly onto an absolutely-positioned overlay anchored
/// inside the container — no further offset arithmetic needed.
///
/// Returns an empty list when the selector matches no element or when
/// the container has no `[data-global-index]` descendants.
@external(javascript, "./ffi.ffi.mjs", "measure_word_lines")
pub fn measure_word_lines(
  container_selector: String,
) -> List(#(Float, Float, Int, Int))

/// Install a debounced `resize` listener on `window`. The callback is
/// invoked at most once per debounce window (250 ms) after the most
/// recent resize event. The handle is anchored on `window` itself —
/// there is no removal API today.
@external(javascript, "./ffi.ffi.mjs", "on_resize")
pub fn on_resize(callback: fn() -> Nil) -> Nil

/// Install a `keydown` listener on `window` that routes `ArrowRight`
/// to `next_callback`. `ArrowLeft` is intentionally not wired —
/// backward page navigation is disabled. The listener persists for
/// the lifetime of the page.
@external(javascript, "./ffi.ffi.mjs", "on_arrow_key")
pub fn on_arrow_key(next_callback next_callback: fn() -> Nil) -> Nil

/// Install a `keydown` listener on `window` that fires `callback`
/// for the platform-conventional undo chord — `Cmd+Z` on macOS and
/// `Ctrl+Z` everywhere else. `Cmd+Shift+Z` / `Ctrl+Shift+Z` (redo)
/// is intentionally not caught here; there is no redo stack in the
/// reader today. The listener persists for the lifetime of the page.
@external(javascript, "./ffi.ffi.mjs", "on_undo_key")
pub fn on_undo_key(callback: fn() -> Nil) -> Nil

/// Install a `keydown` listener on `window` for the vim-style
/// reader keys. Each callback corresponds to one unmodified key
/// press: `h`/`l` move the cursor between sentences, `j`/`k` move
/// between paragraphs, `Space` fires `space_callback` (the
/// reducer then routes it to either an erase-focused or a
/// pause/resume-engine action depending on `model.mode`), and
/// `u` invokes undo. Modifier chords (`Cmd`/`Ctrl`/`Alt`) are
/// ignored so the listener never collides with the existing
/// `Cmd+Z` undo handler or with browser shortcuts; keys pressed
/// while focus is in an `<input>` or `<textarea>` are also
/// ignored so the cursor doesn't hijack typing. The listener
/// persists for the lifetime of the page.
@external(javascript, "./ffi.ffi.mjs", "on_vim_keys")
pub fn on_vim_keys(
  focus_previous_callback focus_previous_callback: fn() -> Nil,
  focus_paragraph_down_callback focus_paragraph_down_callback: fn() -> Nil,
  focus_paragraph_up_callback focus_paragraph_up_callback: fn() -> Nil,
  focus_next_callback focus_next_callback: fn() -> Nil,
  space_callback space_callback: fn() -> Nil,
  undo_callback undo_callback: fn() -> Nil,
) -> Nil

/// Schedule the next word-fade tick. The implementation owns a
/// single-slot timer handle so callers do not need to track it:
/// starting a new timer cancels any previous one synchronously.
/// `callback` fires once after `delay_ms` milliseconds.
///
/// Synchronous cancellation closes the race that an
/// effect-dispatched timeout id would leave open (id arrives one
/// tick after the effect runs, during which window a
/// `PauseFade` would have nothing to cancel). With the slot in
/// JS land, every model update sees the timer in a known state.
@external(javascript, "./ffi.ffi.mjs", "start_word_timer")
pub fn start_word_timer(delay_ms: Int, callback: fn() -> Nil) -> Nil

/// Cancel any in-flight word timer. No-op when nothing is
/// scheduled. Called from `PauseFade`, from the internal
/// `apply_stop_fade` helper (engine exhaustion at end of book),
/// and on mode switches that leave RealTime mode.
@external(javascript, "./ffi.ffi.mjs", "clear_word_timer")
pub fn clear_word_timer() -> Nil

/// Returns `True` when the browser reports `prefers-color-scheme: dark`,
/// `False` otherwise. Used at boot to seed the reader's theme from the
/// reader's OS preference before any explicit override is applied. The
/// reader can flip the in-memory setting at runtime through the settings
/// panel; we do not re-query the media list on every settings change
/// because the user override takes precedence.
@external(javascript, "./ffi.ffi.mjs", "get_prefers_color_scheme_dark")
pub fn get_prefers_color_scheme_dark() -> Bool

/// Returns `True` when the browser reports `prefers-reduced-motion:
/// reduce`. The reader uses this to gate the sentence fade animation:
/// when the user has asked the OS to reduce motion, the `transition`
/// is stripped from `.sentence` so erases snap rather than fade.
@external(javascript, "./ffi.ffi.mjs", "get_prefers_reduced_motion")
pub fn get_prefers_reduced_motion() -> Bool

/// Set a CSS custom property on `document.documentElement` (i.e. the
/// `:root` selector). Used to push live font-size / line-height /
/// ghost-opacity values into the cascade without re-rendering the
/// whole view tree. The change cascades into every rule that references
/// the property.
@external(javascript, "./ffi.ffi.mjs", "set_css_property")
pub fn set_css_property(name: String, value: String) -> Nil

/// Set or remove a class on `document.body`. When `enabled` is `True`
/// the class is added; when `False` it is removed. Used for theme
/// (`vi-light-mode`), dyslexia font (`vi-dyslexia-font`), ghost mode
/// (`vi-ghost-mode`), and reduced motion (`vi-reduced-motion`) toggles —
/// the CSS reads each class to flip the relevant rules. Keeping the
/// switches on `body` rather than the shell `<div>` so the existing
/// view-render tests stay stable: the rendered Lustre tree is unchanged
/// by setting toggles.
@external(javascript, "./ffi.ffi.mjs", "set_body_class")
pub fn set_body_class(class_name: String, enabled: Bool) -> Nil

/// Patch the document's `<meta name="viewport">` element to include
/// `viewport-fit=cover` so the iOS notch / Dynamic Island and home
/// indicator regions report non-zero `env(safe-area-inset-*)` values.
/// `lustre_dev_tools` ships a stock viewport meta without the cover
/// flag; the FFI rewrites the `content` attribute in place rather than
/// inserting a duplicate tag (which would let the older one win
/// depending on parser order). Safe to call repeatedly — only the
/// attribute value is touched.
@external(javascript, "./ffi.ffi.mjs", "ensure_viewport_fit_cover")
pub fn ensure_viewport_fit_cover() -> Nil

/// Failure modes for the JSON fetch wrappers below. The shape matches
/// the three places a request can fail:
///
/// * `NetworkError` — the underlying `fetch()` promise rejected (DNS,
///   CORS, offline, server unreachable). The browser exposes the
///   reason only as a `TypeError` message string; we surface it
///   verbatim for the developer console.
/// * `HttpError` — the server responded with a non-2xx status. Both
///   the numeric status and the response body are preserved so a 4xx
///   validation message from the API is visible to the caller.
/// * `DecodeError` — the response body was not the expected shape.
///   The caller maps `gleam_json`'s structured decode error into a
///   single human-readable `detail` string before constructing this
///   variant.
pub type FetchError {
  NetworkError(message: String)
  HttpError(status: Int, body: String)
  DecodeError(detail: String)
}

/// Issue a `GET` for `url` and invoke `on_complete` with either the
/// raw response body (`Ok(body_string)`) or a typed `FetchError`. The
/// caller is responsible for running a JSON decoder on the body —
/// keeping decoding out of the FFI means a future content type (e.g.
/// plain text health probes) reuses the same primitive without
/// special-casing.
///
/// Relative URLs are resolved against the document's base URL by the
/// browser, so `"/api/books"` works without callers needing to
/// reconstruct the origin. This is the principal reason for the
/// bespoke wrapper — the previous `gleam_fetch` spike could not
/// express relative URLs because `request.to/from_uri` requires both
/// scheme and host.
@external(javascript, "./ffi.ffi.mjs", "fetch_json_get")
pub fn fetch_json_get(
  url: String,
  on_complete: fn(Result(String, FetchError)) -> Nil,
) -> Nil

/// Issue a `POST` for `url` with `body` as the request payload (sent
/// with `Content-Type: application/json`) and invoke `on_complete`
/// the same way as `fetch_json_get`. The caller is responsible for
/// serialising the request body to a JSON string before calling.
@external(javascript, "./ffi.ffi.mjs", "fetch_json_post")
pub fn fetch_json_post(
  url: String,
  body: String,
  on_complete: fn(Result(String, FetchError)) -> Nil,
) -> Nil

/// PUT counterpart to `fetch_json_post`. The settings endpoints use PUT
/// rather than POST so the server stays on the convention of "POST for
/// creates, PUT for full-record updates" — `/api/settings` and
/// `/api/books/:id/settings` both replace the whole record on write,
/// which is the canonical PUT semantic.
@external(javascript, "./ffi.ffi.mjs", "fetch_json_put")
pub fn fetch_json_put(
  url: String,
  body: String,
  on_complete: fn(Result(String, FetchError)) -> Nil,
) -> Nil

/// Issue a `DELETE` for `url` with no request body and invoke
/// `on_complete` with `Ok("")` on a 204 No Content, or a typed
/// `FetchError` on network / HTTP failure. The body is empty for
/// a successful delete so the caller does not need to decode anything.
@external(javascript, "./ffi.ffi.mjs", "fetch_json_delete")
pub fn fetch_json_delete(
  url: String,
  on_complete: fn(Result(String, FetchError)) -> Nil,
) -> Nil

/// PATCH counterpart to `fetch_json_put`. The metadata-edit endpoint
/// uses PATCH rather than PUT because the request carries a partial
/// record (one or more of `title` / `author` / `genre`) rather than
/// the full row. Same callback contract as the other helpers.
@external(javascript, "./ffi.ffi.mjs", "fetch_json_patch")
pub fn fetch_json_patch(
  url: String,
  body: String,
  on_complete: fn(Result(String, FetchError)) -> Nil,
) -> Nil

/// Wall-clock now formatted as an ISO 8601 UTC string with millisecond
/// precision (`YYYY-MM-DDTHH:MM:SS.sssZ`). Used to stamp
/// `reading_state.updated_at` on each PUT — the server canonicalises
/// every accepted timestamp to the same width so the last-write-wins
/// lexicographic comparison inside SQLite matches chronological order.
/// Pinning the FFI to `Date.prototype.toISOString` keeps the client
/// output already in canonical form, so the round trip is a no-op.
@external(javascript, "./ffi.ffi.mjs", "now_iso8601")
pub fn now_iso8601() -> String

/// Pack a list of non-negative indices into a base64-encoded bitset.
/// Bit N is set (MSB-first within each byte) when N appears in the
/// input; the byte array is sized to the smallest length that fits the
/// largest index, with up to seven trailing zero bits. An empty input
/// returns an empty string, which callers map to JSON `null` on the
/// wire rather than transmitting an empty BitArray.
///
/// The encoding is symmetric with `unpack_base64_to_indices` —
/// round-tripping a list of indices through both helpers returns the
/// same indices in ascending order (duplicates collapse to a single
/// bit). Used by the reading-state save path to project the in-memory
/// `Set(Int)` of erased sentence/word global indices onto the
/// `bit_array.base64_encode`-compatible wire form the server expects.
@external(javascript, "./ffi.ffi.mjs", "pack_indices_to_base64")
pub fn pack_indices_to_base64(indices: List(Int)) -> String

/// Inverse of `pack_indices_to_base64`. Decodes the base64 string into
/// bytes and returns one entry per set bit, in ascending index order.
/// An empty input, malformed base64, or a bitset whose bytes are all
/// zero all surface as an empty list — callers feed the result into
/// `set.from_list` either way, so a quiet empty-set fallback is the
/// right shape for "no progress recorded" / "decode failed."
@external(javascript, "./ffi.ffi.mjs", "unpack_base64_to_indices")
pub fn unpack_base64_to_indices(encoded: String) -> List(Int)
