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
//// Keyboard navigation (`ArrowRight`) and `resize` are both wired
//// through `client/ffi.gleam`. `resize` is debounced in the FFI so
//// a continuous drag does not flood the update loop.
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
/// `--vi-line-height` (the warm-palette mock pacing is `1.85`,
/// which gives the prose enough breathing room that the line-
/// highlight overlay reads as one row rather than wrapping two).
pub const default_line_spacing: Float = 1.85

pub const min_line_spacing: Float = 1.2

pub const max_line_spacing: Float = 2.0

/// Default `ghost_opacity` — applied only when `ghost_mode` is on.
/// The value is a deliberately gentle starting point: most readers
/// graduating from fully-invisible erases want a faint reminder that
/// something is there, not a half-visible second copy of the prose.
pub const default_ghost_opacity: Float = 0.06

pub const min_ghost_opacity: Float = 0.0

pub const max_ghost_opacity: Float = 0.3

/// Default WPM for the real-time fade engine. 200 wpm is the
/// mid-range of typical adult silent-reading speeds (most readers
/// fall in the 175–300 wpm band); it gives a comfortable starting
/// point that newcomers can ratchet up or down with the slider.
pub const default_wpm: Int = 200

/// Lower bound on the WPM slider. 60 wpm is roughly one word per
/// second — slow enough for the reader to deliberately watch each
/// word fade, which matches the therapeutic-exposure pacing the
/// app exists to support.
pub const min_wpm: Int = 60

/// Upper bound. 500 wpm is the floor of speed-reading territory;
/// past this point the eye stops processing words individually and
/// the fade animation would visually blur into a single sweep,
/// defeating the per-word visibility contract.
pub const max_wpm: Int = 500

/// Default extra pause inserted between the last word of one
/// paragraph and the first word of the next. 1 second gives the
/// reader a beat to register the paragraph break, then resumes the
/// steady WPM rhythm.
pub const default_paragraph_delay_ms: Int = 1000

/// Lower bound on the Paragraph-pause slider. Zero disables the
/// inter-paragraph pause entirely so the engine ticks at the
/// steady WPM rhythm regardless of paragraph boundaries — the
/// right choice for a reader who wants uninterrupted pace.
pub const min_paragraph_delay_ms: Int = 0

/// Upper bound on the Paragraph-pause slider. 5 seconds is long
/// enough to feel like a deliberate break-and-breathe beat
/// without dragging the reading flow into stop-start tedium;
/// past this point readers tend to perceive the engine as
/// stalled rather than paused.
pub const max_paragraph_delay_ms: Int = 5000

/// Default extra pause inserted between the last word of one page
/// and the first word of the next page. Longer than the paragraph
/// delay because the page turn is a visual context shift — the
/// reader's eye has to reset to the top of the new page before the
/// next fade is meaningful.
pub const default_page_delay_ms: Int = 2000

/// Lower bound on the Page-pause slider. Zero disables the
/// page-turn pause so the engine continues directly into the
/// first word of the new page — useful for fast readers who
/// can mentally re-anchor without a beat.
pub const min_page_delay_ms: Int = 0

/// Upper bound on the Page-pause slider. Matches
/// `max_paragraph_delay_ms` so the sliders feel consistent
/// even though the page-turn beat is typically chosen longer
/// than the paragraph beat; 5 seconds is still inside the
/// "deliberate pause" envelope rather than reading as a stall.
pub const max_page_delay_ms: Int = 5000

/// One minute in milliseconds — the constant the WPM-to-interval
/// conversion divides by. Pulled out so the math is named in
/// the source rather than relying on a magic literal.
const ms_per_minute: Int = 60_000

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

/// Reading mode. `Manual` is the original tap/click + vim-key
/// reader: erasure happens on explicit user input. `RealTime` is
/// the fade engine: words fade away on a WPM-paced timer, with
/// pause/resume on Space (desktop) and tap (mobile). Both modes
/// share the same `Model`; the bitsets (`erased`, `erased_words`)
/// coexist so a reader who erases in Manual mode and then switches
/// to RealTime keeps the prior erases visible-as-gone.
pub type Mode {
  Manual
  RealTime
}

/// Lifecycle state of the real-time fade engine. `Stopped` means
/// no timer scheduled and `next_word_index` is `None` — the engine
/// is dormant. `Running` means a timer is in flight and
/// `next_word_index` carries the word to fade on the next tick.
/// `Paused` is `Running` minus the timer — the reader hit
/// space/tap, so the schedule is suspended but `next_word_index`
/// remains intact so a resume picks up at the same word.
pub type EngineState {
  Stopped
  Running
  Paused
}

