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

/// Install a `keydown` listener on `window` for the vim-style
/// reader keys. Each callback corresponds to one unmodified key
/// press: `h`/`l` move the cursor between sentences, `j`/`k` move
/// between paragraphs, `Space` erases the focused sentence, and
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
  erase_focused_callback erase_focused_callback: fn() -> Nil,
  undo_callback undo_callback: fn() -> Nil,
) -> Nil

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
