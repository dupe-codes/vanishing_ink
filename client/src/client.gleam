//// Vanishing Ink Lustre client. Mounts the reader as a Model-View-
//// Update application on `#app` and renders one viewport-sized page
//// of a `SegmentedText` at a time, paginated against actual DOM
//// dimensions instead of character-count estimates.
////
//// The scaffold loads a hardcoded sample text at init — the HTTP
//// client is intentionally absent (see the `gleam.toml` note on
//// `lustre_http`) so a later quest will replace the sample wiring
//// with a real server request without changing the message shape.
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
//// Keyboard navigation (`ArrowLeft`/`ArrowRight`) and `resize` are
//// both wired through `client/ffi.gleam`. `resize` is debounced in
//// the FFI so a continuous drag does not flood the update loop.
////
//// **Reader settings** are kept in-memory on the `Model` (no
//// persistence today). The view tree stays free of theme/setting
//// markup — settings are pushed into the CSS cascade via FFI
//// (`set_css_property` for sliders, `set_body_class` for binary
//// toggles), and the CSS reads custom properties and body classes to
//// flip the relevant rules. The settings panel itself is the only
//// part of the view conditional on the settings model, so the
//// existing rendered-HTML tests stay stable through every settings
//// change.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/ffi
import client/gestures
import client/navigation
import client/pagination.{type Page, type PageParagraph}
import client/sample
import shared/segmenter.{
  type Paragraph, type SegmentedText, type Sentence, type Word,
}

/// Cap on the depth of the per-page undo stack. The stack only holds
/// erases on the current page (cleared on every page navigation), so
/// five generations is plenty without giving the reader a free pass
/// to undo a whole rapid-erase run by mistake.
pub const undo_stack_depth: Int = 5

// ---------------------------------------------------------------------------
// Reader settings — defaults and bounds
// ---------------------------------------------------------------------------
//
// All values below are clamped at the reducer boundary so a future
// slider that fires an out-of-range value does not poison the model.
// The bounds are also surfaced to the view so the `<input type=range>`
// elements declare the same min/max — the reducer clamp is the
// authority and the slider attributes just keep the UI honest.

/// Default `font_size`. Picked to match the bundled stylesheet's
/// `--vi-base-font-size` (`18px`) so the initial render does not
/// invalidate the first paragraph measurement pass.
pub const default_font_size: Int = 18

/// Lower bound on `font_size`. Anything below 14px starts to lose
/// legibility on a phone screen at typical reading distance.
pub const min_font_size: Int = 14

/// Upper bound on `font_size`. 28px is large enough for
/// vision-impaired reading without breaking the bundled prose's
/// paragraph rhythm.
pub const max_font_size: Int = 28

/// Default `line_spacing`. Matches the bundled stylesheet's
/// `--vi-line-height`.
pub const default_line_spacing: Float = 1.6

pub const min_line_spacing: Float = 1.2

pub const max_line_spacing: Float = 2.0

/// Default `ghost_opacity` — applied only when `ghost_mode` is on.
/// The value is a deliberately gentle starting point: most readers
/// graduating from fully-invisible erases want a faint reminder that
/// something is there, not a half-visible second copy of the prose.
pub const default_ghost_opacity: Float = 0.06

pub const min_ghost_opacity: Float = 0.0

pub const max_ghost_opacity: Float = 0.3

// ---------------------------------------------------------------------------
// DOM ids
// ---------------------------------------------------------------------------
//
// Centralised so the FFI calls in `update` and the `attribute.id(...)`
// calls in `view` stay in lock-step. A drift here is the most
// plausible way the pagination engine can silently stop receiving
// measurements. Selector strings ("#vi-...") are built at the call
// site by prepending `"#"` so the selector form cannot diverge from
// the attribute form.

const reading_area_id: String = "vi-reading-area"

const page_content_id: String = "vi-page-content"

const measurement_id: String = "vi-measurement"

// ---------------------------------------------------------------------------
// CSS custom property and body-class names
// ---------------------------------------------------------------------------
//
// Mirrors the names declared in `assets/styles.css`. Defining them as
// constants on the Gleam side keeps the FFI calls in `update` and the
// CSS rules from drifting apart: a rename in the stylesheet means a
// rename here, and the failure mode is a Gleam compile error rather
// than a silently broken setting.

const css_var_font_size: String = "--vi-base-font-size"

const css_var_line_height: String = "--vi-line-height"

const css_var_ghost_opacity: String = "--vi-ghost-opacity"

const body_class_light_mode: String = "vi-light-mode"

const body_class_ghost_mode: String = "vi-ghost-mode"

const body_class_dyslexia_font: String = "vi-dyslexia-font"

const body_class_reduced_motion: String = "vi-reduced-motion"

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