/// One visual line of the current page, measured against the live
/// DOM. The line spans the rendered word spans whose
/// `getBoundingClientRect().top` rounds to the same y-coordinate;
/// `first_word_gi` and `last_word_gi` are the lowest and highest
/// `Word.global_index` to land on that line. `top` is the line's
/// distance from the page-content container's top edge (already
/// converted from viewport-relative on the FFI side) and `height`
/// is the per-line maximum bounding-box height — both in CSS
/// pixels.
///
/// The active-line overlay reads `top` and `height` directly off
/// the matching box to position itself; the engine's per-tick
/// `next_word_index` is looked up against `first_word_gi` /
/// `last_word_gi` to figure out which box to highlight.
pub type LineBox {
  LineBox(top: Float, height: Float, first_word_gi: Int, last_word_gi: Int)
}

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
///   `SegmentedText` on every `NextPage` keystroke for no semantic
///   reason.
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
/// * `mode` — `Manual` (tap/click/vim erasure) or `RealTime` (the
///   WPM-paced fade engine). Default `Manual` to keep the original
///   reader behaviour for first-time users; the mode toggle in the
///   settings panel switches modes without converting the bitsets.
/// * `wpm` — words-per-minute pacing for the fade engine. The
///   per-word delay derives from this: `60_000 / wpm` milliseconds.
///   Clamped into `[min_wpm, max_wpm]` at the reducer boundary.
/// * `engine_state` — lifecycle state of the fade engine. See
///   `EngineState`. Default `Stopped` — RealTime mode does not
///   auto-start; the reader must hit Space/tap to begin.
/// * `next_word_index` — `Some(global_index)` of the word the
///   engine will fade on the next tick, or `None` when the engine
///   is `Stopped` or has nothing left to fade on the document.
///   Carries through `Paused` so resume picks up at the same word.
/// * `erased_words` — set of `Word.global_index` for every word the
///   fade engine has erased. Disjoint from `erased` (which keys by
///   `Sentence.global_index`): a word is hidden when *either*
///   `erased_words` contains it directly *or* the sentence-level
///   `erased` contains its parent sentence. Manual-mode erasures
///   flow into `erased`; RealTime-mode fades flow into
///   `erased_words`, and both bitsets coexist across mode switches.
/// * `paragraph_delay_ms` — extra delay inserted after the last
///   word of one paragraph fades, before the first word of the
///   next paragraph fades. Reader-configurable in the settings
///   panel; clamped into `[min_paragraph_delay_ms,
///   max_paragraph_delay_ms]`.
/// * `page_delay_ms` — extra delay inserted on a page boundary
///   when the engine advances pages automatically. Clamped into
///   `[min_page_delay_ms, max_page_delay_ms]`.
/// * `line_boxes` — visual line geometry for the current page,
///   measured against the live DOM after every layout-affecting
///   event (`ParagraphsMeasured`, `NextPage`, viewport / settings
///   changes that re-flow text). Empty between layout and the
///   first `LinesMeasured` dispatch, and during a resize while the
///   measurement effect is in flight. Read by the active-line
///   overlay in `view_paginated` to position itself; the engine
///   reducer treats `[]` as "no overlay" so a transient empty
///   state simply skips rendering rather than crashing.
/// * `active_line` — `Some(index)` into `line_boxes` identifying
///   the line that contains the engine's `next_word_index`, or
///   `None` when the engine has no live target (Stopped, or
///   `line_boxes` empty, or `next_word_index` not contained in
///   any measured line). Recomputed on every event that moves
///   `next_word_index` or replaces `line_boxes`.
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
    mode: Mode,
    wpm: Int,
    engine_state: EngineState,
    next_word_index: Option(Int),
    erased_words: Set(Int),
    paragraph_delay_ms: Int,
    page_delay_ms: Int,
    line_boxes: List(LineBox),
    active_line: Option(Int),
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

  /// Visual line geometry for the current page has been read via
  /// FFI. The reducer stores the boxes on the model and recomputes
  /// `active_line` against the in-flight `next_word_index`. Fired
  /// from `measure_lines_after_paint` after every event that can
  /// re-flow the visible page (pagination completion, page turn,
  /// font / spacing changes, fade-engine page advance).
  LinesMeasured(boxes: List(LineBox))

  /// Reader requested the next page (`ArrowRight` or swipe-left
  /// gesture). Clears the undo stack — erases on the page being
  /// left commit.
  NextPage

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
  /// non-erased sentence on the current page. Stops at the page
  /// boundary: when the cursor is on the first non-erased sentence
  /// of the current page, `FocusPrevious` is a no-op. A no-op when
  /// `focused_sentence` is `None` — the first press wakes the cursor
  /// rather than moving it (initialises to the first non-erased
  /// sentence on the current page).
  FocusPrevious

  /// Reader pressed `l` — move the keyboard cursor to the next
  /// non-erased sentence. Crosses page boundaries forward, mirror
  /// of `FocusPrevious`. A no-op at the end of the document.
  /// Initialises focus on first press.
  FocusNext

  /// Reader pressed `k` — move the keyboard cursor to the first
  /// non-erased sentence of the previous paragraph on the current
  /// page. Fully-erased paragraphs are skipped. Stops at the page
  /// boundary: a no-op when the cursor is already on the first
  /// paragraph of the current page. Initialises focus on first press.
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

  /// Reader selected a reading mode in the settings panel.
  /// Switching to `Manual` stops any running fade engine and
  /// clears its timer; switching to `RealTime` leaves the engine
  /// in `Stopped` state (the reader must press Space/tap to
  /// start). The bitsets are not converted — both modes share
  /// the same `Model` and any prior erasures persist.
  SetMode(Mode)

  /// Reader pressed Space (desktop) or tapped the reader page
  /// (mobile). In `Manual` mode this is forwarded to
  /// `EraseFocused` so vim-keys behaviour is unchanged. In
  /// `RealTime` mode the reducer routes it to start/pause/resume
  /// of the fade engine based on the current `engine_state`.
  SpacePressed

  /// Start the fade engine. Finds the first non-erased word on
  /// the current page, sets `next_word_index` to its global
  /// index, transitions `engine_state` to `Running`, and
  /// schedules the first AdvanceWord tick after one word
  /// interval. No-op when there is no eligible word on the
  /// current page or when the engine is already `Running`.
  StartFade

  /// Pause the fade engine. Clears the in-flight word timer via
  /// FFI and transitions `engine_state` to `Paused`. Keeps
  /// `next_word_index` intact so `ResumeFade` continues from the
  /// same position. No-op when the engine is not `Running`.
  PauseFade

  /// Resume a paused fade engine. Re-schedules the AdvanceWord
  /// timer at the current WPM interval and transitions
  /// `engine_state` to `Running`. No-op when the engine is not
  /// `Paused`.
  ResumeFade

  /// Stop the fade engine fully. Clears any in-flight timer,
  /// transitions to `Stopped`, and resets `next_word_index` to
  /// `None`. Used on mode-switch out of `RealTime` and on
  /// document exhaustion (no more eligible words to fade).
  StopFade

  /// Timer callback fired by the FFI word-timer slot. Marks
  /// `next_word_index` as faded (inserts into `erased_words`),
  /// finds the next eligible word, and either schedules the next
  /// tick or advances the page / stops the engine. Guarded
  /// against stale ticks — when `engine_state != Running` the
  /// arm is a no-op so a callback that survives a `PauseFade`
  /// race (none should, given the synchronous FFI slot, but the
  /// guard is the belt to the FFI's braces) cannot mutate state.
  AdvanceWord

  /// Reader dragged the WPM slider. Clamps the incoming value
  /// into `[min_wpm, max_wpm]` and writes it to the model. Does
  /// not re-schedule the in-flight timer — the next AdvanceWord
  /// already reads the live `model.wpm` when it computes its
  /// follow-up delay, so a WPM change takes effect on the next
  /// tick without needing a restart.
  SetWpm(Int)

  /// Reader dragged the paragraph-delay slider. Clamps into
  /// `[min_paragraph_delay_ms, max_paragraph_delay_ms]`. Same
  /// take-effect-on-next-tick semantics as `SetWpm`.
  SetParagraphDelay(Int)

  /// Reader dragged the page-delay slider. Clamps into
  /// `[min_page_delay_ms, max_page_delay_ms]`. Same
  /// take-effect-on-next-tick semantics as `SetWpm`.
  SetPageDelay(Int)
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
      mode: Manual,
      wpm: default_wpm,
      engine_state: Stopped,
      next_word_index: None,
      erased_words: set.new(),
      paragraph_delay_ms: default_paragraph_delay_ms,
      page_delay_ms: default_page_delay_ms,
      line_boxes: [],
      active_line: None,
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
///    - `SwipeRight` — `Undo` the most recent erase. A no-op when
///      the undo stack is empty (no backward page navigation).
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
        line_boxes: [],
        active_line: None,
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
      // Re-anchor `focused_sentence` if pagination shifted it off the
      // visible page. Without this, a viewport change can leave the
      // vim cursor on a sentence whose `page_index` differs from
      // `clamped`; the next vim keypress would then call `change_page`
      // with that off-screen target, bypassing the forward-only guard
      // in `go_to_page` and dragging `current_page` backward — the
      // exact regression this PR exists to close. Re-anchoring to the
      // first non-erased sentence on `clamped` keeps the cursor on
      // the page the reader is actually looking at.
      let focused = case model.focused_sentence {
        None -> None
        Some(sentence_index) -> {
          let locations = navigation.locate_sentences(pages)
          let on_current_page =
            locations
            |> list.any(fn(loc) {
              loc.sentence_global_index == sentence_index
              && loc.page_index == clamped
            })
          case on_current_page {
            True -> Some(sentence_index)
            False ->
              navigation.first_on_page(locations, clamped, model.erased)
              |> option.map(fn(loc) { loc.sentence_global_index })
          }
        }
      }
      #(
        Model(
          ..model,
          pages: pages,
          current_page: clamped,
          focused_sentence: focused,
          // Re-pagination invalidates the cached line geometry: the
          // new `pages` may wrap differently and the previous
          // `line_boxes` no longer describe what the view is about
          // to render. Clear both fields synchronously in the same
          // model update that schedules the re-measure so the view
          // never paints the new page against stale overlay
          // coordinates — without this, the 250ms `top` transition
          // glides the overlay from the old position to the new one
          // once `LinesMeasured` lands, which reads as drift on a
          // settings-slider drag where each tick re-paginates.
          line_boxes: [],
          active_line: None,
        ),
        // Pagination ran — chain a line measurement so the active-line
        // overlay re-anchors to the post-repagination geometry. The
        // chain is necessary because line tops depend on the rendered
        // page, which only exists after the view re-renders with the
        // new `pages` value; `effect.after_paint` waits for that paint
        // before reading `getBoundingClientRect()`.
        measure_lines_after_paint(),
      )
    }

    LinesMeasured(boxes) -> {
      let new_model = Model(..model, line_boxes: boxes)
      #(
        Model(..new_model, active_line: resolve_active_line(new_model)),
        effect.none(),
      )
    }

    NextPage -> {
      let updated = go_to_page(model, model.current_page + 1)
      case updated.current_page == model.current_page {
        // A no-op page turn (already on the last page) doesn't change
        // the rendered DOM, so re-measuring would only churn the
        // overlay position without effect. Skipping the measurement
        // here also keeps the no-page-change test pin in place.
        True -> #(updated, effect.none())
        // A real page turn invalidates the cached line geometry. Clear
        // `line_boxes` and `active_line` synchronously in the same
        // model update that schedules the re-measure — otherwise the
        // view paints the new page with the old overlay coordinates
        // and the 250ms `top` CSS transition glides the band into
        // place once `LinesMeasured` lands. The cleared state mirrors
        // the engine's own cross-page tick in `advance_to_next_page_loop`.
        False -> #(
          Model(..updated, line_boxes: [], active_line: None),
          measure_lines_after_paint(),
        )
      }
    }

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

    TouchEnd(x, y) -> apply_touch_end(model, x, y)

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

    SetMode(mode) -> apply_set_mode(model, mode)

    SpacePressed -> apply_space_pressed(model)

    StartFade -> apply_start_fade(model)

    PauseFade -> apply_pause_fade(model)

    ResumeFade -> apply_resume_fade(model)

    StopFade -> apply_stop_fade(model)

    AdvanceWord -> apply_advance_word(model)

    SetWpm(value) -> #(
      Model(..model, wpm: clamp_int(value, min_wpm, max_wpm)),
      effect.none(),
    )

    SetParagraphDelay(value) -> #(
      Model(
        ..model,
        paragraph_delay_ms: clamp_int(
          value,
          min_paragraph_delay_ms,
          max_paragraph_delay_ms,
        ),
      ),
      effect.none(),
    )

    SetPageDelay(value) -> #(
      Model(
        ..model,
        page_delay_ms: clamp_int(value, min_page_delay_ms, max_page_delay_ms),
      ),
      effect.none(),
    )
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

