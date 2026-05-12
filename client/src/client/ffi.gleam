//// JavaScript FFI boundary for the Lustre reader. Wraps a small
//// surface of browser APIs — viewport size, DOM element measurement,
//// resize events, keyboard navigation — behind typed Gleam
//// signatures so the pagination engine and the reader's update loop
//// stay JS-free.
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

/// Install a debounced `resize` listener on `window`. The callback is
/// invoked at most once per debounce window (250 ms) after the most
/// recent resize event. The handle is anchored on `window` itself —
/// there is no removal API today.
@external(javascript, "./ffi.ffi.mjs", "on_resize")
pub fn on_resize(callback: fn() -> Nil) -> Nil

/// Install a `keydown` listener on `window` that routes `ArrowLeft`
/// to `previous_callback` and `ArrowRight` to `next_callback`. Other
/// keys are ignored. The listener persists for the lifetime of the
/// page.
@external(javascript, "./ffi.ffi.mjs", "on_arrow_key")
pub fn on_arrow_key(
  previous_callback previous_callback: fn() -> Nil,
  next_callback next_callback: fn() -> Nil,
) -> Nil

/// Install a `keydown` listener on `window` that fires `callback`
/// for the platform-conventional undo chord — `Cmd+Z` on macOS and
/// `Ctrl+Z` everywhere else. `Cmd+Shift+Z` / `Ctrl+Shift+Z` (redo)
/// is intentionally not caught here; there is no redo stack in the
/// reader today. The listener persists for the lifetime of the page.
@external(javascript, "./ffi.ffi.mjs", "on_undo_key")
pub fn on_undo_key(callback: fn() -> Nil) -> Nil