/// Top-level reader state.
///
/// * `text` — `None` before the sample (or a future server payload)
///   has been dispatched through the update loop, `Some(text)`
///   afterwards.
/// * `flat_paragraphs` — the flattened `PageParagraph` list cached
///   alongside `text`. Computed once on `TextLoaded` and reused by
///   both `ParagraphsMeasured` (to feed `calculate_pages`) and
///   `view_paginated` (to populate the off-screen measurement
///   container). Recomputing it per render would walk the whole
///   `SegmentedText` on every `NextPage` / `PreviousPage` keystroke
///   for no semantic reason.
/// * `pages` — pre-calculated page boundaries. Empty between
///   `TextLoaded` and the first `ParagraphsMeasured`, and during a
///   resize while measurement is in flight.
/// * `current_page` — zero-based index into `pages`. Always clamped
///   into `[0, list.length(pages))` after a measurement.
/// * `erased` — set of `sentence.global_index` for every sentence
///   the reader has erased. Membership is the sole erasure signal;
///   non-members render as visible. A `Set` rather than a
///   `Dict(Int, Bool)` so the "no `False` value ever stored"
///   invariant is type-encoded rather than enforced by convention.
/// * `undo_stack` — last erases on the *current* page, most recent
///   first. Bounded to `undo_stack_depth` entries; cleared whenever
///   the reader navigates between pages, so erases commit when the
///   page turns.
/// * `touch_start` — `(clientX, clientY)` of the in-flight touch
///   between `touchstart` and `touchend`. `None` when there is no
///   active gesture. Cleared on every `TouchEnd`.
/// * `focused_sentence` — `Some(global_index)` of the sentence the
///   keyboard cursor sits on, `None` before the reader has ever
///   pressed a vim navigation key. The cursor is a desktop-only
///   affordance: touch input (clicks, swipes, taps) never sets
///   focus, so the field stays `None` on a tablet/phone session
///   even as the reader erases sentences. A focused sentence
///   renders with the `sentence-focused` class so the reader can
///   see where the cursor is.
/// * `dark_mode` — `True` for the OLED dark surface (default),
///   `False` for the light reading palette. Seeded from
///   `prefers-color-scheme` at boot and overridable through the
///   settings panel.
/// * `font_size` — base font size in CSS pixels. Pushed into the
///   `--vi-base-font-size` custom property on change so the cascade
///   updates without re-rendering the view tree. Re-pagination is
///   triggered after the change because paragraph heights depend on
///   font size.
/// * `line_spacing` — `line-height` multiplier. Pushed into
///   `--vi-line-height` and triggers re-pagination on change.
/// * `ghost_mode` — when `True`, erased sentences render at
///   `ghost_opacity` instead of `0`. Useful for graded ERP exposure
///   work where the reader wants a faint reminder that prose has
///   been erased.
/// * `ghost_opacity` — opacity applied to erased sentences when
///   `ghost_mode` is on. Ignored when `ghost_mode` is off (the
///   inline `opacity:0` rules instead).
/// * `dyslexia_font` — when `True`, swap the body font to
///   OpenDyslexic. Triggers re-pagination because the new font
///   metrics change paragraph wrap heights.
/// * `reduced_motion` — when `True`, the body carries
///   `vi-reduced-motion` and the sentence-fade transition collapses
///   to a snap. Seeded from `prefers-reduced-motion` at boot.
/// * `settings_open` — when `True`, the settings panel renders as a
///   bottom-sheet overlay above the reading surface. The gear icon
///   on the control bar toggles it.
pub type Model {
  Model(
    text: Option(SegmentedText),
    flat_paragraphs: List(PageParagraph),
    pages: List(Page),
    current_page: Int,
    erased: Set(Int),
    undo_stack: List(Int),
    touch_start: Option(#(Float, Float)),
    focused_sentence: Option(Int),
    dark_mode: Bool,
    font_size: Int,
    line_spacing: Float,
    ghost_mode: Bool,
    ghost_opacity: Float,
    dyslexia_font: Bool,
    reduced_motion: Bool,
    settings_open: Bool,
  )
}

/// Application messages.
pub type Msg {
  /// A book has been segmented and is ready to render. Fired from
  /// `init` with the hardcoded sample today; a future quest will
  /// dispatch the same message with a server payload.
  TextLoaded(SegmentedText)

  /// Browser paragraph heights have been read via FFI. Carries the
  /// `(global_index, height)` pairs alongside the available
  /// content-area height the pagination algorithm should fit pages
  /// into.
  ParagraphsMeasured(heights: List(#(Int, Float)), available_height: Float)

  /// Reader requested the next page (button, `ArrowRight`, or
  /// swipe-left gesture). Clears the undo stack — erases on the
  /// page being left commit.
  NextPage

  /// Reader requested the previous page (button, `ArrowLeft`, or a
  /// swipe-right gesture with an empty undo stack). Clears the undo
  /// stack so undo never crosses a page boundary backwards either.
  PreviousPage

  /// Debounced `window.resize` fired. The handler re-runs the
  /// measurement effect — paragraph heights change with viewport
  /// width because of line wrapping.
  ViewportResized

  /// Reader tapped or clicked the sentence with this global index.
  /// `update` writes it into `erased` and pushes it onto
  /// `undo_stack`. A repeat erase of an already-erased sentence is
  /// a no-op so the undo stack stays meaningful.
  EraseSentence(global_index: Int)

  /// Reader requested undo (swipe right with non-empty undo stack,
  /// `Cmd+Z`/`Ctrl+Z`, or any other future undo binding). Pops the
  /// most recent erase off `undo_stack` and clears its `erased`
  /// entry. No-op when the stack is empty.
  Undo

  /// `touchstart` fired on the reader page. Carries the primary
  /// touch's viewport coordinates; `update` stores them on the
  /// model so `TouchEnd` can compute the gesture delta.
  TouchStart(x: Float, y: Float)

  /// `touchend` fired on the reader page. `update` reads the
  /// matching `touch_start` off the model, classifies the gesture
  /// via `gestures.classify`, and routes a swipe to either a page
  /// navigation or `Undo`. A `Tap` outcome is a no-op — sentence
  /// erasure flows through the synthesized `click` event.
  TouchEnd(x: Float, y: Float)

  /// `touchcancel` fired on the reader page. The browser delivers
  /// this when an in-flight touch is interrupted (system gesture,
  /// modal, notification) and follows it with *no* matching
  /// `touchend`. `update` clears `touch_start` so the next
  /// legitimate `touchend` doesn't classify against the cancelled
  /// gesture's coordinates and emit a phantom swipe.
  TouchCancel

  /// Reader pressed `h` — move the keyboard cursor to the previous
  /// non-erased sentence. Crosses page boundaries: when the cursor
  /// sits on the first non-erased sentence of the current page,
  /// `FocusPrevious` navigates to the previous page and lands the
  /// cursor on its last non-erased sentence. A no-op at the start
  /// of the document. When `focused_sentence` is `None`, the cursor
  /// initialises to the first non-erased sentence on the current
  /// page rather than moving — the first press wakes the cursor up.
  FocusPrevious

  /// Reader pressed `l` — move the keyboard cursor to the next
  /// non-erased sentence. Crosses page boundaries forward, mirror
  /// of `FocusPrevious`. A no-op at the end of the document.
  /// Initialises focus on first press.
  FocusNext

  /// Reader pressed `k` — move the keyboard cursor to the first
  /// non-erased sentence of the previous paragraph. Fully-erased
  /// paragraphs between the cursor's current paragraph and the
  /// target are skipped so the cursor cannot stall on a paragraph
  /// with no visible text. Crosses page boundaries. A no-op at the
  /// start of the document. Initialises focus on first press.
  FocusParagraphUp

  /// Reader pressed `j` — move the keyboard cursor to the first
  /// non-erased sentence of the next paragraph. Mirror of
  /// `FocusParagraphUp`. A no-op at the end of the document.
  /// Initialises focus on first press.
  FocusParagraphDown

  /// Reader pressed `Space` — erase the currently focused sentence
  /// (same effect as a click/tap on that sentence) and advance the
  /// cursor to the next non-erased sentence. Crosses page
  /// boundaries when no non-erased sentence remains after the
  /// erased one on the current page. A no-op when
  /// `focused_sentence` is `None` — there is no cursor target to
  /// act on.
  EraseFocused

  /// Settings panel gear icon (or close button) toggled. Flips
  /// `settings_open`; no DOM side effect.
  ToggleSettings

  /// Reader toggled the dark / light theme switch in the settings
  /// panel. Flips `dark_mode` and pushes `vi-light-mode` onto the
  /// body class list to override the dark palette in CSS.
  ToggleDarkMode

  /// Reader dragged the font-size slider. The reducer clamps the
  /// value into `[min_font_size, max_font_size]`, writes it to the
  /// model, pushes the new value into `--vi-base-font-size`, and
  /// dispatches `ViewportResized` so paragraph heights re-measure
  /// at the new font size before pagination recalculates.
  SetFontSize(Int)

  /// Reader dragged the line-spacing slider. Same flow as
  /// `SetFontSize` but for `--vi-line-height` and the `line_spacing`
  /// model field.
  SetLineSpacing(Float)

  /// Reader toggled ghost mode in the settings panel. Flips
  /// `ghost_mode` and adds/removes `vi-ghost-mode` on the body.
  /// When the toggle goes on, erased sentences fade up to
  /// `ghost_opacity` instead of fully disappearing; when it goes
  /// off, the inline opacity reverts to `0`.
  ToggleGhostMode

  /// Reader dragged the ghost-opacity slider. Clamped into
  /// `[min_ghost_opacity, max_ghost_opacity]`, written to the model,
  /// and pushed into `--vi-ghost-opacity` for completeness — the
  /// view computes the inline opacity directly from the model field,
  /// the custom property is a hook for future CSS rules.
  SetGhostOpacity(Float)

  /// Reader toggled the dyslexia-friendly font switch. Flips
  /// `dyslexia_font` and adds/removes `vi-dyslexia-font` on the
  /// body. The font swap changes paragraph heights, so this also
  /// dispatches `ViewportResized` to trigger re-pagination.
  ToggleDyslexiaFont
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)

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

// ---------------------------------------------------------------------------
// init / update
// ---------------------------------------------------------------------------

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
  // - `load` injects the sample text through the update loop.
  // - The four listener effects (`resize`, `arrow`, `undo`, `vim`)
  //   wire keyboard navigation and the debounced resize handler.
  let viewport_meta =
    effect.from(fn(_dispatch) { ffi.ensure_viewport_fit_cover() })
  let body_classes =
    effect.from(fn(_dispatch) {
      ffi.set_body_class(body_class_light_mode, !dark_mode)
      ffi.set_body_class(body_class_reduced_motion, reduced_motion)
    })
  let load = effect.from(fn(dispatch) { dispatch(TextLoaded(sample.text())) })
  let resize_listener =
    effect.from(fn(dispatch) {
      ffi.on_resize(fn() { dispatch(ViewportResized) })
    })
  let arrow_listener =
    effect.from(fn(dispatch) {
      ffi.on_arrow_key(
        previous_callback: fn() { dispatch(PreviousPage) },
        next_callback: fn() { dispatch(NextPage) },
      )
    })
  let undo_listener =
    effect.from(fn(dispatch) { ffi.on_undo_key(fn() { dispatch(Undo) }) })
  let vim_listener =
    effect.from(fn(dispatch) {
      ffi.on_vim_keys(
        focus_previous_callback: fn() { dispatch(FocusPrevious) },
        focus_paragraph_down_callback: fn() { dispatch(FocusParagraphDown) },
        focus_paragraph_up_callback: fn() { dispatch(FocusParagraphUp) },
        focus_next_callback: fn() { dispatch(FocusNext) },
        erase_focused_callback: fn() { dispatch(EraseFocused) },
        undo_callback: fn() { dispatch(Undo) },
      )
    })

  #(
    model,
    effect.batch([
      viewport_meta,
      body_classes,
      load,
      resize_listener,
      arrow_listener,
      undo_listener,
      vim_listener,
    ]),
  )
}

/// Transition the reader to the next state given a message.
///
/// **Touch gesture pipeline** (`TouchStart` → `TouchEnd` → classify → route):
///
/// 1. `TouchStart` stores the touch origin on `model.touch_start`.
/// 2. `TouchEnd` reads that origin back, calls `gestures.classify/4`,
///    and routes the result:
///    - `Tap` — no-op; sentence erasure flows through the synthesised
///      `click` event on the `.sentence` span.
///    - `SwipeLeft` — `NextPage`.
///    - `SwipeRight` with a non-empty undo stack — `Undo` first so a
///      right-swipe reverses the most recent erase before backing up.
///    - `SwipeRight` with an empty undo stack — `PreviousPage`.
/// 3. `TouchCancel` clears `touch_start` without routing anything,
///    preventing the stale start coordinates from corrupting the next
///    `touchend` classification.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TextLoaded(text) -> #(
      Model(
        ..model,
        text: Some(text),
        flat_paragraphs: pagination.flatten(text),
        pages: [],
        current_page: 0,
        erased: set.new(),
        undo_stack: [],
        touch_start: None,
        focused_sentence: None,
      ),
      measure_after_paint(),
    )

    ParagraphsMeasured(heights, available_height) -> {
      let pages = case model.text {
        None -> []
        Some(_) ->
          pagination.calculate_pages(
            model.flat_paragraphs,
            pagination.heights_from_pairs(heights),
            available_height,
          )
      }
      let total = list.length(pages)
      let clamped = pagination.clamp_page_index(model.current_page, total)
      #(Model(..model, pages: pages, current_page: clamped), effect.none())
    }

    NextPage -> #(go_to_page(model, model.current_page + 1), effect.none())

    PreviousPage -> #(go_to_page(model, model.current_page - 1), effect.none())

    ViewportResized -> #(model, measure_after_paint())

    EraseSentence(global_index) -> #(
      apply_erase(model, global_index),
      effect.none(),
    )

    Undo -> #(apply_undo(model), effect.none())

    FocusPrevious -> #(
      focus_sentence_step(model, navigation.Backward),
      effect.none(),
    )

    FocusNext -> #(
      focus_sentence_step(model, navigation.Forward),
      effect.none(),
    )

    FocusParagraphUp -> #(
      focus_paragraph_step(model, navigation.Backward),
      effect.none(),
    )

    FocusParagraphDown -> #(
      focus_paragraph_step(model, navigation.Forward),
      effect.none(),
    )

    EraseFocused -> #(apply_erase_focused(model), effect.none())

    TouchStart(x, y) -> #(
      Model(..model, touch_start: Some(#(x, y))),
      effect.none(),
    )

    TouchCancel -> #(Model(..model, touch_start: None), effect.none())

    TouchEnd(x, y) -> {
      let cleared = Model(..model, touch_start: None)
      case model.touch_start {
        None -> #(cleared, effect.none())
        Some(#(start_x, start_y)) ->
          case gestures.classify(start_x, start_y, x, y) {
            gestures.Tap -> #(cleared, effect.none())
            gestures.SwipeLeft -> #(
              go_to_page(cleared, cleared.current_page + 1),
              effect.none(),
            )
            gestures.SwipeRight ->
              case cleared.undo_stack {
                [] -> #(
                  go_to_page(cleared, cleared.current_page - 1),
                  effect.none(),
                )
                _ -> #(apply_undo(cleared), effect.none())
              }
          }
      }
    }

    ToggleSettings -> #(
      Model(..model, settings_open: !model.settings_open),
      effect.none(),
    )

    ToggleDarkMode -> apply_toggle_dark_mode(model)

    SetFontSize(size) -> apply_set_font_size(model, size)

    SetLineSpacing(spacing) -> apply_set_line_spacing(model, spacing)

    ToggleGhostMode -> apply_toggle_ghost_mode(model)

    SetGhostOpacity(opacity) -> apply_set_ghost_opacity(model, opacity)

    ToggleDyslexiaFont -> apply_toggle_dyslexia_font(model)
  }
}