// ---------------------------------------------------------------------------
// update — fade engine reducer arms
// ---------------------------------------------------------------------------
//
// The real-time fade engine is a three-state machine: Stopped, Running,
// Paused. Transitions:
//
//   Stopped --StartFade-->         Running  (find first eligible word,
//                                            schedule first tick)
//   Running --AdvanceWord-->       Running  (fade current, schedule next)
//                          \
//                           \-->   Stopped  (no more words; engine done)
//   Running --PauseFade-->         Paused   (clear timer, keep next index)
//   Paused  --ResumeFade-->        Running  (schedule next tick at WPM)
//   *       --StopFade-->          Stopped  (clear timer, clear next index)
//   *       --SetMode(Manual)-->   Stopped  (mode switch always halts)
//
// The FFI's single-slot word timer is the runtime authority on
// "is there a timer in flight": every transition that should kill
// the timer calls `ffi.clear_word_timer`, every transition that
// schedules one calls `ffi.start_word_timer`. `AdvanceWord` also
// guards on `engine_state == Running` so a stale tick that
// somehow survives `clear_word_timer` (it shouldn't — the FFI is
// synchronous) cannot mutate state behind a paused engine.

/// Reading-order context for a single word inside the current
/// page. Carries the word's global index alongside its enclosing
/// paragraph and sentence indices so the engine can detect
/// paragraph boundaries (for the inter-paragraph delay) and skip
/// words whose parent sentence has already been manually erased.
type WordContext {
  WordContext(
    word_global_index: Int,
    paragraph_global_index: Int,
    sentence_global_index: Int,
  )
}

fn apply_set_mode(model: Model, mode: Mode) -> #(Model, Effect(Msg)) {
  case mode {
    Manual -> {
      // Leaving RealTime: kill any in-flight timer and reset the
      // engine to a fully-dormant state. The bitsets persist —
      // fade-engine erasures remain visible-as-gone in Manual mode.
      // `active_line` clears alongside the engine: the overlay is a
      // RealTime-only affordance and would otherwise linger as a
      // ghost rectangle on the page after the toggle flipped.
      let cleared =
        Model(
          ..model,
          mode: Manual,
          engine_state: Stopped,
          next_word_index: None,
          active_line: None,
        )
      #(cleared, effect.from(fn(_dispatch) { ffi.clear_word_timer() }))
    }
    RealTime -> #(Model(..model, mode: RealTime), effect.none())
  }
}

fn apply_space_pressed(model: Model) -> #(Model, Effect(Msg)) {
  case model.mode {
    Manual -> #(apply_erase_focused(model), effect.none())
    RealTime ->
      case model.engine_state {
        Running -> apply_pause_fade(model)
        Paused -> apply_resume_fade(model)
        Stopped -> apply_start_fade(model)
      }
  }
}

fn apply_start_fade(model: Model) -> #(Model, Effect(Msg)) {
  case first_eligible_word_on_current_page(model) {
    None -> #(model, effect.none())
    Some(ctx) -> {
      let with_next =
        Model(
          ..model,
          engine_state: Running,
          next_word_index: Some(ctx.word_global_index),
        )
      // Resolve the active line against the in-memory boxes from the
      // last layout pass. The overlay therefore renders correctly on
      // the first frame after Start, even when no `LinesMeasured`
      // tick has fired yet for this run (the boxes are still valid
      // because the page hasn't reflowed).
      let started =
        Model(..with_next, active_line: resolve_active_line(with_next))
      #(started, schedule_advance_word(word_interval_ms(model.wpm)))
    }
  }
}

fn apply_pause_fade(model: Model) -> #(Model, Effect(Msg)) {
  case model.engine_state {
    Running -> #(
      Model(..model, engine_state: Paused),
      effect.from(fn(_dispatch) { ffi.clear_word_timer() }),
    )
    _ -> #(model, effect.none())
  }
}

