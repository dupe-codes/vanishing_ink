//// Vanishing Ink Lustre client. Mounts the reader as a Model-View-
//// Update application on `#app` and renders one viewport-sized page
//// of a `SegmentedText` at a time, paginated against actual DOM
//// dimensions instead of character-count estimates.
////
//// This module is the application's entry point only:
////   * `main` — wires `init`, `reducer.update`, and `view.view` into a
////     `lustre.application` and starts it against `#app`.
////   * `init` — constructs the initial `Model` (seeded with OS-level
////     preferences read synchronously through `ffi`), and produces the
////     boot `Effect` batch (viewport-meta patch, body classes,
////     `fetch_books`, `fetch_settings`, keyboard listeners).
////
//// Every other concern — types, messages, the reducer, the fade engine,
//// effect builders, view rendering — lives in the sibling modules under
//// `client/`. See `state.gleam`, `msg.gleam`, `effects.gleam`,
//// `engine.gleam`, `reducer.gleam`, and `view.gleam` (plus the per-view
//// modules under `view/`).
////
//// The app boots into the library view: `init` dispatches
//// `fetch_books()` to populate the grid from `GET /api/books`, and
//// the reader is reached by tapping a book card, which dispatches
//// `OpenBook(id)` and chains `fetch_book(id)` to land a
//// `BookLoaded` payload. The HTTP primitives live in
//// `client/ffi.gleam` (bespoke FFI rather than `lustre_http`; see
//// the `gleam.toml` note for the version-pin context).
////
//// Pagination flow on first paint and on every viewport resize:
////
//// 1. `TextLoaded` (or `ViewportResized`) lands in `update`.
//// 2. `update` returns an `after_paint` effect that, once the DOM is
////    laid out, measures each paragraph in the off-screen
////    `#vi-measurement` container plus the available content height
////    of the visible `#vi-page-content` element.
//// 3. The measurement effect dispatches `ParagraphsMeasured`, which
////    runs `pagination.calculate_pages` and stores the resulting
////    page boundaries on the model. `current_page` is clamped so an
////    in-progress reader does not slide off the new last page after
////    a resize.
////
//// Keyboard navigation (`ArrowRight`) and `resize` are both wired
//// through `client/ffi.gleam`. `resize` is debounced in the FFI so
//// a continuous drag does not flood the update loop.

import gleam/dict
import gleam/io
import gleam/option.{None}
import gleam/set
import gleam/string
import lustre
import lustre/effect.{type Effect}

import client/effects.{
  fetch_books, fetch_library_book_stats, fetch_library_stats, fetch_settings,
}
import client/ffi
import client/msg.{
  type Msg, FocusNext, FocusParagraphDown, FocusParagraphUp, FocusPrevious,
  NextPage, SpacePressed, Undo, ViewportResized, VisibilityChanged,
}
import client/reducer
import client/state.{
  type Model, Library, Manual, Model, Stopped, body_class_light_mode,
  body_class_reduced_motion, default_font_size, default_ghost_opacity,
  default_line_spacing, default_page_delay_ms, default_paragraph_delay_ms,
  default_wpm, fallback_user_settings,
}
import client/view