// ---------------------------------------------------------------------------
// update — settings-arm helpers
// ---------------------------------------------------------------------------
//
// Each helper owns one settings transition: clamps the incoming value
// (where applicable), writes the new field onto the model, and emits
// the FFI side-effects that mirror the model into the CSS cascade.
// Splitting them out keeps the top-level `update` case statement scannable
// and lets each transition be unit-tested without inspecting the others.

fn apply_toggle_dark_mode(model: Model) -> #(Model, Effect(Msg)) {
  let new_dark = !model.dark_mode
  #(
    Model(..model, dark_mode: new_dark),
    effect.from(fn(_dispatch) {
      ffi.set_body_class(body_class_light_mode, !new_dark)
    }),
  )
}

fn apply_set_font_size(model: Model, size: Int) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(size, min_font_size, max_font_size)
  #(
    Model(..model, font_size: clamped),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_css_property(css_var_font_size, int.to_string(clamped) <> "px")
      }),
      // Paragraph wrap heights depend on font size — kick the measurement
      // loop so pagination recalculates at the new metrics.
      // `ViewportResized` is the existing entry point; dispatching it
      // keeps the resize path and the settings-change path identical from
      // `measure_after_paint` onward.
      repaginate_after_paint(),
    ]),
  )
}

fn apply_set_line_spacing(
  model: Model,
  spacing: Float,
) -> #(Model, Effect(Msg)) {
  let clamped = clamp_float(spacing, min_line_spacing, max_line_spacing)
  #(
    Model(..model, line_spacing: clamped),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_css_property(css_var_line_height, float.to_string(clamped))
      }),
      repaginate_after_paint(),
    ]),
  )
}