fn apply_resume_fade(model: Model) -> #(Model, Effect(Msg)) {
  case model.engine_state {
    Paused -> #(
      Model(..model, engine_state: Running),
      schedule_advance_word(word_interval_ms(model.wpm)),
    )
    _ -> #(model, effect.none())
  }
}

fn apply_stop_fade(model: Model) -> #(Model, Effect(Msg)) {
  #(
    // `active_line: None` so the overlay disappears when the engine
    // halts — there's no active word for it to track. Keeping the
    // last position visible across a Stop would mislead the reader
    // about where the engine is (which is "nowhere").
    Model(
      ..model,
      engine_state: Stopped,
      next_word_index: None,
      active_line: None,
    ),
    effect.from(fn(_dispatch) { ffi.clear_word_timer() }),
  )
}

/// Process one tick of the fade engine. Guarded against stale
/// ticks: when the engine is not `Running`, the tick is a no-op.
/// Otherwise, marks the current `next_word_index` as faded,
/// resolves the next target (next eligible word on the current
/// page, or the first eligible word on the next page when this
/// page is exhausted), and schedules the next tick at the
/// appropriate delay. When no eligible word remains anywhere
/// after the current page, the engine stops.
///
/// `Running, None` is treated as an invariant violation rather
/// than a silent no-op: the `Model` header at lines 99-103
/// guarantees that `Running` carries `Some(_)` in
/// `next_word_index`, and any path that produces the inverse is
/// a reducer bug that should fail loudly at its source rather
/// than propagate as a phantom-tick no-op.
fn apply_advance_word(model: Model) -> #(Model, Effect(Msg)) {
  case model.engine_state, model.next_word_index {
    Running, Some(current_idx) -> advance_with_current(model, current_idx)
    Running, None ->
      panic as "apply_advance_word: Running engine must carry Some(next_word_index)"
    Stopped, _ -> #(model, effect.none())
    Paused, _ -> #(model, effect.none())
  }
}

fn advance_with_current(
  model: Model,
  current_idx: Int,
) -> #(Model, Effect(Msg)) {
  let faded =
    Model(..model, erased_words: set.insert(model.erased_words, current_idx))
  case next_eligible_after(faded, current_idx) {
    Some(#(next_ctx, crosses_paragraph)) -> {
      let delay = case crosses_paragraph {
        True -> word_interval_ms(faded.wpm) + faded.paragraph_delay_ms
        False -> word_interval_ms(faded.wpm)
      }
      let with_next =
        Model(..faded, next_word_index: Some(next_ctx.word_global_index))
      // The line boxes don't shift on a within-page tick (the page
      // hasn't reflowed), so the existing `line_boxes` is still
      // valid — re-resolving the active line against them moves
      // the overlay between rows as the engine crosses lines.
      let scheduled =
        Model(..with_next, active_line: resolve_active_line(with_next))
      #(scheduled, schedule_advance_word(delay))
    }
    None -> advance_to_next_page(faded)
  }
}

/// Move the engine onto the next page when the current page is
/// exhausted. Walks forward through the remaining pages until one
/// with at least one eligible word is found; stops the engine when
/// no such page exists. Uses `go_to_page` for the page change so
/// the existing forward-only navigation invariant is preserved
/// and the focused-sentence cursor (if any) follows along.
fn advance_to_next_page(model: Model) -> #(Model, Effect(Msg)) {
  let total = list.length(model.pages)
  advance_to_next_page_loop(model, model.current_page + 1, total)
}

fn advance_to_next_page_loop(
  model: Model,
  candidate: Int,
  total: Int,
) -> #(Model, Effect(Msg)) {
  case candidate >= total {
    True -> apply_stop_fade(model)
    False -> {
      let on_page = go_to_page(model, candidate)
      case first_eligible_word_on_current_page(on_page) {
        Some(ctx) -> {
          // Cross-page tick: the page reflow means the existing
          // `line_boxes` no longer describe the visible page.
          // Clear them and clear `active_line` so the overlay
          // disappears for the one frame between the page render
          // and the next `LinesMeasured`. `measure_lines_after_paint`
          // is batched into the effect chain so the overlay
          // re-emerges on the new line as soon as the fresh
          // geometry lands.
          let scheduled =
            Model(
              ..on_page,
              next_word_index: Some(ctx.word_global_index),
              line_boxes: [],
              active_line: None,
            )
          #(
            scheduled,
            effect.batch([
              schedule_advance_word(on_page.page_delay_ms),
              measure_lines_after_paint(),
            ]),
          )
        }
        None -> advance_to_next_page_loop(on_page, candidate + 1, total)
      }
    }
  }
}

/// Resolve the fade engine's first target on the current page.
/// "Eligible" means the word is not in `erased_words` and its
/// parent sentence is not in `erased`. Returns `None` when every
/// word on the current page is hidden — the engine treats this
/// as an empty page and either does not start (from
/// `apply_start_fade`) or advances past it (from
/// `advance_to_next_page`).
fn first_eligible_word_on_current_page(model: Model) -> Option(WordContext) {
  case pagination.nth(model.pages, model.current_page) {
    None -> None
    Some(page) ->
      page
      |> page_word_contexts
      |> list.find(fn(ctx) {
        is_word_visible(ctx, model.erased_words, model.erased)
      })
      |> option.from_result
  }
}

/// Find the next eligible word strictly after `current_idx` in
/// document order on the current page. Returns the target context
/// alongside a `Bool` that's `True` when the next word lives in a
/// different paragraph than the just-faded word — the caller uses
/// that flag to add the inter-paragraph delay to the schedule.
///
/// Implemented as a single forward scan over `page_word_contexts`:
/// the previous two-pass form (one `list.find` to resolve
/// `current_paragraph`, then a `drop_through_word` + second
/// `list.find` to skip past `current_idx`) walked the list twice
/// per tick — ~400 list-element visits at 200-word pages and
/// 200 WPM. The fused scan captures the current word's paragraph
/// when it passes through it and continues looking for the next
/// eligible word in the same traversal.
fn next_eligible_after(
  model: Model,
  current_idx: Int,
) -> Option(#(WordContext, Bool)) {
  case pagination.nth(model.pages, model.current_page) {
    None -> None
    Some(page) ->
      scan_for_next_eligible(
        page_word_contexts(page),
        current_idx,
        None,
        model.erased_words,
        model.erased,
      )
  }
}