pub fn main() -> Nil {
  let app = lustre.application(init, reducer.update, view.view)

  case lustre.start(app, "#app", Nil) {
    Ok(_) -> Nil
    Error(reason) -> {
      // The realistic failures are `ElementNotFound("#app")` (the HTML
      // shell forgot the mount point) and `NotABrowser` (the bundle
      // was loaded outside a browser by mistake). Log the structured
      // reason before panicking so the operator sees what went wrong
      // rather than a bare runtime error.
      io.println("Lustre failed to mount on #app: " <> string.inspect(reason))
      panic as "lustre.start failed; see the logged reason above"
    }
  }
}

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  // Read the OS preferences synchronously so the model's `dark_mode`
  // and `reduced_motion` fields carry the right values *before* the
  // first render. The previous revision dispatched a
  // `SystemPreferencesDetected` from an effect, which ran after the
  // first paint — a reader on a light-mode (or reduced-motion) OS
  // saw a frame of the dark theme before the body classes flipped.
  // The FFI calls below are pure media-query reads (no DOM mutation)
  // so calling them from `init` is safe and idempotent.
  let dark_mode = ffi.get_prefers_color_scheme_dark()
  let reduced_motion = ffi.get_prefers_reduced_motion()

  let model =
    Model(
      text: None,
      flat_paragraphs: [],
      pages: [],
      current_page: 0,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
      focused_sentence: None,
      dark_mode: dark_mode,
      font_size: default_font_size,
      line_spacing: default_line_spacing,
      ghost_mode: False,
      ghost_opacity: default_ghost_opacity,
      dyslexia_font: False,
      reduced_motion: reduced_motion,
      settings_open: False,
      mode: Manual,
      wpm: default_wpm,
      engine_state: Stopped,
      next_word_index: None,
      erased_words: set.new(),
      paragraph_delay_ms: default_paragraph_delay_ms,
      page_delay_ms: default_page_delay_ms,
      line_boxes: [],
      active_line: None,
      total_sentence_count: 0,
      total_word_count: 0,
      current_chapter_title: "",
      total_pages: 0,
      view: Library,
      books: [],
      books_loading: True,
      library_error: None,
      active_book_id: None,
      paste_title: "",
      paste_text: "",
      paste_author: None,
      paste_submitting: False,
      paste_error: None,
      paste_warning: None,
      add_book_open: False,
      created_book_segments: None,
      global_defaults: fallback_user_settings(dark_mode),
      book_settings: None,
      confirm_delete_id: None,
      deleting_book_ids: set.new(),
      jump_menu_open: False,
      jump_preview: None,
      chapter_entries: [],
      jump_page_input: "",
      active_session_id: None,
      session_start_page: 0,
      session_start_erased_count: 0,
      session_words_skipped: 0,
      session_started_at: None,
      session_started_at_ms: 0,
      stats_open: False,
      book_stats: None,
      library_stats: None,
      library_book_stats: dict.new(),
      editing_metadata: None,
      jump_search_query: "",
      jump_search_results: [],
      sentence_word_indices: dict.new(),
      speed_trend: [],
    )

  // Boot effects:
  //
  // - `viewport_meta` patches the `<meta name="viewport">` tag injected
  //   by `lustre_dev_tools` to include `viewport-fit=cover` so the
  //   `env(safe-area-inset-*)` rules in the stylesheet actually report
  //   non-zero values on iOS notched devices.
  // - `body_classes` mirrors the OS-preference reads from above onto
  //   `<body>` so the CSS cascade reflects them on first paint.
  //   Synchronous effects run before Lustre's first `#render()` call
  //   (see `runtime.ffi.mjs`), so the body classes are present before
  //   the first DOM update and the browser never sees a frame with the
  //   wrong theme. `vi-light-mode` is applied when `dark_mode` is
  //   *False* — the dark palette is the default, so the class only
  //   fires the light override.
  // - `fetch_books` issues `GET /api/books` so the library populates
  //   from the server. The previous boot path injected a bundled
  //   sample text directly through `TextLoaded`; the server is now
  //   the source of truth and the sample fixture is no longer wired
  //   into production code (it stays around for tests as a
  //   well-shaped segmented-text fixture).
  // - The four listener effects (`resize`, `arrow`, `undo`, `vim`)
  //   wire keyboard navigation and the debounced resize handler.
  let viewport_meta =
    effect.from(fn(_dispatch) { ffi.ensure_viewport_fit_cover() })
  let body_classes =
    effect.from(fn(_dispatch) {
      ffi.set_body_class(body_class_light_mode, !dark_mode)
      ffi.set_body_class(body_class_reduced_motion, reduced_motion)
    })
  let resize_listener =
    effect.from(fn(dispatch) {
      ffi.on_resize(fn() { dispatch(ViewportResized) })
    })
  let arrow_listener =
    effect.from(fn(dispatch) { ffi.on_arrow_key(fn() { dispatch(NextPage) }) })
  let undo_listener =
    effect.from(fn(dispatch) { ffi.on_undo_key(fn() { dispatch(Undo) }) })
  let vim_listener =
    effect.from(fn(dispatch) {
      ffi.on_vim_keys(
        focus_previous_callback: fn() { dispatch(FocusPrevious) },
        focus_paragraph_down_callback: fn() { dispatch(FocusParagraphDown) },
        focus_paragraph_up_callback: fn() { dispatch(FocusParagraphUp) },
        focus_next_callback: fn() { dispatch(FocusNext) },
        space_callback: fn() { dispatch(SpacePressed) },
        undo_callback: fn() { dispatch(Undo) },
      )
    })
  // `visibilitychange` boots the reading-session lifecycle's
  // tab-hide / tab-show hook. The reducer maps `False` to
  // `apply_end_session` (the reader has tabbed away and the active
  // session should close so its counters are persisted) and `True`
  // to `apply_start_session` (the reader is back; open a fresh row
  // against the active book).
  let visibility_listener =
    effect.from(fn(dispatch) {
      ffi.add_visibility_listener(fn(visible) {
        dispatch(VisibilityChanged(visible))
      })
    })

  #(
    model,
    effect.batch([
      viewport_meta,
      body_classes,
      fetch_books(),
      fetch_settings(),
      fetch_library_stats(),
      fetch_library_book_stats(),
      resize_listener,
      arrow_listener,
      undo_listener,
      vim_listener,
      visibility_listener,
    ]),
  )
}