fn apply_toggle_ghost_mode(model: Model) -> #(Model, Effect(Msg)) {
  let new_ghost = !model.ghost_mode
  #(
    Model(..model, ghost_mode: new_ghost),
    // Only the body class is toggled here. The `--vi-ghost-opacity`
    // custom property is owned by `apply_set_ghost_opacity`, which
    // writes it on every change to `model.ghost_opacity`; pushing it
    // again from this arm would be a dead write — the variable is
    // already up to date when ghost mode flips on or off.
    effect.from(fn(_dispatch) {
      ffi.set_body_class(body_class_ghost_mode, new_ghost)
    }),
  )
}

fn apply_set_ghost_opacity(
  model: Model,
  opacity: Float,
) -> #(Model, Effect(Msg)) {
  let clamped = clamp_float(opacity, min_ghost_opacity, max_ghost_opacity)
  #(
    Model(..model, ghost_opacity: clamped),
    effect.from(fn(_dispatch) {
      ffi.set_css_property(css_var_ghost_opacity, float.to_string(clamped))
    }),
  )
}

fn apply_toggle_dyslexia_font(model: Model) -> #(Model, Effect(Msg)) {
  let new_font = !model.dyslexia_font
  #(
    Model(..model, dyslexia_font: new_font),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_body_class(body_class_dyslexia_font, new_font)
      }),
      // OpenDyslexic has wider glyph metrics than the system stack, so
      // paragraph wrap heights shift on the toggle. Re-measure for the
      // same reason `apply_set_font_size` does.
      repaginate_after_paint(),
    ]),
  )
}

/// Clamp `value` into `[lo, hi]`. Defensive helper for slider /
/// stepper inputs; the inputs themselves carry `min` and `max`
/// attributes, but a future programmatic call (or a malformed event)
/// could bypass them, so the reducer is the authority.
///
/// Exposed for tests that pin the boundary behaviour at the lo and
/// hi rails — the slider arms in `update` delegate to this helper, so
/// asserting it directly is the smallest unit that proves the
/// out-of-range guard works.
pub fn clamp_int(value: Int, lo: Int, hi: Int) -> Int {
  case value < lo, value > hi {
    True, _ -> lo
    _, True -> hi
    _, _ -> value
  }
}

/// Float counterpart to `clamp_int`. Exposed for the same reason —
/// the line-spacing and ghost-opacity sliders both delegate to this
/// helper.
pub fn clamp_float(value: Float, lo: Float, hi: Float) -> Float {
  case value <. lo, value >. hi {
    True, _ -> lo
    _, True -> hi
    _, _ -> value
  }
}