/// Tail-recursive helper for `next_eligible_after`. `current_paragraph`
/// carries the just-faded word's paragraph index once the scan has
/// passed it, and stays `None` until then. The arm split is therefore
/// "before / at / after the current word":
///
/// * `None` + non-match → keep walking, current word not yet seen.
/// * `None` + match → capture this element's paragraph and skip it.
/// * `Some(_)` + visible → return as the next eligible target along
///   with the crosses-paragraph flag.
/// * `Some(_)` + erased → keep walking.
///
/// If the scan exhausts the list without ever finding `current_idx`,
/// the result is `None` — the caller treats that as a "page
/// exhausted" signal and walks forward to the next page.
fn scan_for_next_eligible(
  contexts: List(WordContext),
  current_idx: Int,
  current_paragraph: Option(Int),
  erased_words: Set(Int),
  erased_sentences: Set(Int),
) -> Option(#(WordContext, Bool)) {
  case contexts, current_paragraph {
    [], _ -> None
    [ctx, ..rest], None ->
      case ctx.word_global_index == current_idx {
        True ->
          scan_for_next_eligible(
            rest,
            current_idx,
            Some(ctx.paragraph_global_index),
            erased_words,
            erased_sentences,
          )
        False ->
          scan_for_next_eligible(
            rest,
            current_idx,
            None,
            erased_words,
            erased_sentences,
          )
      }
    [ctx, ..rest], Some(captured_paragraph) ->
      case is_word_visible(ctx, erased_words, erased_sentences) {
        True -> Some(#(ctx, ctx.paragraph_global_index != captured_paragraph))
        False ->
          scan_for_next_eligible(
            rest,
            current_idx,
            Some(captured_paragraph),
            erased_words,
            erased_sentences,
          )
      }
  }
}

/// Flatten one page into reading-order word contexts. Iteration
/// is `page.paragraphs[].paragraph.sentences[].words[]` —
/// document order matches the Word.global_index sequence the
/// segmenter assigned at build time.
fn page_word_contexts(page: Page) -> List(WordContext) {
  page.paragraphs
  |> list.flat_map(fn(page_paragraph) {
    page_paragraph.paragraph.sentences
    |> list.flat_map(fn(sentence) {
      sentence.words
      |> list.map(fn(word) {
        WordContext(
          word_global_index: word.global_index,
          paragraph_global_index: page_paragraph.global_index,
          sentence_global_index: sentence.global_index,
        )
      })
    })
  })
}

/// A word is visible when neither its own bitset entry nor its
/// parent sentence's entry is set. Shared between the engine's
/// eligibility search and the view's render path so the two
/// stay in lock-step.
fn is_word_visible(
  ctx: WordContext,
  erased_words: Set(Int),
  erased_sentences: Set(Int),
) -> Bool {
  !set.contains(erased_words, ctx.word_global_index)
  && !set.contains(erased_sentences, ctx.sentence_global_index)
}

/// Words-per-minute → per-word delay in milliseconds. Integer
/// division — the residual fractional millisecond is sub-frame
/// at every realistic WPM and would not be observable in the
/// rendered fade.
fn word_interval_ms(wpm: Int) -> Int {
  ms_per_minute / wpm
}

/// Schedule the next AdvanceWord dispatch after `delay_ms`. The
/// FFI's single-slot timer clears any prior in-flight handle
/// synchronously, so this is safe to call from any
/// engine-transition arm without first calling
/// `clear_word_timer` defensively.
fn schedule_advance_word(delay_ms: Int) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.start_word_timer(delay_ms, fn() { dispatch(AdvanceWord) })
  })
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

/// Resolve a `TouchEnd` into the next model state. Clears
/// `touch_start` unconditionally, then classifies the gesture
/// (`Tap` / `SwipeLeft` / `SwipeRight`) and routes the swipe to a
/// page navigation or an undo. A `Tap` in `Manual` mode is a
/// no-op — sentence erasure flows through the synthesised `click`
/// event on the `.sentence` span. A `Tap` in `RealTime` mode is
/// routed through `apply_space_pressed`, which toggles the fade
/// engine's start/pause/resume state. Returns an `Effect` so the
/// RealTime branch can schedule or cancel the FFI word timer.
fn apply_touch_end(model: Model, x: Float, y: Float) -> #(Model, Effect(Msg)) {
  let cleared = Model(..model, touch_start: None)
  case model.touch_start {
    None -> #(cleared, effect.none())
    Some(#(start_x, start_y)) ->
      case gestures.classify(start_x, start_y, x, y) {
        gestures.Tap ->
          case cleared.mode {
            Manual -> #(cleared, effect.none())
            RealTime -> apply_space_pressed(cleared)
          }
        gestures.SwipeLeft -> #(
          go_to_page(cleared, cleared.current_page + 1),
          effect.none(),
        )
        gestures.SwipeRight -> #(apply_undo(cleared), effect.none())
      }
  }
}

/// Pop the most recent erase off `undo_stack` and remove its index
/// from `erased`. Returns the model unchanged when the stack is
/// empty. Shared between the `Undo` reducer arm and the SwipeRight
/// branch of `apply_touch_end` — both consume the head of the stack
/// in identical ways, and a copy-and-paste here would let the two
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
/// `pages` range. Rejects any `candidate` less than `current_page`
/// — backward page navigation is disabled; only forward movement is
/// permitted. Clears `undo_stack` only when `clamped` differs from
/// `current_page` — a real page change commits every erase that has
/// not yet been undone, but a clamp-to-self (ArrowRight on the last
/// page) must leave the undo stack intact so a reader's stray reflex
/// tap does not silently destroy undoable erases.
///
/// Used by `NextPage`/swipes — input modes where the reader pages
/// forward through the book. When `focused_sentence` is `Some(_)`
/// (i.e. the reader is in vim mode) and the page actually changes,
/// the cursor resets to the first non-erased sentence on the new
/// page. Vim-key navigation bypasses this helper through
/// `change_page`/`move_focus` because the navigation module decides
/// exactly where the cursor should land.
fn go_to_page(model: Model, candidate: Int) -> Model {
  case candidate < model.current_page {
    True -> model
    False -> {
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
  }
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

/// Schedule an `after_paint` effect that walks the visible page's
/// `[data-global-index]` word spans and dispatches `LinesMeasured`
/// with one `LineBox` per visual line. The FFI returns four-tuples
/// (top, height, first_gi, last_gi); this helper converts each to a
/// `LineBox` record before dispatching so the rest of the reducer
/// surface speaks in the domain type rather than raw geometry.
///
/// Read against `#vi-page-content` (the visible page container) — not
/// the off-screen measurement mirror — because the visible page is
/// what the overlay anchors into. The measurement mirror has the same
/// width and word-wrap behaviour but lives at a different y-offset, so
/// reading its line tops would point the overlay at the wrong rows.
fn measure_lines_after_paint() -> Effect(Msg) {
  effect.after_paint(fn(dispatch, _root) {
    let tuples = ffi.measure_word_lines("#" <> page_content_id)
    let boxes = list.map(tuples, line_box_from_tuple)
    dispatch(LinesMeasured(boxes: boxes))
  })
}

/// Convert one FFI four-tuple into a `LineBox`. Pulled out so the
/// measurement effect reads as one `list.map` rather than carrying
/// an inline `fn(tuple) { ... }` literal.
fn line_box_from_tuple(tuple: #(Float, Float, Int, Int)) -> LineBox {
  let #(top, height, first_gi, last_gi) = tuple
  LineBox(
    top: top,
    height: height,
    first_word_gi: first_gi,
    last_word_gi: last_gi,
  )
}

/// Resolve the line index whose word range contains `word_global_index`.
/// Returns `None` when the boxes list is empty (mid-measurement) or
/// when the word index falls outside every measured range (a manual
/// erasure or page turn between measurement and lookup). The lookup
/// is `O(lines)` because the line count per page is small — typically
/// 20-40 — and the alternative (binary search) would carry more
/// complexity than it saves at these magnitudes.
///
/// Implemented as a single-pass tail-recursive scan with early exit
/// on first match. The previous `index_map |> find |> result.map`
/// pipeline materialised an intermediate `List(#(Int, LineBox))`
/// before searching it — the same logic in one pass with no
/// intermediate allocation.
fn line_index_for_word(
  boxes: List(LineBox),
  word_global_index: Int,
) -> Option(Int) {
  scan_lines_for_word(boxes, word_global_index, 0)
}

fn scan_lines_for_word(
  boxes: List(LineBox),
  word_global_index: Int,
  index: Int,
) -> Option(Int) {
  case boxes {
    [] -> None
    [box, ..rest] ->
      case
        box.first_word_gi <= word_global_index
        && word_global_index <= box.last_word_gi
      {
        True -> Some(index)
        False -> scan_lines_for_word(rest, word_global_index, index + 1)
      }
  }
}

/// Resolve the active line for the current `next_word_index` against
/// the current `line_boxes`. Returns `None` when the engine has no
/// target or no boxes are available; otherwise returns the index of
/// the line that contains the target word. Pulled out so every
/// reducer arm that touches `next_word_index` or `line_boxes` reads
/// the same lookup and the two fields stay in lock-step.
fn resolve_active_line(model: Model) -> Option(Int) {
  case model.next_word_index, model.line_boxes {
    None, _ -> None
    _, [] -> None
    Some(idx), boxes -> line_index_for_word(boxes, idx)
  }
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

/// Build the full reading surface: sticky header, reading-progress
/// bar, visible page, mode-aware bottom bar, and off-screen
/// measurement container.
///
/// The chrome rows (`view_reader_header`, `view_progress_bar`,
/// `view_bottom_bar`) flank the central `.reader-page` so the
/// reading area is the flex-grow child between two `flex: 0 0 auto`
/// frames. The header carries the back glyph, current book title,
/// and settings gear; the bottom bar swaps shape with `model.mode`
/// — Manual gets undo / page indicator / turn-page, RealTime gets
/// WPM readout / play-pause / spacer.
///
/// The `#vi-measurement` container receives all paragraphs from the
/// whole book — not just the current page. This lets
/// `measure_after_paint` read every paragraph height in a single DOM
/// pass after `TextLoaded` or `ViewportResized`, rather than
/// re-measuring on every page turn.
///
/// Touch handlers are placed on `.reader-page` rather than the outer
/// `.reader-text` so neither the chrome rows nor the off-screen
/// measurement container can intercept page swipes. The measurement
/// container is `pointer-events: none` (see `.reader-measurement` in
/// `styles.css`) so its descendants cannot receive any touch or
/// click events.
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
        model.erased_words,
        model.mode,
      )
    None -> view_preparing()
  }

  // The active-line overlay rides as a sibling of `visible` inside
  // `#vi-page-content` so it inherits the same containing block.
  // CSS makes `.reader-page-content` `position: relative`, which
  // anchors the overlay's absolute top/height to the rendered
  // page area — exactly the coordinate space the FFI normalises
  // each `LineBox.top` into.
  let active_line_overlay = view_active_line_overlay(model)

  html.div([attribute.class("reader-text")], [
    view_reader_header(model),
    view_progress_bar(model),
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
          [visible, active_line_overlay],
        ),
      ],
    ),
    view_bottom_bar(model, total),
    view_measurement_container(model.flat_paragraphs, erased_opacity),
  ])
}

/// Sticky top chrome row. Three slots: back glyph (left), book title
/// (centre, ellipsised), settings gear (right). The back button
/// dispatches `SetMode(Manual)` — in RealTime mode this stops the
/// fade engine and returns to the tap-to-erase reader, in Manual
/// mode it is an idempotent no-op (the model is already in Manual,
/// and `apply_set_mode(model, Manual)` is safe to call against
/// a stopped engine). Act 4 will rewire the back button to library
/// navigation once a library view exists; until then "back" reads
/// as "exit the active reading mode".
///
/// The book title is hardcoded to the bundled sample's chapter and
/// author for now; the future server-payload path will surface the
/// real title onto the model.
fn view_reader_header(_model: Model) -> Element(Msg) {
  html.div([attribute.class("reader-header")], [
    html.div([attribute.class("reader-header-inner")], [
      html.button(
        [
          attribute.class("btn-icon"),
          attribute.aria_label("Back to library"),
          attribute.type_("button"),
          event.on_click(SetMode(Manual)),
        ],
        [html.text("←")],
      ),
      html.div([attribute.class("reader-title")], [
        html.text("Pride and Prejudice · Austen"),
      ]),
      html.button(
        [
          attribute.class("btn-icon"),
          attribute.aria_label("Open settings"),
          attribute.type_("button"),
          event.on_click(ToggleSettings),
        ],
        // Unicode gear glyph keeps the asset surface zero. A later
        // quest can swap this for an inline SVG if iconography
        // becomes a theme concern.
        [html.text("⚙")],
      ),
    ]),
  ])
}

/// Thin reading-progress bar between the header and the reading
/// area. The fill width is driven inline from the model:
///
/// * Manual mode — fraction of sentences erased over the whole text.
/// * RealTime mode — fraction of words faded over the whole text.
///
/// Both denominators are computed from `model.text` rather than
/// the current page's slice, so the bar reads as "progress through
/// the book" rather than "progress through this page". When the
/// model has no text yet, the fill is 0% — the bar renders as an
/// empty track until `TextLoaded` lands.
fn view_progress_bar(model: Model) -> Element(Msg) {
  let percent = progress_percentage(model)
  let width_value = float.to_string(percent) <> "%"
  html.div([attribute.class("reader-progress-track")], [
    html.div(
      [
        attribute.class("reader-progress-fill"),
        attribute.style("width", width_value),
        attribute.attribute("aria-hidden", "true"),
      ],
      [],
    ),
  ])
}

fn progress_percentage(model: Model) -> Float {
  let #(numerator, denominator) = case model.mode {
    Manual -> #(set.size(model.erased), total_sentence_count(model.text))
    RealTime -> #(set.size(model.erased_words), total_word_count(model.text))
  }
  case denominator {
    0 -> 0.0
    _ -> int.to_float(numerator) /. int.to_float(denominator) *. 100.0
  }
}

/// Total sentence count across every chapter and paragraph in the
/// loaded text. Used as the denominator of the manual-mode progress
/// fraction. Returns `0` when `text` is `None` so the caller's
/// division falls through to a `0%` fill instead of a divide-by-zero
/// crash.
fn total_sentence_count(text: Option(SegmentedText)) -> Int {
  case text {
    None -> 0
    Some(t) ->
      t.chapters
      |> list.flat_map(fn(ch) { ch.paragraphs })
      |> list.flat_map(fn(p) { p.sentences })
      |> list.length
  }
}

/// Total word count across every sentence in the loaded text. Used
/// as the denominator of the real-time progress fraction. Mirrors
/// `total_sentence_count`'s shape: `None` → `0`.
fn total_word_count(text: Option(SegmentedText)) -> Int {
  case text {
    None -> 0
    Some(t) ->
      t.chapters
      |> list.flat_map(fn(ch) { ch.paragraphs })
      |> list.flat_map(fn(p) { p.sentences })
      |> list.flat_map(fn(s) { s.words })
      |> list.length
  }
}