/// Pop the most recent erase off `undo_stack` and remove its index
/// from `erased`. Returns the model unchanged when the stack is
/// empty. Shared between the `Undo` reducer arm and the SwipeRight
/// branch of `TouchEnd` — both consume the head of the stack in
/// identical ways, and a copy-and-paste here would let the two
/// branches drift apart on a future refactor (e.g. one of them
/// growing a "max-undo-count" cap that the other forgot).
fn apply_undo(model: Model) -> Model {
  case model.undo_stack {
    [] -> model
    [last, ..rest] ->
      Model(..model, erased: set.delete(model.erased, last), undo_stack: rest)
  }
}

/// Insert `global_index` into `erased` and push it onto the
/// `undo_stack`, capped to `undo_stack_depth` entries. A repeat
/// erase on an already-erased sentence is a no-op so the undo
/// stack never carries duplicate entries — without that guard, an
/// `EraseFocused` press on a sentence the reader had earlier
/// clicked would push a second copy and force two undo presses to
/// restore one sentence. Shared between `EraseSentence` (from
/// click/tap) and `EraseFocused` (from the keyboard cursor).
fn apply_erase(model: Model, global_index: Int) -> Model {
  case set.contains(model.erased, global_index) {
    True -> model
    False ->
      Model(
        ..model,
        erased: set.insert(model.erased, global_index),
        undo_stack: [global_index, ..model.undo_stack]
          |> list.take(undo_stack_depth),
      )
  }
}

/// Step the keyboard cursor by one sentence in `direction`,
/// crossing page boundaries when the next visible sentence lives
/// on a different page. When the cursor is dormant
/// (`focused_sentence: None`), the first press initialises focus
/// to the first non-erased sentence on the current page rather
/// than moving — the press wakes the cursor up.
fn focus_sentence_step(model: Model, direction: navigation.Direction) -> Model {
  let locations = navigation.locate_sentences(model.pages)
  case model.focused_sentence {
    None -> initialise_focus(model, locations)
    Some(current) ->
      case
        navigation.next_sentence(locations, current, model.erased, direction)
      {
        None -> model
        Some(target) -> move_focus(model, target)
      }
  }
}

/// Step the keyboard cursor by one paragraph in `direction`. The
/// landing rule is "first non-erased sentence of the
/// previous/next paragraph that still has visible text",
/// implemented in `navigation.next_paragraph_sentence`. Initialises
/// focus on first press, same rule as `focus_sentence_step`.
fn focus_paragraph_step(
  model: Model,
  direction: navigation.Direction,
) -> Model {
  let locations = navigation.locate_sentences(model.pages)
  case model.focused_sentence {
    None -> initialise_focus(model, locations)
    Some(current) ->
      case navigation.locate(locations, current) {
        None -> model
        Some(current_location) ->
          case
            navigation.next_paragraph_sentence(
              locations,
              current_location.paragraph_global_index,
              model.erased,
              direction,
            )
          {
            None -> model
            Some(target) -> move_focus(model, target)
          }
      }
  }
}

/// Erase the focused sentence and advance the cursor to the next
/// non-erased sentence (Forward), crossing page boundaries when the
/// erased sentence was the last visible one on its page. When the
/// erase happened to land on the document's final visible sentence
/// the cursor goes dormant (`focused_sentence: None`); the reader
/// then has to press a vim key again to re-initialise.
fn apply_erase_focused(model: Model) -> Model {
  case model.focused_sentence {
    None -> model
    Some(idx) -> {
      let erased_model = apply_erase(model, idx)
      let locations = navigation.locate_sentences(erased_model.pages)
      case
        navigation.next_sentence(
          locations,
          idx,
          erased_model.erased,
          navigation.Forward,
        )
      {
        None -> Model(..erased_model, focused_sentence: None)
        Some(target) -> move_focus(erased_model, target)
      }
    }
  }
}

/// Set the cursor to `target`, changing the current page first
/// when the target lives on a different page. Used by every vim
/// navigation message — the navigation module returns the target
/// page alongside the target sentence so this helper can commit
/// both in one place.
fn move_focus(model: Model, target: navigation.SentenceLocation) -> Model {
  let with_page = change_page(model, target.page_index)
  Model(..with_page, focused_sentence: Some(target.sentence_global_index))
}

/// Initialise the cursor to the first non-erased sentence on the
/// current page. The result is `None` when every sentence on the
/// current page is erased — a legitimate state during a re-read
/// where the reader has erased an entire page and the next vim key
/// would normally advance them off it.
fn initialise_focus(
  model: Model,
  locations: List(navigation.SentenceLocation),
) -> Model {
  let focused =
    navigation.first_on_page(locations, model.current_page, model.erased)
    |> option.map(fn(loc) { loc.sentence_global_index })
  Model(..model, focused_sentence: focused)
}

/// Move the reader to `candidate` after clamping to the current
/// `pages` range. Clears `undo_stack` only when `clamped` differs
/// from `current_page` — a real page change commits every erase
/// that has not yet been undone, but a clamp-to-self (ArrowRight on
/// the last page, ArrowLeft on the first) must leave the undo stack
/// intact so a reader's stray reflex tap does not silently destroy
/// erases that were undoable a moment earlier.
///
/// Used by `NextPage`/`PreviousPage`/swipes — input modes where
/// the reader is paging through the book on their own. When
/// `focused_sentence` is `Some(_)` (i.e. the reader is in vim
/// mode) and the page actually changes, the cursor resets to the
/// first non-erased sentence on the new page so the reader has
/// somewhere to start on the fresh page. Vim-key navigation
/// bypasses this helper through `change_page`/`move_focus`
/// because the navigation module decides exactly where the cursor
/// should land.
fn go_to_page(model: Model, candidate: Int) -> Model {
  let after = change_page(model, candidate)
  let focused = case after.current_page == model.current_page {
    True -> model.focused_sentence
    False ->
      case model.focused_sentence {
        None -> None
        Some(_) ->
          navigation.first_on_page(
            navigation.locate_sentences(after.pages),
            after.current_page,
            after.erased,
          )
          |> option.map(fn(loc) { loc.sentence_global_index })
      }
  }
  Model(..after, focused_sentence: focused)
}

/// Lower-level page change: clamps `candidate` into the valid
/// page range and clears the undo stack only when the page
/// actually changes. Shared between `go_to_page` (the
/// touch/arrow-key path) and `move_focus` (the vim path) — both
/// need the same "no page change, no undo-stack clear" invariant
/// and pulling the logic into one helper stops the two callers
/// from drifting apart.
fn change_page(model: Model, candidate: Int) -> Model {
  let total = list.length(model.pages)
  let clamped = pagination.clamp_page_index(candidate, total)
  case clamped == model.current_page {
    True -> model
    False -> Model(..model, current_page: clamped, undo_stack: [])
  }
}