/// Render the active-line overlay. The overlay is only visible while
/// the engine has a live target on a measured line:
///
/// * `mode == RealTime` — the overlay is a fade-engine affordance;
///   Manual-mode readers see no overlay.
/// * `engine_state` is `Running` or `Paused` — Stopped means no
///   target. Paused keeps the overlay so the reader can see where
///   they stopped.
/// * `active_line` is `Some(_)` — there is a resolved line.
/// * The matching `LineBox` exists in `model.line_boxes`.
///
/// Returns `element.none()` when any guard fails, so the overlay is
/// fully absent from the DOM rather than rendering a zero-sized
/// rectangle. Skipping the element entirely also keeps the
/// rendered-HTML tests for Manual-mode views stable — no overlay
/// markup ever appears in the no-engine baseline.
fn view_active_line_overlay(model: Model) -> Element(Msg) {
  let should_render = case model.mode, model.engine_state {
    RealTime, Running -> True
    RealTime, Paused -> True
    _, _ -> False
  }
  case should_render {
    False -> element.none()
    True ->
      case model.active_line {
        None -> element.none()
        Some(index) ->
          case nth_line_box(model.line_boxes, index) {
            None -> element.none()
            Some(box) -> render_active_line_overlay(box)
          }
      }
  }
}

/// `List(LineBox)` analogue of `pagination.nth`. The pagination
/// helper is monomorphic in `List(Page)`, and the overlay's lookup
/// against `line_boxes` is the only second caller in the program —
/// generalising the pagination function would force every other
/// caller to thread the type, so a local helper is the smaller
/// change.
fn nth_line_box(boxes: List(LineBox), index: Int) -> Option(LineBox) {
  case index < 0 {
    True -> None
    False ->
      case list.drop(boxes, index) {
        [box, ..] -> Some(box)
        [] -> None
      }
  }
}

/// Build the overlay `<div>` for a resolved `LineBox`. The element
/// is absolutely positioned by inline `top` / `height` styles so a
/// single `transition` on the CSS rule glides the overlay between
/// lines when `active_line` changes; the rendered HTML doesn't
/// re-mount, it just receives new style values.
///
/// `float.to_string` is used unmodified — no rounding is applied.
/// Render stability across re-measurements relies on
/// `getBoundingClientRect` being deterministic for an unchanged
/// layout (the W3C CSSOM View spec requires it), so a re-measure
/// against the same DOM produces byte-identical inline styles and
/// Lustre's vdom diff sees no change. When the layout *does*
/// change (page turn, re-pagination, settings drag), the new
/// coordinates differ enough that any decimal jitter is dwarfed by
/// the actual position delta. If a future genuine sub-pixel-jitter
/// source surfaces, switch to `float.to_precision(_, 1)` here and
/// add a test that pins the rounded format — do not rely on the
/// rounding implicitly.
fn render_active_line_overlay(box: LineBox) -> Element(Msg) {
  let top_value = float.to_string(box.top) <> "px"
  let height_value = float.to_string(box.height) <> "px"
  html.div(
    [
      attribute.class("reader-active-line"),
      attribute.attribute("aria-hidden", "true"),
      attribute.style("top", top_value),
      attribute.style("height", height_value),
    ],
    [],
  )
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
  erased_words: Set(Int),
  mode: Mode,
) -> Element(Msg) {
  html.div(
    [
      attribute.class("page"),
      attribute.attribute("data-page-index", int.to_string(page.index)),
    ],
    list.map(page.paragraphs, fn(p) {
      view_page_paragraph(
        p,
        erased,
        focused,
        interactive,
        erased_opacity,
        erased_words,
        mode,
      )
    }),
  )
}

/// Bottom bar — mode-aware. Manual mode renders the undo / page-
/// indicator / turn-page trio so the reader can step through the
/// book with thumb-reachable controls; RealTime mode renders the
/// WPM readout, the play / pause button, and a balancing spacer so
/// the play button sits centred between two equal-width siblings.
///
/// The outer `.reader-bottom-bar` carries the safe-area-bottom
/// padding and the warm chrome bg so both branches inherit the
/// same frame; only the inner row changes shape with `model.mode`.
fn view_bottom_bar(model: Model, total: Int) -> Element(Msg) {
  let inner = case model.mode {
    Manual -> view_bottom_manual(model, total)
    RealTime -> view_bottom_realtime(model)
  }
  html.div([attribute.class("reader-bottom-bar")], [inner])
}

/// Manual-mode bottom bar inner row.
///
/// Layout: `[↩ Undo]   Page N of M   [Turn Page →]`.
///
/// * Undo button — disabled when the undo stack is empty. Dispatches
///   `Undo`.
/// * Page label — same `Page N of M` text the old `view_control_bar`
///   carried; renders an empty string when no pages are available yet,
///   so the bar's frame stays the same height before pagination has
///   produced its first result.
/// * Turn-page button — primary (inverted) styling so the eye is
///   drawn to it. Reads "✓ Finished" on the last page and is
///   disabled there (the reader has nowhere to advance to). Dispatches
///   `NextPage`.
fn view_bottom_manual(model: Model, total: Int) -> Element(Msg) {
  let on_last_page = total > 0 && model.current_page >= total - 1
  let next_label = case on_last_page {
    True -> "✓ Finished"
    False -> "Turn Page →"
  }
  let next_disabled = total == 0 || on_last_page
  let page_text = case total {
    0 -> ""
    _ ->
      "Page "
      <> int.to_string(model.current_page + 1)
      <> " of "
      <> int.to_string(total)
  }
  let undo_disabled = list.is_empty(model.undo_stack)

  html.div([attribute.class("reader-bottom-manual")], [
    html.button(
      [
        attribute.class("btn-bar"),
        attribute.type_("button"),
        attribute.disabled(undo_disabled),
        attribute.aria_label("Undo last erase"),
        event.on_click(Undo),
      ],
      [html.text("↩ Undo")],
    ),
    html.div([attribute.class("reader-page-label")], [html.text(page_text)]),
    html.button(
      [
        attribute.class("btn-bar primary"),
        attribute.type_("button"),
        attribute.disabled(next_disabled),
        attribute.aria_label("Turn page"),
        event.on_click(NextPage),
      ],
      [html.text(next_label)],
    ),
  ])
}

/// Real-time mode bottom bar inner row.
///
/// Layout: `WPM readout   [▶ / ⏸]   (spacer)`.
///
/// The play button cycles through the engine's three states:
///
/// * `Stopped` — render `▶` with the `.paused` accent background;
///   click dispatches `StartFade`.
/// * `Paused`  — render `▶` with the `.paused` accent background;
///   click dispatches `ResumeFade`.
/// * `Running` — render `⏸` with the default inverted background;
///   click dispatches `PauseFade`.
///
/// `event.stop_propagation` keeps the click from bubbling up — the
/// page-level tap handler routes taps in RealTime mode to
/// pause/resume too, so without the guard a tap that landed on the
/// button would fire the engine transition twice (once via the
/// button click, once via the bubbled-up touch handler).
fn view_bottom_realtime(model: Model) -> Element(Msg) {
  let #(button_label, button_class, play_msg) = case model.engine_state {
    Running -> #("⏸", "btn-play", PauseFade)
    Paused -> #("▶", "btn-play paused", ResumeFade)
    Stopped -> #("▶", "btn-play paused", StartFade)
  }

  html.div([attribute.class("reader-bottom-realtime")], [
    html.div([attribute.class("wpm-readout")], [
      html.text(int.to_string(model.wpm) <> " wpm"),
    ]),
    html.button(
      [
        attribute.class(button_class),
        attribute.type_("button"),
        attribute.aria_label("Play or pause reading"),
        event.on_click(play_msg) |> event.stop_propagation,
      ],
      [html.text(button_label)],
    ),
    html.div(
      [
        attribute.class("btn-play-spacer"),
        attribute.attribute("aria-hidden", "true"),
      ],
      [],
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
      // Mode is `Manual` here as a no-op default: the measurement
      // mirror passes `interactive: False`, which already gates the
      // click handler off regardless of mode, and the word-level
      // fade rendering uses an empty `erased_words` set so no
      // measurement-mirror word carries an inline opacity. The
      // measurement DOM stays opacity-clean, so its
      // `getBoundingClientRect().height` is unaffected by erase
      // styling.
      view_page_paragraph(
        p,
        set.new(),
        None,
        False,
        erased_opacity,
        set.new(),
        Manual,
      )
    }),
  )
}

fn view_page_paragraph(
  page_paragraph: PageParagraph,
  erased: Set(Int),
  focused: Option(Int),
  interactive: Bool,
  erased_opacity: String,
  erased_words: Set(Int),
  mode: Mode,
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
        erased_words,
        mode,
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
  erased_words: Set(Int),
  mode: Mode,
) -> Element(Msg) {
  // A literal " " text node between sentences keeps the gap visible
  // when each sentence's last word omits its trailing space.
  let sentence_elements =
    paragraph.sentences
    |> list.map(fn(s) {
      view_sentence(
        s,
        erased,
        focused,
        interactive,
        erased_opacity,
        erased_words,
        mode,
      )
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
  erased_words: Set(Int),
  mode: Mode,
) -> Element(Msg) {
  let word_count = list.length(sentence.words)
  let words =
    list.index_map(sentence.words, fn(word, index) {
      // Words carry their own trailing space so adjacent word spans
      // wrap cleanly under `display: inline`. The final word in a
      // sentence drops the space — the inter-sentence separator
      // above owns that boundary instead.
      let with_trailing_space = index < word_count - 1
      let word_erased = set.contains(erased_words, word.global_index)
      view_word(word, with_trailing_space, word_erased, erased_opacity)
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
  // Click-to-erase is a Manual-mode affordance only. In RealTime
  // mode the engine drives fades; a stray tap on a sentence span
  // must not erase the whole sentence — the page-level `Tap`
  // gesture is routed to pause/resume instead. The measurement
  // mirror passes `interactive: False`, so its spans never carry
  // a click handler regardless of mode.
  let click_enabled = interactive && mode == Manual
  let trailing_attrs = case click_enabled, is_erased {
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

fn view_word(
  word: Word,
  with_trailing_space: Bool,
  word_erased: Bool,
  erased_opacity: String,
) -> Element(Msg) {
  let text_content = case with_trailing_space {
    True -> word.text <> " "
    False -> word.text
  }
  // Individual-word opacity is the fade engine's render hook.
  // Ghost mode applies through the same `erased_opacity` string
  // that drives sentence-level erasure so a reader running with
  // ghost mode on sees faded words at the configured ghost
  // opacity rather than fully invisible. CSS handles the
  // transition timing via `.word { transition: opacity ... }`.
  let opacity_attrs = case word_erased {
    True -> [attribute.style("opacity", erased_opacity)]
    False -> []
  }

  html.span(
    [
      attribute.class("word"),
      attribute.attribute("data-global-index", int.to_string(word.global_index)),
      ..opacity_attrs
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
///
/// Visual structure (matching `mobile-reader-prototype.html`):
///
///   .sheet-handle                 — visual drag affordance
///   .settings-panel-header        — uppercase section title + close
///   pacing group
///     mode toggle
///     WPM / paragraph / page delay sliders
///   <hr> divider
///   appearance group
///     theme toggle
///     font / line-spacing sliders
///   <hr> divider
///   reading-aid group
///     ghost mode + opacity, dyslexia font
fn view_settings_sheet(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-panel"), stop_click_propagation()], [
    html.div(
      [
        attribute.class("settings-sheet-handle"),
        attribute.attribute("aria-hidden", "true"),
      ],
      [],
    ),
    view_settings_header(),
    view_mode_toggle(model),
    view_wpm_slider(model),
    view_paragraph_delay_slider(model),
    view_page_delay_slider(model),
    html.hr([attribute.class("settings-divider")]),
    view_theme_toggle(model),
    view_font_size_slider(model),
    view_line_spacing_slider(model),
    html.hr([attribute.class("settings-divider")]),
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

fn view_mode_toggle(model: Model) -> Element(Msg) {
  // Checkbox semantics: unchecked → `Manual`, checked → `RealTime`.
  // The label reads as "Real-time fade mode" so the off state
  // (the default) reads as "the original tap/click reader" without
  // needing to name it explicitly. `event.on_check` carries the
  // new checkbox state, which maps directly to `Mode`.
  let checked = model.mode == RealTime
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Real-time fade mode"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(checked),
        event.on_check(fn(is_on) {
          case is_on {
            True -> SetMode(RealTime)
            False -> SetMode(Manual)
          }
        }),
      ]),
    ]),
  ])
}

fn view_wpm_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Reading speed")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(int.to_string(model.wpm) <> " wpm"),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(int.to_string(min_wpm)),
      attribute.max(int.to_string(max_wpm)),
      attribute.step("10"),
      attribute.value(int.to_string(model.wpm)),
      attribute.attribute("aria-label", "Words per minute"),
      event.on_input(fn(value) {
        case int.parse(value) {
          Ok(parsed) -> SetWpm(parsed)
          Error(_) -> SetWpm(model.wpm)
        }
      }),
    ]),
  ])
}

fn view_paragraph_delay_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Paragraph pause")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(int.to_string(model.paragraph_delay_ms) <> " ms"),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(int.to_string(min_paragraph_delay_ms)),
      attribute.max(int.to_string(max_paragraph_delay_ms)),
      attribute.step("100"),
      attribute.value(int.to_string(model.paragraph_delay_ms)),
      attribute.attribute("aria-label", "Paragraph pause in milliseconds"),
      event.on_input(fn(value) {
        case int.parse(value) {
          Ok(parsed) -> SetParagraphDelay(parsed)
          Error(_) -> SetParagraphDelay(model.paragraph_delay_ms)
        }
      }),
    ]),
  ])
}

fn view_page_delay_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Page pause")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(int.to_string(model.page_delay_ms) <> " ms"),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(int.to_string(min_page_delay_ms)),
      attribute.max(int.to_string(max_page_delay_ms)),
      attribute.step("100"),
      attribute.value(int.to_string(model.page_delay_ms)),
      attribute.attribute("aria-label", "Page pause in milliseconds"),
      event.on_input(fn(value) {
        case int.parse(value) {
          Ok(parsed) -> SetPageDelay(parsed)
          Error(_) -> SetPageDelay(model.page_delay_ms)
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