/// Schedule an `after_paint` effect that reads paragraph heights and
/// the available content-area height from the live DOM, then
/// dispatches `ParagraphsMeasured`. Falls back to `window.innerHeight`
/// when the page-content sentinel cannot be located so pagination
/// still produces output rather than getting wedged.
fn measure_after_paint() -> Effect(Msg) {
  effect.after_paint(fn(dispatch, _root) {
    let available_height = case ffi.get_element_height("#" <> page_content_id) {
      Ok(height) -> height
      Error(_) -> ffi.get_viewport_height()
    }
    let heights = ffi.measure_paragraphs("#" <> measurement_id)
    dispatch(ParagraphsMeasured(
      heights: heights,
      available_height: available_height,
    ))
  })
}

/// Re-trigger pagination by dispatching `ViewportResized`. Used after
/// settings changes that alter paragraph wrap heights (font size,
/// line spacing, dyslexia font). Going through the existing message
/// keeps one re-measure path instead of two — `ViewportResized` is
/// already the single producer of the measurement effect for window
/// resizes, and threading settings changes through the same arm means
/// every future measurement-side concern (e.g. a debounce, or a
/// progress indicator) only has to land in one place.
fn repaginate_after_paint() -> Effect(Msg) {
  effect.from(fn(dispatch) { dispatch(ViewportResized) })
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

/// Top-level view. Renders a loading placeholder until `TextLoaded`
/// delivers text, then delegates to `view_paginated`. The settings
/// panel rides as a sibling overlay rendered conditionally on
/// `model.settings_open` — it is only ever in the DOM when the panel
/// is open, so the empty/loading rendering is unaffected by settings
/// state.
pub fn view(model: Model) -> Element(Msg) {
  let body = case model.text {
    None -> view_placeholder()
    Some(_) -> view_paginated(model)
  }

  let overlay = case model.settings_open {
    True -> view_settings_panel(model)
    False -> element.none()
  }

  html.div([attribute.id("vi-shell"), attribute.class("reader")], [
    body,
    overlay,
  ])
}

fn view_placeholder() -> Element(Msg) {
  html.div([attribute.class("reader-placeholder")], [html.text("Loading...")])
}

/// Build the full reading surface: visible page, control bar (page
/// indicator + settings gear), and off-screen measurement container.
///
/// The `#vi-measurement` container receives all paragraphs from the
/// whole book — not just the current page. This lets `measure_after_paint`
/// read every paragraph height in a single DOM pass after `TextLoaded` or
/// `ViewportResized`, rather than re-measuring on every page turn.
///
/// Touch handlers are placed on `.reader-page` rather than the outer
/// `.reader-text` so neither the control bar (with its tappable gear
/// icon) nor the off-screen measurement container can intercept page
/// swipes. The measurement container is `pointer-events: none`
/// (see `.reader-measurement` in `styles.css`) so its descendants
/// cannot receive any touch or click events.
fn view_paginated(model: Model) -> Element(Msg) {
  let total = list.length(model.pages)
  let erased_opacity = erased_opacity_value(model)
  let visible = case pagination.nth(model.pages, model.current_page) {
    Some(page) ->
      view_page(
        page,
        model.erased,
        model.focused_sentence,
        True,
        erased_opacity,
      )
    None -> view_preparing()
  }

  html.div([attribute.class("reader-text")], [
    html.div(
      [
        attribute.id(reading_area_id),
        attribute.class("reader-page"),
        gestures.on_touch_start(TouchStart),
        gestures.on_touch_end(TouchEnd),
        gestures.on_touch_cancel(TouchCancel),
      ],
      [
        html.div(
          [
            attribute.id(page_content_id),
            attribute.class("reader-page-content"),
          ],
          [visible],
        ),
      ],
    ),
    view_control_bar(total, model.current_page),
    view_measurement_container(model.flat_paragraphs, erased_opacity),
  ])
}

/// Resolve the opacity string applied to erased sentences. Returns
/// `"0"` when ghost mode is off so the bundled rendered-HTML tests
/// (which pin `opacity:0;`) stay stable; otherwise the configured
/// ghost-opacity float. The string is threaded through every
/// rendering function rather than read from a CSS custom property
/// because the rendered HTML — not the cascade — drives the
/// transition's start/end values; the cascade alone wouldn't change
/// the inline style, and the fade wouldn't fire.
///
/// Exposed so the ghost-mode tests can assert both branches without
/// reaching through the view layer — the `False` branch is implicitly
/// covered by every existing rendering test, but the `True` branch
/// has no view-level pin yet.
pub fn erased_opacity_value(model: Model) -> String {
  case model.ghost_mode {
    False -> "0"
    True -> float.to_string(model.ghost_opacity)
  }
}

fn view_preparing() -> Element(Msg) {
  html.div([attribute.class("reader-preparing")], [
    html.text("Preparing pages..."),
  ])
}

fn view_page(
  page: Page,
  erased: Set(Int),
  focused: Option(Int),
  interactive: Bool,
  erased_opacity: String,
) -> Element(Msg) {
  html.div(
    [
      attribute.class("page"),
      attribute.attribute("data-page-index", int.to_string(page.index)),
    ],
    list.map(page.paragraphs, fn(p) {
      view_page_paragraph(p, erased, focused, interactive, erased_opacity)
    }),
  )
}

/// Bottom control bar. Holds the page indicator (centred) and the
/// settings gear button (right-aligned, ≥ 44 × 44 CSS pixels). The
/// page indicator renders an empty string when no pages are
/// available yet; the bar's `min-height: var(--vi-tap-target)` rule
/// (see `.reader-control-bar` in `styles.css`) keeps the row at the
/// thumb-friendly tap target so the gear is reachable from the first
/// paint, before pagination has produced its first result.
fn view_control_bar(total: Int, current: Int) -> Element(Msg) {
  let indicator_text = case total {
    0 -> ""
    _ -> "Page " <> int.to_string(current + 1) <> " of " <> int.to_string(total)
  }
  html.div([attribute.class("reader-control-bar")], [
    html.div([attribute.class("reader-page-indicator")], [
      html.text(indicator_text),
    ]),
    html.button(
      [
        attribute.class("reader-settings-button"),
        attribute.attribute("aria-label", "Open settings"),
        attribute.type_("button"),
        event.on_click(ToggleSettings),
      ],
      // Unicode gear glyph keeps the asset surface zero. A later
      // quest can swap this for an inline SVG if iconography becomes
      // a theme concern.
      [html.text("⚙")],
    ),
  ])
}

fn view_measurement_container(
  paragraphs: List(PageParagraph),
  erased_opacity: String,
) -> Element(Msg) {
  // Off-screen mirror of the visible reading area. Carries the same
  // class hierarchy (`reader-text` → paragraph spans) so paragraph
  // line-wrap heights match what the visible page will render. CSS
  // hides it from layout flow (`position: absolute; visibility:
  // hidden`) without removing it from the DOM, so
  // `getBoundingClientRect().height` still reports valid pixel
  // values to the FFI.
  //
  // The mirror passes an empty erase set *and* `interactive: False`:
  // opacity-driven attributes don't affect `getBoundingClientRect().height`
  // so the erase styling is omitted regardless, and the same
  // reasoning rules out the per-sentence `on_click` — the mirror is
  // `pointer-events: none`, so any click handler attached there is
  // unreachable. Skipping the handler keeps the virtual DOM smaller
  // by N event attributes (one per sentence on the whole book), and
  // a future DOM query that drifted from scoping to
  // `#vi-page-content` would not accidentally fire phantom erases.
  html.div(
    [
      attribute.id(measurement_id),
      attribute.class("reader-measurement"),
      attribute.attribute("aria-hidden", "true"),
    ],
    list.map(paragraphs, fn(p) {
      view_page_paragraph(p, set.new(), None, False, erased_opacity)
    }),
  )
}

fn view_page_paragraph(
  page_paragraph: PageParagraph,
  erased: Set(Int),
  focused: Option(Int),
  interactive: Bool,
  erased_opacity: String,
) -> Element(Msg) {
  // `data-paragraph-global-index` lives on the `.page-paragraph`
  // wrapper, not the inner `<p>`, so the FFI measures the wrapper's
  // `getBoundingClientRect().height`. The wrapper establishes a
  // block formatting context (`display: flow-root` in `styles.css`)
  // so the inner `.chapter-title`/`.paragraph` vertical margins are
  // contained — the measured height equals the page space the
  // wrapper actually occupies. Measuring the inner `<p>` instead
  // would silently drop the 1.2rem paragraph margin (and any
  // chapter-title chrome), and the reader would lose lines at every
  // page bottom.
  //
  // `data-chapter-index` rides on the wrapper too — unconditionally,
  // so untitled chapters are still inspectable in the DOM.
  let title_element = case page_paragraph.chapter_title {
    Some(title) ->
      html.h2([attribute.class("chapter-title")], [html.text(title)])
    None -> element.none()
  }

  html.div(
    [
      attribute.class("page-paragraph"),
      attribute.attribute(
        "data-paragraph-global-index",
        int.to_string(page_paragraph.global_index),
      ),
      attribute.attribute(
        "data-chapter-index",
        int.to_string(page_paragraph.chapter_index),
      ),
    ],
    [
      title_element,
      view_paragraph(
        page_paragraph.paragraph,
        erased,
        focused,
        interactive,
        erased_opacity,
      ),
    ],
  )
}

fn view_paragraph(
  paragraph: Paragraph,
  erased: Set(Int),
  focused: Option(Int),
  interactive: Bool,
  erased_opacity: String,
) -> Element(Msg) {
  // A literal " " text node between sentences keeps the gap visible
  // when each sentence's last word omits its trailing space.
  let sentence_elements =
    paragraph.sentences
    |> list.map(fn(s) {
      view_sentence(s, erased, focused, interactive, erased_opacity)
    })
    |> list.intersperse(html.text(" "))

  html.p([attribute.class("paragraph")], sentence_elements)
}

/// Render one sentence span. `interactive` gates the `on_click`
/// handler — the visible reading area passes `True`, the off-screen
/// measurement mirror passes `False` so its unreachable
/// (`pointer-events: none`) sentences don't carry dead handlers.
///
/// `on_click` covers both desktop clicks and mobile-synthesized
/// taps. The synthesized click only fires when the touch movement
/// stays below the browser's own click-cancellation threshold
/// (~10–15px), which is well under `gestures.swipe_threshold`, so a
/// real swipe never lands an accidental erase.
///
/// `focused` carries the global index of the keyboard cursor's
/// current sentence, or `None` when the cursor is dormant. The
/// matching sentence picks up the `sentence-focused` class so the
/// reader can see where the cursor is. The class is rendered on
/// both interactive and non-interactive sentences — the
/// measurement mirror is passed `None` anyway, so this branch
/// only fires on the visible page.
///
/// `erased_opacity` is the opacity string applied to erased
/// sentences. The caller computes it from `model.ghost_mode` /
/// `model.ghost_opacity` (see `erased_opacity_value`) — when ghost
/// mode is off the value is the literal string `"0"`, preserving
/// the rendered-HTML contract that the existing reader tests pin
/// against.
///
/// Exposed for tests that need to assert the click handler stays
/// wired to visible sentences — Lustre's HTML serialiser strips
/// event attributes, so the only way to pin the contract is to
/// inspect the returned `Element` directly.
pub fn view_sentence(
  sentence: Sentence,
  erased: Set(Int),
  focused: Option(Int),
  interactive: Bool,
  erased_opacity: String,
) -> Element(Msg) {
  let word_count = list.length(sentence.words)
  let words =
    list.index_map(sentence.words, fn(word, index) {
      // Words carry their own trailing space so adjacent word spans
      // wrap cleanly under `display: inline`. The final word in a
      // sentence drops the space — the inter-sentence separator
      // above owns that boundary instead.
      let with_trailing_space = index < word_count - 1
      view_word(word, with_trailing_space)
    })

  let is_erased = set.contains(erased, sentence.global_index)
  let is_focused = case focused {
    None -> False
    Some(idx) -> idx == sentence.global_index
  }
  let class_value = case is_focused {
    True -> "sentence sentence-focused"
    False -> "sentence"
  }
  // Both conditional attributes collapse into a single trailing list
  // so the surrounding `html.span` call constructs the attribute
  // sequence in one literal expression rather than appending two
  // separately-built lists.
  let trailing_attrs = case interactive, is_erased {
    True, True -> [
      event.on_click(EraseSentence(sentence.global_index)),
      attribute.style("opacity", erased_opacity),
    ]
    True, False -> [event.on_click(EraseSentence(sentence.global_index))]
    False, True -> [attribute.style("opacity", erased_opacity)]
    False, False -> []
  }

  html.span(
    [
      attribute.class(class_value),
      attribute.attribute(
        "data-sentence-index",
        int.to_string(sentence.global_index),
      ),
      ..trailing_attrs
    ],
    words,
  )
}

fn view_word(word: Word, with_trailing_space: Bool) -> Element(Msg) {
  let text_content = case with_trailing_space {
    True -> word.text <> " "
    False -> word.text
  }

  html.span(
    [
      attribute.class("word"),
      attribute.attribute("data-global-index", int.to_string(word.global_index)),
    ],
    [html.text(text_content)],
  )
}

// ---------------------------------------------------------------------------
// View — settings panel
// ---------------------------------------------------------------------------

/// Settings overlay rendered as a fixed-position scrim wrapping a
/// bottom-sheet panel. The scrim itself catches taps that fall
/// outside the panel and closes the overlay — same as the close
/// button — so the reader can dismiss without aiming for a small
/// target. Inside, every row maps to one setting on the model.
fn view_settings_panel(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class("settings-overlay"),
      attribute.attribute("role", "dialog"),
      attribute.attribute("aria-modal", "true"),
      attribute.attribute("aria-label", "Reader settings"),
      // A click on the scrim — not the panel — closes the overlay.
      // The panel itself stops propagation via the inner click guard
      // below, so taps inside the panel never reach this listener.
      event.on_click(ToggleSettings),
    ],
    [view_settings_sheet(model)],
  )
}

/// Inner sheet for the settings panel. The sheet swallows click
/// events so taps inside it don't bubble up to the scrim's close
/// handler — without this guard, every slider drag and toggle press
/// would also close the panel. The propagation guard is encapsulated
/// in `stop_click_propagation` so the `Msg` ADT doesn't carry a
/// `NoOp` variant just to satisfy Lustre's "handler required" rule.
fn view_settings_sheet(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-panel"), stop_click_propagation()], [
    view_settings_header(),
    view_theme_toggle(model),
    view_font_size_slider(model),
    view_line_spacing_slider(model),
    view_ghost_mode_toggle(model),
    view_ghost_opacity_slider(model),
    view_dyslexia_font_toggle(model),
  ])
}

/// Attach a click listener that stops propagation but never dispatches
/// a message. Used by the settings sheet to keep slider drags and
/// toggle presses from bubbling up to the scrim's close handler.
///
/// Implementation note: Lustre's `event.stop_propagation` is an
/// attribute modifier that operates on an `Event` attribute, not a
/// standalone attribute — so the propagation guard needs a paired
/// event handler to attach to. `event.on` takes a `Decoder(Msg)`;
/// `decode.failure(...)` always fails, which means the runtime
/// silently drops the event (see `reconciler.ffi.mjs#handleEvent` —
/// `stopPropagation` runs unconditionally when the attribute carries
/// `vattr.always`, but the model dispatch only fires on a successful
/// decode). The placeholder `Msg` value is never returned and never
/// dispatched.
fn stop_click_propagation() -> attribute.Attribute(Msg) {
  event.on("click", decode.failure(ToggleSettings, "stop-propagation"))
  |> event.stop_propagation
}

fn view_settings_header() -> Element(Msg) {
  html.div([attribute.class("settings-panel-header")], [
    html.h2([attribute.class("settings-panel-title")], [
      html.text("Reader settings"),
    ]),
    html.button(
      [
        attribute.class("settings-panel-close"),
        attribute.attribute("aria-label", "Close settings"),
        attribute.type_("button"),
        event.on_click(ToggleSettings),
      ],
      [html.text("✕")],
    ),
  ])
}

fn view_theme_toggle(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Dark mode"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(model.dark_mode),
        event.on_check(fn(_checked) { ToggleDarkMode }),
      ]),
    ]),
  ])
}

fn view_ghost_mode_toggle(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Ghost mode"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(model.ghost_mode),
        event.on_check(fn(_checked) { ToggleGhostMode }),
      ]),
    ]),
  ])
}

fn view_dyslexia_font_toggle(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Dyslexia-friendly font"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(model.dyslexia_font),
        event.on_check(fn(_checked) { ToggleDyslexiaFont }),
      ]),
    ]),
  ])
}

fn view_font_size_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Font size")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(int.to_string(model.font_size) <> "px"),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(int.to_string(min_font_size)),
      attribute.max(int.to_string(max_font_size)),
      attribute.step("1"),
      attribute.value(int.to_string(model.font_size)),
      attribute.attribute("aria-label", "Font size in pixels"),
      event.on_input(fn(value) {
        // `parse` returns `Result(Int, Nil)` — a slider always emits a
        // valid integer string, but on the off chance the browser
        // sends something garbled, fall back to the current model
        // value via the clamp in the reducer.
        case int.parse(value) {
          Ok(parsed) -> SetFontSize(parsed)
          Error(_) -> SetFontSize(model.font_size)
        }
      }),
    ]),
  ])
}

fn view_line_spacing_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Line spacing")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(float.to_string(model.line_spacing)),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(float.to_string(min_line_spacing)),
      attribute.max(float.to_string(max_line_spacing)),
      attribute.step("0.1"),
      attribute.value(float.to_string(model.line_spacing)),
      attribute.attribute("aria-label", "Line spacing multiplier"),
      event.on_input(fn(value) {
        case float.parse(value) {
          Ok(parsed) -> SetLineSpacing(parsed)
          Error(_) -> SetLineSpacing(model.line_spacing)
        }
      }),
    ]),
  ])
}

fn view_ghost_opacity_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Ghost opacity")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(float.to_string(model.ghost_opacity)),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(float.to_string(min_ghost_opacity)),
      attribute.max(float.to_string(max_ghost_opacity)),
      attribute.step("0.01"),
      attribute.value(float.to_string(model.ghost_opacity)),
      attribute.attribute("aria-label", "Ghost mode opacity"),
      event.on_input(fn(value) {
        case float.parse(value) {
          Ok(parsed) -> SetGhostOpacity(parsed)
          Error(_) -> SetGhostOpacity(model.ghost_opacity)
        }
      }),
    ]),
  ])
}
