//// Vanishing Ink Lustre client. Mounts the reader as a Model-View-
//// Update application on `#app` and renders one viewport-sized page
//// of a `SegmentedText` at a time, paginated against actual DOM
//// dimensions instead of character-count estimates.
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
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
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
import client/types.{
  type BookMeta, type BookSettings, type UserSettings, BookSettings,
  UserSettings,
}
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

/// Compile-time fallback `UserSettings` used to seed `Model.global_defaults`
/// before the `SettingsLoaded` round trip lands. The values mirror the
/// server's `user_settings` column defaults so a fresh boot — even one
/// where the server response is delayed — applies the same baseline the
/// persisted record would surface. `dark_mode` is the only field whose
/// runtime seed (`prefers-color-scheme`) differs from the server default;
/// the caller supplies the OS preference at construction time so the
/// in-memory baseline matches the rendered theme until the server
/// response overwrites both.
fn fallback_user_settings(dark_mode: Bool) -> UserSettings {
  UserSettings(
    font_size: default_font_size,
    line_spacing: default_line_spacing,
    dark_mode: dark_mode,
    ghost_mode: False,
    ghost_opacity: default_ghost_opacity,
    default_wpm: default_wpm,
    default_paragraph_delay_ms: default_paragraph_delay_ms,
    default_page_delay_ms: default_page_delay_ms,
  )
}

/// All-null per-book overrides — every field falls back to the
/// global default. Used when `Reset to default` clears overrides
/// and as the placeholder shape when a book has no row in
/// `book_settings` yet.
fn empty_book_settings() -> BookSettings {
  BookSettings(
    wpm: None,
    paragraph_delay_ms: None,
    page_delay_ms: None,
    ghost_opacity: None,
  )
}

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
// Library view — book-cover palette
// ---------------------------------------------------------------------------
//
// The grid and hero card render each book onto a flat colour block —
// the source texts have no embedded cover art, so the affordance is
// deterministic colour-by-title. The palette below mirrors the warm
// literary palette in the design mock (warm copper, slate blue, sage
// green, dusk lavender, ink grey). The selection is a stable hash of
// the title so re-renders on the same book always paint the same
// colour, and two books with adjacent titles spread across the
// palette instead of clumping on one swatch.
/// The palette is the single source of truth for both the per-title
/// hash modulus (read via `list.length` in `cover_color_for_title`)
/// and the test's "every result is one of these" pin (read via
/// `cover_palette()` from the test module). Keeping the modulus
/// derived rather than hard-coded prevents the lock-step drift a
/// hard-coded `cover_color_count` invites — `gleam/list` is a
/// pure-Gleam list so `list.length` is O(n) but `n = 8`, and the
/// helper is called once per book per render.
pub const cover_colors: List(String) = [
  "#B87A52", "#4A7A8E", "#5A6B50", "#8A7C6E", "#6A5E80", "#7A8B7A", "#A05E5E",
  "#5E7A8B",
]

/// Pick a deterministic cover colour for a book based on its title.
/// The hash is a simple grapheme-codepoint sum modulo the palette
/// length — collisions are acceptable because the palette is a
/// visual rhythm cue, not a unique identifier.
///
/// Exposed so the library tests can pin the colour-for-title
/// contract without having to walk the rendered HTML for the inline
/// `style` value.
///
/// The two `let assert` rails state the invariants directly:
/// `cover_colors` is a non-empty `pub const`, so `int.modulo` is
/// always `Ok(_)`; `index` is always `< count`, so `list.drop`
/// always leaves a non-empty tail. If the palette were ever
/// shortened to empty, or `int.modulo`'s contract changed, the
/// assertion would crash at the violation rather than survive in
/// a degraded state. The previous revision carried three
/// fallback branches for these impossibilities; per the operative
/// standard, fallbacks for cases that cannot happen are dead code.
pub fn cover_color_for_title(title: String) -> String {
  let codepoints = string.to_utf_codepoints(title)
  let sum =
    list.fold(codepoints, 0, fn(acc, cp) {
      acc + string.utf_codepoint_to_int(cp)
    })
  let count = list.length(cover_colors)
  let assert Ok(index) = int.modulo(sum, count)
  let assert [color, ..] = list.drop(cover_colors, index)
  color
}

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

/// Active top-level view. `Library` renders the book grid plus the
/// add-book bottom sheet; `Reader` renders the paginated reading
/// surface against `model.text`. The reducer flips this field on
/// `OpenBook(_)` (library → reader) and `GoToLibrary` (reader →
/// library). No URL routing is involved — `modem`/`lustre_routed`
/// would add machinery that a two-view app cannot justify; a plain
/// enum on the model is sufficient and keeps the test surface flat.
pub type View {
  Library
  Reader
}

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
///   on the reader header toggles it.
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
/// * `total_sentence_count` / `total_word_count` — cached
///   denominators for `progress_percentage`. Computed once in the
///   `TextLoaded` arm via `total_counts` and refreshed on every
///   subsequent `TextLoaded`. The previous revision recomputed both
///   on every render, which at 200 WPM (`~3` engine dispatches per
///   second) compounded against every settings drag and keystroke
///   into hundreds of thousands of list traversals per second on a
///   100k-word book. The totals are immutable for the lifetime of
///   the loaded text — caching them is a design-phase decision,
///   not a hot-path optimisation.
/// * `current_chapter_title` — cached title for the chapter that
///   the visible page sits in, used by `view_reader_header` to
///   populate the centre slot of the chrome row. Computed via
///   `compute_current_chapter_title` and refreshed in the three
///   reducer arms that mutate any of `text` / `pages` /
///   `current_page` (`TextLoaded`, `ParagraphsMeasured`,
///   `change_page`). The view reads the cached field directly so
///   each render avoids re-walking `pagination.nth` and
///   `chapter_title_at` — the same caching pattern as the
///   sentence/word totals above. Empty string when no text is
///   loaded or the resolved chapter has no title.
/// * `total_pages` — cached `list.length(pages)`. Maintained in
///   the two arms that write `pages` (`TextLoaded` resets to `0`
///   alongside `pages: []`; `ParagraphsMeasured` writes the count
///   produced by `calculate_pages`). Same caching pattern as the
///   sentence/word totals — the view path reads the cache rather
///   than walking `pages` per render, which matters because
///   re-pagination on a settings-slider drag can produce hundreds
///   of pages on a 100k-word book. Reducer paths that need the
///   page count (`advance_to_next_page`, `change_page`) read the
///   cache for the same reason: a single canonical source of
///   truth across view and reducer call sites.
/// * `view` — current top-level view. Default `Library` at boot.
///   `init` fires `fetch_books()` so the grid populates from the
///   server; `OpenBook(_)` flips to `Reader` and chains a
///   `fetch_book(id)` to load the segmented payload.
/// * `books` — library contents (lightweight `BookMeta` records,
///   no segmented payload). Populated by `BooksLoaded(Ok(_))` and
///   appended to by `BookCreated(Ok(_))`. The library renders the
///   list directly; sort order is computed at render time from
///   `last_read_at`.
/// * `books_loading` — `True` between boot and the first
///   `BooksLoaded` dispatch, then `False` for the lifetime of the
///   session. The library view shows a skeleton state while loading
///   and an empty state when loading finishes with no books.
/// * `library_error` — `Some(message)` when the most recent library
///   fetch failed; `None` otherwise. Surfaced to the reader so a
///   network outage produces a clear message rather than a silent
///   empty grid. Cleared on the next successful load.
/// * `active_book_id` — `Some(id)` when a server-backed book is
///   loaded into the reader, `None` before any book has been
///   opened. Used by the reader header to badge the visible book
///   and (in a future quest) by the reading-state save path.
/// * `paste_title` / `paste_text` — controlled inputs for the
///   add-book bottom sheet. Cleared on `BookCreated(Ok(_))` so
///   the form returns to empty after a successful upload.
/// * `paste_submitting` — `True` while the POST is in flight so
///   the submit button can disable itself and avoid a duplicate
///   create-book on a double-tap.
/// * `paste_error` — `Some(message)` when validation or the
///   server's response rejected the most recent submission;
///   `None` otherwise. Cleared on the next successful POST or on
///   any form-field change.
/// * `add_book_open` — `True` when the add-book bottom sheet is
///   visible. Toggled by the FAB on the library view and by the
///   sheet's own close button / overlay tap.
/// * `created_book_segments` — single-slot cache of the `(meta,
///   segments)` payload returned by `POST /api/books`. `BookCreated(Ok(_))`
///   stamps it; `OpenBook(id)` consumes it (skipping the duplicate
///   `GET /api/books/:id` round trip) when the id matches, then
///   clears it. `None` between server-backed sessions and after the
///   slot has been consumed. Holding the meta alongside the segments
///   means the cache-hit path does not need to walk `books` to
///   recover the metadata.
/// * `global_defaults` — the persisted global reader preferences
///   (the same eight fields the server's `user_settings` table
///   carries). Seeded from the compiled-in defaults until the
///   `SettingsLoaded` round trip lands; updated alongside the
///   effective field whenever the reader changes a global preference
///   so the next per-book merge has the latest baseline.
/// * `book_settings` — the in-flight per-book overrides for the
///   currently-loaded book (`None` while in the library or before
///   `BookSettingsLoaded` lands). Each field is `None` when the
///   book has no override for that setting, so the merge step uses
///   `global_defaults` for that field. Saves go to
///   `/api/books/:id/settings`; resetting the row sends an all-null
///   record so the server clears the row.
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
    total_sentence_count: Int,
    total_word_count: Int,
    current_chapter_title: String,
    total_pages: Int,
    view: View,
    books: List(BookMeta),
    books_loading: Bool,
    library_error: Option(String),
    active_book_id: Option(String),
    paste_title: String,
    paste_text: String,
    paste_submitting: Bool,
    paste_error: Option(String),
    add_book_open: Bool,
    created_book_segments: Option(#(BookMeta, SegmentedText)),
    global_defaults: UserSettings,
    book_settings: Option(BookSettings),
    /// `Some(book_id)` while the delete confirmation overlay is visible
    /// for that book. `None` at all other times. The overlay asks the
    /// reader to confirm before the DELETE request fires, preventing
    /// accidental destruction of a book and its reading history.
    confirm_delete_id: Option(String),
    /// Ids of books whose `DELETE /api/books/:id` request is in flight.
    /// The card remains in `books` until `BookDeleted(_, Ok)` lands so
    /// the failure arm can restore the row without an explicit undo —
    /// but while the request is outstanding, the × badge for that card
    /// is rendered disabled and `ConfirmDelete(id)` is a no-op, so a
    /// keen-fingered reader cannot fire a second DELETE on the same
    /// id (which would resolve as a 404 and surface a confusing
    /// FetchError on a successful deletion).
    deleting_book_ids: Set(String),
  )
}

/// Application messages.
pub type Msg {
  /// A book has been segmented and is ready to render. Production
  /// flows route through `BookLoaded` (server response from
  /// `fetch_book`), which delegates the per-text reset to the same
  /// `apply_text_load` helper this arm uses; `TextLoaded` itself is
  /// retained as a direct entry point for the reducer tests that
  /// pin the per-text reset surface in isolation from the library
  /// bookkeeping `BookLoaded` layers on top.
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

  /// `GET /api/books` resolved. `Ok(books)` lands the library
  /// contents on the model and unsets `books_loading`; `Error(_)`
  /// surfaces a human-readable message into `library_error` and
  /// also unsets `books_loading` so the view does not stay on the
  /// skeleton state.
  BooksLoaded(Result(List(BookMeta), ffi.FetchError))

  /// `GET /api/books/:id` resolved. The success arm routes through
  /// `apply_book_loaded`, which delegates the per-text reset
  /// (segmented payload, flat-paragraph cache, totals, per-book
  /// scratch bitsets) to the shared `apply_text_load` helper that
  /// `TextLoaded` also calls, then layers on the library
  /// bookkeeping fields (view flip to `Reader`, `active_book_id`,
  /// `library_error: None`, engine reset). The error arm flips the
  /// view back to `Library` and stores the message in
  /// `library_error` so the reader sees what went wrong.
  BookLoaded(Result(#(BookMeta, SegmentedText), ffi.FetchError))

  /// `POST /api/books` resolved. The success arm prepends the new
  /// metadata to `books`, clears the paste form, and closes the
  /// bottom sheet — the reader stays in the library so they can
  /// see their new book on the grid before they decide to open it.
  /// The error arm leaves the form populated and surfaces the
  /// failure in `paste_error`.
  BookCreated(Result(#(BookMeta, SegmentedText), ffi.FetchError))

  /// Library card tapped. Flips `view` to `Reader`, kicks off
  /// `fetch_book(id)`, and resets the reader scratch state so the
  /// previous book's erasures don't bleed into the new session.
  OpenBook(id: String)

  /// Reader back-arrow pressed. Flips `view` to `Library`, stops
  /// any running fade engine, clears the in-flight word timer,
  /// and resets the reader's per-book state (`text`, `pages`,
  /// erasures, focus, line geometry) so re-opening the same book
  /// boots from a clean slate.
  GoToLibrary

  /// FAB tapped (open) or sheet overlay / close button tapped
  /// (close). Flips `add_book_open` and clears `paste_error` when
  /// the sheet opens so a previously surfaced validation message
  /// doesn't greet the next attempt.
  ToggleAddBook

  /// Controlled title input change. Stores the new value and clears
  /// `paste_error` so the error message disappears as soon as the
  /// reader starts typing again.
  SetPasteTitle(value: String)

  /// Controlled paste-textarea change. Same shape as `SetPasteTitle`
  /// — stores the new value and clears any prior error.
  SetPasteText(value: String)

  /// "Add to Library" button pressed. Validates that both fields
  /// are non-empty; on success, marks `paste_submitting: True` and
  /// fires `create_book`. The submit button's `disabled` reflects
  /// `paste_submitting` so a double-tap cannot fire two POSTs.
  SubmitPaste

  /// `GET /api/settings` resolved. The success arm decodes the body
  /// as `UserSettings`, stamps `model.global_defaults`, and applies
  /// every field to the matching effective model field — pushing CSS
  /// custom properties and body classes via the same FFI calls the
  /// individual setters use. The error arm logs and continues with
  /// the compiled-in defaults; settings load is non-blocking by
  /// design.
  SettingsLoaded(Result(String, ffi.FetchError))

  /// `GET /api/books/:id/settings` resolved. The success arm decodes
  /// the body as `BookSettings`, merges each field with
  /// `model.global_defaults`, and applies the merged values to the
  /// four overridable effective fields. The error arm logs and
  /// continues with the in-effect globals — a stuck request leaves
  /// the reader using the user's last-known global preferences.
  ///
  /// The `book_id` is the id the GET was issued for. The reducer
  /// drops responses whose id no longer matches `model.active_book_id`
  /// (or whose view has flipped back to `Library`) — see the guard at
  /// the top of `apply_book_settings_loaded`. The id round-trips so
  /// "open A → back to library → open B → A's response lands" cannot
  /// stamp A's overrides onto B's session.
  BookSettingsLoaded(book_id: String, result: Result(String, ffi.FetchError))

  /// Reader pressed "Reset to default" in the per-book section of
  /// the settings panel. Clears every per-book override (writes
  /// `BookSettings(None, None, None, None)` to the server and the
  /// model), and restores the four overridable effective fields to
  /// `model.global_defaults`. A no-op when there is no active book.
  ResetBookSettings

  /// Reader tapped the delete icon on a book card. Sets
  /// `confirm_delete_id` to `Some(id)` so the confirmation overlay
  /// renders for that specific card. No request is fired yet.
  ConfirmDelete(id: String)

  /// Reader tapped "Cancel" on the delete confirmation overlay.
  /// Clears `confirm_delete_id` without firing a DELETE request.
  CancelDelete

  /// Reader tapped "Delete" on the delete confirmation overlay.
  /// Fires `DELETE /api/books/:id` and clears `confirm_delete_id`.
  ExecuteDelete(id: String)

  /// `DELETE /api/books/:id` resolved. The `Ok` arm removes the book
  /// from `model.books` and, when the deleted book is the currently
  /// active reader book, navigates back to the library. The `Error`
  /// arm surfaces the failure in `library_error` without removing the
  /// book from the grid.
  BookDeleted(id: String, result: Result(String, ffi.FetchError))
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
      paste_submitting: False,
      paste_error: None,
      add_book_open: False,
      created_book_segments: None,
      global_defaults: fallback_user_settings(dark_mode),
      book_settings: None,
      confirm_delete_id: None,
      deleting_book_ids: set.new(),
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

  #(
    model,
    effect.batch([
      viewport_meta,
      body_classes,
      fetch_books(),
      fetch_settings(),
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
    TextLoaded(text) ->
      // `pages` is reset to `[]` by `apply_text_load`, so the cached
      // chapter title and `total_pages` are empty/zero until
      // `ParagraphsMeasured` lands the first page list. Resetting
      // them explicitly (rather than leaving the prior values in
      // place) avoids the cache lagging across a fresh book load —
      // the header would otherwise briefly carry the previous book's
      // title and page count.
      #(apply_text_load(model, text), measure_after_paint())

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
      // Refresh the cached chapter title against the post-clamp
      // page list — the visible page's chapter may have shifted if
      // pagination repacked paragraphs or the clamp moved the
      // current page.
      let chapter_title =
        compute_current_chapter_title(model.text, pages, clamped)
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
          current_chapter_title: chapter_title,
          total_pages: total,
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

    AdvanceWord -> apply_advance_word(model)

    SetWpm(value) -> apply_set_wpm(model, value)

    SetParagraphDelay(value) -> apply_set_paragraph_delay(model, value)

    SetPageDelay(value) -> apply_set_page_delay(model, value)

    BooksLoaded(Ok(books)) -> #(
      Model(..model, books: books, books_loading: False, library_error: None),
      effect.none(),
    )

    BooksLoaded(Error(error)) -> #(
      Model(
        ..model,
        books_loading: False,
        library_error: Some(describe_fetch_error(error)),
      ),
      effect.none(),
    )

    BookLoaded(Ok(#(meta, segments))) ->
      apply_book_loaded(model, meta, segments)

    BookLoaded(Error(error)) -> #(
      Model(
        ..model,
        view: Library,
        library_error: Some(describe_fetch_error(error)),
      ),
      effect.none(),
    )

    BookCreated(Ok(#(meta, segments))) -> #(
      Model(
        ..model,
        books: [meta, ..model.books],
        paste_title: "",
        paste_text: "",
        paste_submitting: False,
        paste_error: None,
        add_book_open: False,
        // Stash the segmented payload so an immediate `OpenBook(meta.id)`
        // can apply it directly instead of round-tripping through
        // `GET /api/books/:id`. The POST response already decoded the
        // same segments; dropping them on the floor would force a
        // second network call for data the client already has.
        created_book_segments: Some(#(meta, segments)),
      ),
      effect.none(),
    )

    BookCreated(Error(error)) -> #(
      Model(
        ..model,
        paste_submitting: False,
        paste_error: Some(describe_fetch_error(error)),
      ),
      effect.none(),
    )

    OpenBook(id) -> apply_open_book(model, id)

    GoToLibrary -> apply_go_to_library(model)

    ToggleAddBook -> {
      let opening = !model.add_book_open
      #(
        Model(
          ..model,
          add_book_open: opening,
          // Opening the sheet clears any prior error so the form
          // starts clean; closing it leaves whatever error was last
          // shown intact (the reader is dismissing the surface, not
          // acknowledging the message).
          paste_error: case opening {
            True -> None
            False -> model.paste_error
          },
        ),
        effect.none(),
      )
    }

    SetPasteTitle(value) -> #(
      Model(..model, paste_title: value, paste_error: None),
      effect.none(),
    )

    SetPasteText(value) -> #(
      Model(..model, paste_text: value, paste_error: None),
      effect.none(),
    )

    SubmitPaste -> apply_submit_paste(model)

    SettingsLoaded(Ok(body)) ->
      case json.parse(body, types.user_settings_decoder()) {
        Ok(settings) -> apply_settings_loaded(model, settings)
        Error(_) -> {
          io.println("Failed to decode /api/settings response")
          #(model, effect.none())
        }
      }

    SettingsLoaded(Error(error)) -> {
      io.println(
        "Failed to load global settings: " <> describe_fetch_error(error),
      )
      #(model, effect.none())
    }

    BookSettingsLoaded(book_id, Ok(body)) ->
      case json.parse(body, types.book_settings_decoder()) {
        Ok(settings) -> apply_book_settings_loaded(model, book_id, settings)
        Error(_) -> {
          io.println("Failed to decode /api/books/:id/settings response")
          #(model, effect.none())
        }
      }

    BookSettingsLoaded(_book_id, Error(error)) -> {
      io.println(
        "Failed to load book settings: " <> describe_fetch_error(error),
      )
      #(model, effect.none())
    }

    ResetBookSettings -> apply_reset_book_settings(model)

    // A second tap on an already-in-flight card is a no-op: opening
    // the confirmation overlay again would let the reader fire a
    // second DELETE on an id that is about to be 404'd by the first
    // delete's success, surfacing a confusing FetchError on what was
    // actually a successful deletion.
    ConfirmDelete(id) ->
      case set.contains(model.deleting_book_ids, id) {
        True -> #(model, effect.none())
        False -> #(
          Model(..model, confirm_delete_id: Some(id)),
          effect.none(),
        )
      }

    CancelDelete -> #(Model(..model, confirm_delete_id: None), effect.none())

    // Mark the id as in-flight so the × badge for that card renders
    // disabled (see `view_book_card` / `view_hero_card`) and a
    // re-entrant `ConfirmDelete(id)` is short-circuited above. The
    // id is removed from the set in both `BookDeleted` arms so a
    // failed delete also unblocks subsequent retries.
    ExecuteDelete(id) -> #(
      Model(
        ..model,
        confirm_delete_id: None,
        deleting_book_ids: set.insert(model.deleting_book_ids, id),
      ),
      delete_book_effect(id),
    )

    BookDeleted(id, Ok(_)) -> {
      let books = list.filter(model.books, fn(b) { b.id != id })
      let deleting_book_ids = set.delete(model.deleting_book_ids, id)
      case model.active_book_id == Some(id) {
        True -> {
          let #(nav_model, nav_effect) = apply_go_to_library(model)
          #(
            Model(
              ..nav_model,
              books: books,
              library_error: None,
              deleting_book_ids: deleting_book_ids,
            ),
            nav_effect,
          )
        }
        False -> #(
          Model(
            ..model,
            books: books,
            library_error: None,
            deleting_book_ids: deleting_book_ids,
          ),
          effect.none(),
        )
      }
    }

    BookDeleted(id, Error(error)) -> #(
      Model(
        ..model,
        library_error: Some(describe_fetch_error(error)),
        deleting_book_ids: set.delete(model.deleting_book_ids, id),
      ),
      effect.none(),
    )
  }
}

// ---------------------------------------------------------------------------
// update — library / book navigation helpers
// ---------------------------------------------------------------------------

/// Open a book by id. The cache-hit path consumes the
/// `created_book_segments` slot stamped by `BookCreated(Ok(_))`,
/// applies the cached payload through the same `apply_book_loaded`
/// pipeline a server response would have, and clears the slot so a
/// second open of the same id falls through to a real fetch. The
/// cache-miss path is the original behaviour: flip to the reader and
/// chain `fetch_book(id)`. A non-matching cache (the user created
/// book A then tapped book B) is also a miss — the cache is keyed by
/// id, not just "is anything cached".
fn apply_open_book(model: Model, id: String) -> #(Model, Effect(Msg)) {
  case model.created_book_segments {
    Some(#(meta, segments)) ->
      case meta.id == id {
        True -> {
          let #(loaded, eff) = apply_book_loaded(model, meta, segments)
          #(Model(..loaded, created_book_segments: None), eff)
        }
        False -> #(
          Model(..model, view: Reader, library_error: None),
          fetch_book(id),
        )
      }
    None -> #(Model(..model, view: Reader, library_error: None), fetch_book(id))
  }
}

/// Stamp a freshly-fetched book onto the reader state. Delegates
/// every per-text field reset to `apply_text_load` and layers on the
/// library-bookkeeping fields the test-only `TextLoaded` entry point
/// has no opinion on: flip the view to `Reader`, record the active
/// book id, clear any stale `library_error`, and force the fade
/// engine back to its rest state so a previous book's
/// `Running`/`Paused` cursor cannot follow into the new book. The
/// follow-up `ParagraphsMeasured` from the `measure_after_paint`
/// effect is what fills `pages` in.
///
/// RACE — `BookSettingsLoaded` arrives asynchronously after the
/// `fetch_book_settings` effect below. This helper flips to the
/// reader on the same frame, so the reader can edit a slider in the
/// window between the helper running and the GET response landing. A
/// slider drag during that window routes through `persist_target` →
/// `PersistBook(id)` (view is `Reader`, `active_book_id` is
/// `Some(id)`), so the user's edit lands on `book_settings` and PUTs
/// to the server. The in-flight GET response then arrives and
/// `apply_book_settings_loaded` overwrites `book_settings` with the
/// pre-PUT server snapshot, clobbering the just-applied user edit
/// until the next slider drag re-PUTs it. The window is materially
/// wider than the parallel init-time race on `apply_settings_loaded`
/// because the reader is actively in the reader view and can
/// interact immediately. Closing this last-write-wins variant would
/// require a request-id (drop a stale `BookSettingsLoaded` response
/// if a PUT has fired since the GET was issued) or a "fetch sequence
/// number" gate; neither is wired up today.
///
/// The cousin race — late `BookSettingsLoaded` landing after the
/// reader has navigated to the library or opened a different book
/// — IS guarded against. The Msg carries the originating `book_id`,
/// and `apply_book_settings_loaded` drops the response when
/// `model.view != Reader` or `model.active_book_id != Some(book_id)`.
/// That covers the "open A → back → A's GET lands" path (the
/// previously documented "library now shows the prior book's
/// pacing" defect) and the "open A → back → open B → A's GET lands"
/// path (which would otherwise stamp A's overrides onto B's
/// session).
fn apply_book_loaded(
  model: Model,
  meta: BookMeta,
  text: SegmentedText,
) -> #(Model, Effect(Msg)) {
  let loaded = apply_text_load(model, text)
  // Reset the per-book overrides up front so a previous book's
  // overrides do not bleed into the new session before
  // `BookSettingsLoaded` lands. The effective pacing fields
  // simultaneously revert to the global defaults; the follow-up
  // fetch will re-merge any overrides the new book carries.
  let defaults = loaded.global_defaults
  #(
    Model(
      ..loaded,
      view: Reader,
      active_book_id: Some(meta.id),
      library_error: None,
      engine_state: Stopped,
      next_word_index: None,
      book_settings: None,
      ghost_opacity: defaults.ghost_opacity,
      wpm: defaults.default_wpm,
      paragraph_delay_ms: defaults.default_paragraph_delay_ms,
      page_delay_ms: defaults.default_page_delay_ms,
    ),
    effect.batch([
      measure_after_paint(),
      // Symmetric with `apply_go_to_library`: the reset above moves
      // `ghost_opacity` back to the global default, and the CSS
      // custom property has to follow or the rendered opacity keeps
      // pointing at the prior book's value until
      // `apply_book_settings_loaded` lands (or never updates at all
      // if the new book has no override). Today the only entry path
      // here transits `apply_go_to_library` first, which has already
      // pushed the global value — but the helper must be
      // self-consistent so any future entry path (a deep-link, a
      // programmatic open) cannot flicker the prior book's opacity
      // onto the new one.
      effect.from(fn(_dispatch) {
        ffi.set_css_property(
          css_var_ghost_opacity,
          float.to_string(defaults.ghost_opacity),
        )
      }),
      fetch_book_settings(meta.id),
    ]),
  )
}

/// Per-text reset surface shared by `TextLoaded` and
/// `apply_book_loaded`. Every field cleared / refreshed here is part
/// of "the book the reader is currently reading" — the segmented
/// payload, the flat-paragraph cache that view + pagination read,
/// the paginated state (`pages` / `current_page`), every per-book
/// scratch field (`erased` sentence bitset, `erased_words` word
/// bitset, undo stack, touch origin, vim focus, measured line
/// boxes, active-line index), and the cached totals + chapter
/// title. Callers layer on view / library bookkeeping on top of the
/// returned `Model`.
fn apply_text_load(model: Model, text: SegmentedText) -> Model {
  let #(sentences, words) = total_counts(text)
  Model(
    ..model,
    text: Some(text),
    flat_paragraphs: pagination.flatten(text),
    pages: [],
    current_page: 0,
    erased: set.new(),
    erased_words: set.new(),
    undo_stack: [],
    touch_start: None,
    focused_sentence: None,
    line_boxes: [],
    active_line: None,
    total_sentence_count: sentences,
    total_word_count: words,
    current_chapter_title: "",
    total_pages: 0,
  )
}

/// Tear down the reader and return to the library. Stops any
/// in-flight fade engine (clear the FFI timer, drop the engine to
/// `Stopped`) and resets every per-book scratch field so reopening
/// the same — or a different — book starts from a clean slate.
/// `mode` is preserved because it is a user preference, not a
/// per-book setting; `books` / `books_loading` are untouched so
/// the library renders immediately on the swap.
fn apply_go_to_library(model: Model) -> #(Model, Effect(Msg)) {
  let defaults = model.global_defaults
  let cleared =
    Model(
      ..model,
      view: Library,
      text: None,
      flat_paragraphs: [],
      pages: [],
      current_page: 0,
      erased: set.new(),
      erased_words: set.new(),
      undo_stack: [],
      touch_start: None,
      focused_sentence: None,
      line_boxes: [],
      active_line: None,
      total_sentence_count: 0,
      total_word_count: 0,
      current_chapter_title: "",
      active_book_id: None,
      engine_state: Stopped,
      next_word_index: None,
      settings_open: False,
      // Returning to the library re-pins the four overridable fields
      // to the global defaults so the settings panel — which can be
      // opened from the library appbar — shows the user-wide
      // preferences rather than the previous book's effective values.
      book_settings: None,
      ghost_opacity: defaults.ghost_opacity,
      wpm: defaults.default_wpm,
      paragraph_delay_ms: defaults.default_paragraph_delay_ms,
      page_delay_ms: defaults.default_page_delay_ms,
    )
  #(
    cleared,
    effect.batch([
      effect.from(fn(_dispatch) { ffi.clear_word_timer() }),
      // Push the restored `ghost_opacity` into the CSS cascade so the
      // settings panel slider and any visible ghosted prose pick up
      // the global value rather than the last per-book override.
      effect.from(fn(_dispatch) {
        ffi.set_css_property(
          css_var_ghost_opacity,
          float.to_string(defaults.ghost_opacity),
        )
      }),
    ]),
  )
}

/// Validate the paste form and fire `create_book`. Empty title or
/// empty body short-circuits with a `paste_error`; the server's
/// own validation would catch the same case, but checking client-
/// side saves a round trip and surfaces the message instantly.
fn apply_submit_paste(model: Model) -> #(Model, Effect(Msg)) {
  let title = string.trim(model.paste_title)
  let text = string.trim(model.paste_text)
  case title, text {
    "", _ -> #(
      Model(..model, paste_error: Some("Please add a title.")),
      effect.none(),
    )
    _, "" -> #(
      Model(..model, paste_error: Some("Please paste some text.")),
      effect.none(),
    )
    _, _ -> #(
      Model(..model, paste_submitting: True, paste_error: None),
      create_book(title, text),
    )
  }
}

// ---------------------------------------------------------------------------
// update — fetch effects
// ---------------------------------------------------------------------------
//
// Three thin wrappers around the FFI fetch primitives. Each one
// stringifies the response body, applies a decoder, and routes the
// result through one Msg variant. Decode failures collapse into the
// matching `FetchError.DecodeError` so callers see one error shape
// regardless of where the failure originated.

/// `GET /api/books` and dispatch `BooksLoaded`.
fn fetch_books() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/books", fn(result) {
      let decoded =
        result
        |> result.try(fn(body) {
          json.parse(body, decode.list(types.book_meta_decoder()))
          |> result.map_error(fn(_) {
            ffi.DecodeError("Failed to decode book list")
          })
        })
      dispatch(BooksLoaded(decoded))
    })
  })
}

/// `GET /api/books/:id` and dispatch `BookLoaded`. The decoder
/// produces a `#(BookMeta, SegmentedText)` so the reducer can stamp
/// both onto the model in one arm.
fn fetch_book(id: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/books/" <> id, fn(result) {
      let decoded =
        result
        |> result.try(fn(body) {
          json.parse(body, types.book_with_segments_decoder())
          |> result.map_error(fn(_) { ffi.DecodeError("Failed to decode book") })
        })
      dispatch(BookLoaded(decoded))
    })
  })
}

/// `GET /api/settings` and dispatch `SettingsLoaded` with the raw
/// response body string. The reducer arm runs the decoder so a
/// decode failure surfaces as `Error(DecodeError(_))` alongside
/// every other fetch failure — keeping the load path's error
/// surface symmetrical with the books fetches.
fn fetch_settings() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/settings", fn(result) {
      dispatch(SettingsLoaded(result))
    })
  })
}

/// `GET /api/books/:id/settings` and dispatch `BookSettingsLoaded`.
/// Same shape as `fetch_settings` — the body is forwarded raw so
/// the reducer can branch on the decode result inline. The id is
/// closed over and re-emitted on the dispatched Msg so the reducer
/// can drop a stale response that lands after the reader has
/// navigated away or opened a different book.
fn fetch_book_settings(id: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/books/" <> id <> "/settings", fn(result) {
      dispatch(BookSettingsLoaded(id, result))
    })
  })
}

/// Persist the current global preferences via `PUT /api/settings`.
/// Fire-and-forget — the JS callback logs failures to the console so
/// a future operator session can investigate, but the UI does not
/// surface a banner because settings saves race with rapid slider
/// drags and a queued error toast would feel noisier than the bug
/// it indicates.
///
/// ORDERING — rapid slider drags fire one PUT per `Set*` dispatch
/// with no debounce and no sequence number. On a single HTTP/2
/// connection these typically arrive in dispatch order, but the
/// architecture does not enforce it: under packet reordering, a
/// retried request, or a future multiplexed client, the last value
/// on the server may not reflect the user's final intent.
/// Acceptable for the MVP — a debounce or a monotonic request-id
/// gate would pin the invariant if it ever matters.
fn save_global_settings(settings: UserSettings) -> Effect(Msg) {
  let body =
    settings
    |> user_settings_to_json
    |> json.to_string
  effect.from(fn(_dispatch) {
    ffi.fetch_json_put("/api/settings", body, fn(result) {
      case result {
        Ok(_) -> Nil
        Error(error) ->
          io.println(
            "Failed to save global settings: " <> describe_fetch_error(error),
          )
      }
    })
  })
}

/// Persist the current per-book overrides via
/// `PUT /api/books/:id/settings`. Same fire-and-forget shape as
/// `save_global_settings`; the only failure surface is the console.
/// The same lack-of-ordering caveat applies — see the ORDERING note
/// on `save_global_settings`.
fn save_book_settings(id: String, settings: BookSettings) -> Effect(Msg) {
  let body =
    settings
    |> book_settings_to_json
    |> json.to_string
  effect.from(fn(_dispatch) {
    ffi.fetch_json_put("/api/books/" <> id <> "/settings", body, fn(result) {
      case result {
        Ok(_) -> Nil
        Error(error) ->
          io.println(
            "Failed to save book settings: " <> describe_fetch_error(error),
          )
      }
    })
  })
}

fn user_settings_to_json(settings: UserSettings) -> json.Json {
  json.object([
    #("font_size", json.int(settings.font_size)),
    #("line_spacing", json.float(settings.line_spacing)),
    #("dark_mode", json.bool(settings.dark_mode)),
    #("ghost_mode", json.bool(settings.ghost_mode)),
    #("ghost_opacity", json.float(settings.ghost_opacity)),
    #("default_wpm", json.int(settings.default_wpm)),
    #(
      "default_paragraph_delay_ms",
      json.int(settings.default_paragraph_delay_ms),
    ),
    #("default_page_delay_ms", json.int(settings.default_page_delay_ms)),
  ])
}

fn book_settings_to_json(settings: BookSettings) -> json.Json {
  json.object([
    #("wpm", json.nullable(settings.wpm, json.int)),
    #(
      "paragraph_delay_ms",
      json.nullable(settings.paragraph_delay_ms, json.int),
    ),
    #("page_delay_ms", json.nullable(settings.page_delay_ms, json.int)),
    #("ghost_opacity", json.nullable(settings.ghost_opacity, json.float)),
  ])
}

/// `DELETE /api/books/:id` and dispatch `BookDeleted`. The server
/// responds 204 No Content on success and 404 when the id is not found;
/// both resolve through the same `Result(String, FetchError)` shape the
/// other fetch effects use, so the update arm can treat a 404 as an
/// error the same way it treats a network failure.
fn delete_book_effect(id: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_delete("/api/books/" <> id, fn(result) {
      dispatch(BookDeleted(id, result))
    })
  })
}

/// `POST /api/books` with the JSON body `{ "title", "text" }` and
/// dispatch `BookCreated`. The server segments and stores the text;
/// the response carries both the new metadata and the parsed
/// segments so the client could open the reader directly — today
/// we stay in the library so the reader can see the new card
/// appear before deciding to open it.
fn create_book(title: String, text: String) -> Effect(Msg) {
  let body =
    json.object([#("title", json.string(title)), #("text", json.string(text))])
    |> json.to_string
  effect.from(fn(dispatch) {
    ffi.fetch_json_post("/api/books", body, fn(result) {
      let decoded =
        result
        |> result.try(fn(body) {
          json.parse(body, types.create_book_response_decoder())
          |> result.map_error(fn(_) {
            ffi.DecodeError("Failed to decode create response")
          })
        })
      dispatch(BookCreated(decoded))
    })
  })
}

/// Project a `FetchError` to a human-readable string suitable for a
/// toast / error banner. Pulled out so the three failure-path arms
/// share one rendering — drift between them would otherwise
/// produce inconsistent UX for the same underlying failure.
///
/// Exposed for tests that pin the error-message surface — every
/// `FetchError` arm should produce a non-empty, user-readable
/// sentence rather than a `string.inspect` of the raw record.
pub fn describe_fetch_error(error: ffi.FetchError) -> String {
  case error {
    ffi.NetworkError(message) ->
      case message {
        "" -> "Could not reach the server."
        _ -> "Could not reach the server: " <> message
      }
    ffi.HttpError(status, body) ->
      case body {
        "" -> "Server returned " <> int.to_string(status) <> "."
        _ -> "Server returned " <> int.to_string(status) <> ": " <> body
      }
    ffi.DecodeError(detail) -> detail
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

/// Apply the persisted global preferences to the running model. Each
/// of the eight fields is mirrored onto the effective field on the
/// model and pushed into the CSS cascade through the same FFI calls
/// the individual setters use, so the rendered theme matches the
/// loaded record on the same frame. `global_defaults` is also stamped
/// so a later per-book merge has the latest baseline.
///
/// RACE — the GET that produces this dispatch fires from `init`; if
/// the reader toggles a global setting (`ToggleDarkMode`,
/// `SetFontSize`, `SetLineSpacing`, `ToggleGhostMode`) in the
/// ~100–500 ms window before the response lands, the PUT it triggers
/// races the in-flight GET. If the GET response arrives second, this
/// helper stamps `dark_mode`, `font_size`, `line_spacing`,
/// `ghost_mode` from the pre-edit server snapshot — the PUT succeeded
/// server-side, but the in-memory model briefly reverts and the user
/// watches their toggle un-toggle until the next save round-trip
/// lands. The four overridable fields below are already re-merged
/// through `book_settings`, so they survive the race; the four
/// non-overridable globals have no such guard. Closing the race
/// requires a request-id or "seen-once" flag on `SettingsLoaded`;
/// neither is wired up today.
fn apply_settings_loaded(
  model: Model,
  settings: UserSettings,
) -> #(Model, Effect(Msg)) {
  let new_model =
    Model(
      ..model,
      global_defaults: settings,
      font_size: settings.font_size,
      line_spacing: settings.line_spacing,
      dark_mode: settings.dark_mode,
      ghost_mode: settings.ghost_mode,
      // The per-book overrides — if any — already won the merge in
      // `apply_book_settings_loaded`; when loading the globals on top
      // of an already-merged reader state we must not regress those
      // overrides. The four fields below therefore re-merge against
      // any active `book_settings` rather than blindly taking the new
      // global value.
      ghost_opacity: effective_ghost_opacity(model.book_settings, settings),
      wpm: effective_wpm(model.book_settings, settings),
      paragraph_delay_ms: effective_paragraph_delay(
        model.book_settings,
        settings,
      ),
      page_delay_ms: effective_page_delay(model.book_settings, settings),
    )
  let css_effects =
    effect.from(fn(_dispatch) {
      ffi.set_css_property(
        css_var_font_size,
        int.to_string(new_model.font_size) <> "px",
      )
      ffi.set_css_property(
        css_var_line_height,
        float.to_string(new_model.line_spacing),
      )
      ffi.set_css_property(
        css_var_ghost_opacity,
        float.to_string(new_model.ghost_opacity),
      )
      ffi.set_body_class(body_class_light_mode, !new_model.dark_mode)
      ffi.set_body_class(body_class_ghost_mode, new_model.ghost_mode)
    })
  // Font size and line spacing changes alter paragraph wrap heights,
  // so kick the measurement loop. `repaginate_after_paint` is a no-op
  // when no text is loaded yet (the resulting `ViewportResized`
  // dispatch fires the measurement effect, which is harmless before
  // the reader has paginated anything).
  #(new_model, effect.batch([css_effects, repaginate_after_paint()]))
}

/// Merge per-book overrides with the current `global_defaults` and
/// apply the four resulting effective values to the model. The
/// `BookSettings` record is also stored so a later edit of one
/// override (or a `ResetBookSettings`) has the prior overrides to
/// diff against.
///
/// `book_id` is the id the originating `fetch_book_settings` call was
/// issued for. The guard at the top drops the response when:
///
///   * the reader has navigated back to the library
///     (`model.view != Reader` / `model.active_book_id == None`), or
///   * the active book has changed under the in-flight request
///     (open A → back → open B → A's GET lands).
///
/// Without the guard, a late response would either re-populate
/// `book_settings: Some(_)` while `view == Library` (an internally
/// inconsistent state — `book_settings.is_some()` should imply
/// `active_book_id.is_some()`) or stamp the previous book's overrides
/// onto the new active book's effective fields. Both are reachable
/// through ordinary navigation within the GET's ~100-300 ms window.
fn apply_book_settings_loaded(
  model: Model,
  book_id: String,
  settings: BookSettings,
) -> #(Model, Effect(Msg)) {
  case model.view, model.active_book_id {
    Reader, Some(active_id) if active_id == book_id -> {
      let new_model =
        Model(
          ..model,
          book_settings: Some(settings),
          ghost_opacity: effective_ghost_opacity(
            Some(settings),
            model.global_defaults,
          ),
          wpm: effective_wpm(Some(settings), model.global_defaults),
          paragraph_delay_ms: effective_paragraph_delay(
            Some(settings),
            model.global_defaults,
          ),
          page_delay_ms: effective_page_delay(
            Some(settings),
            model.global_defaults,
          ),
        )
      let css_effects =
        effect.from(fn(_dispatch) {
          ffi.set_css_property(
            css_var_ghost_opacity,
            float.to_string(new_model.ghost_opacity),
          )
        })
      #(new_model, css_effects)
    }
    _, _ -> #(model, effect.none())
  }
}

/// Clear every per-book override for the current book. Writes an
/// all-null record to the server (which deletes the override row's
/// values), restores the four effective fields to the global
/// defaults, and updates `model.book_settings` to match. A no-op
/// when no book is loaded — the reader cannot dispatch this Msg
/// from the library view in practice (the UI only renders the
/// Reset button when reading), but the guard keeps the helper
/// total.
fn apply_reset_book_settings(model: Model) -> #(Model, Effect(Msg)) {
  case model.active_book_id {
    None -> #(model, effect.none())
    Some(id) -> {
      let cleared = empty_book_settings()
      let defaults = model.global_defaults
      let new_model =
        Model(
          ..model,
          book_settings: Some(cleared),
          ghost_opacity: defaults.ghost_opacity,
          wpm: defaults.default_wpm,
          paragraph_delay_ms: defaults.default_paragraph_delay_ms,
          page_delay_ms: defaults.default_page_delay_ms,
        )
      let css_effects =
        effect.from(fn(_dispatch) {
          ffi.set_css_property(
            css_var_ghost_opacity,
            float.to_string(new_model.ghost_opacity),
          )
        })
      #(new_model, effect.batch([css_effects, save_book_settings(id, cleared)]))
    }
  }
}

/// Where to persist a change to one of the four overridable fields
/// (`ghost_opacity`, `wpm`, `paragraph_delay_ms`, `page_delay_ms`).
///
/// `PersistBook(id)` — the reader is on the reader view with an active
/// book id, so the change should be stored as a per-book override and
/// PUT to `/api/books/:id/settings`.
///
/// `PersistGlobal` — the reader is on the library view (no book
/// loaded, no per-book scope to attach the change to), so the change
/// is stored as a global default and PUT to `/api/settings`. This is
/// the path the library-appbar gear button feeds, and a future
/// route-state design that lets the reader edit globals while a book
/// is open can flow through the same arm.
type PersistTarget {
  PersistBook(id: String)
  PersistGlobal
}

/// Decide whether the next overridable-field change should land on
/// the active book or on the global defaults. The reader view with an
/// active book id is the only path that produces a per-book write —
/// every other configuration (library view, library view with stale
/// `active_book_id` from a half-cancelled load) falls through to the
/// global path so a slider drag in the library never silently writes
/// to a hidden book row.
fn persist_target(model: Model) -> PersistTarget {
  case model.view, model.active_book_id {
    Reader, Some(id) -> PersistBook(id)
    _, _ -> PersistGlobal
  }
}

fn effective_wpm(
  overrides: Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(wpm: Some(v), ..)) -> v
    _ -> defaults.default_wpm
  }
}

fn effective_paragraph_delay(
  overrides: Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(paragraph_delay_ms: Some(v), ..)) -> v
    _ -> defaults.default_paragraph_delay_ms
  }
}

fn effective_page_delay(
  overrides: Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(page_delay_ms: Some(v), ..)) -> v
    _ -> defaults.default_page_delay_ms
  }
}

fn effective_ghost_opacity(
  overrides: Option(BookSettings),
  defaults: UserSettings,
) -> Float {
  case overrides {
    Some(BookSettings(ghost_opacity: Some(v), ..)) -> v
    _ -> defaults.ghost_opacity
  }
}

fn apply_toggle_dark_mode(model: Model) -> #(Model, Effect(Msg)) {
  let new_dark = !model.dark_mode
  let new_defaults = UserSettings(..model.global_defaults, dark_mode: new_dark)
  #(
    Model(..model, dark_mode: new_dark, global_defaults: new_defaults),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_body_class(body_class_light_mode, !new_dark)
      }),
      save_global_settings(new_defaults),
    ]),
  )
}

fn apply_set_font_size(model: Model, size: Int) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(size, min_font_size, max_font_size)
  let new_defaults = UserSettings(..model.global_defaults, font_size: clamped)
  #(
    Model(..model, font_size: clamped, global_defaults: new_defaults),
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
      save_global_settings(new_defaults),
    ]),
  )
}

fn apply_set_line_spacing(
  model: Model,
  spacing: Float,
) -> #(Model, Effect(Msg)) {
  let clamped = clamp_float(spacing, min_line_spacing, max_line_spacing)
  let new_defaults =
    UserSettings(..model.global_defaults, line_spacing: clamped)
  #(
    Model(..model, line_spacing: clamped, global_defaults: new_defaults),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_css_property(css_var_line_height, float.to_string(clamped))
      }),
      repaginate_after_paint(),
      save_global_settings(new_defaults),
    ]),
  )
}

fn apply_toggle_ghost_mode(model: Model) -> #(Model, Effect(Msg)) {
  let new_ghost = !model.ghost_mode
  let new_defaults =
    UserSettings(..model.global_defaults, ghost_mode: new_ghost)
  #(
    Model(..model, ghost_mode: new_ghost, global_defaults: new_defaults),
    effect.batch([
      // Only the body class is toggled here. The `--vi-ghost-opacity`
      // custom property is owned by `apply_set_ghost_opacity`, which
      // writes it on every change to `model.ghost_opacity`; pushing it
      // again from this arm would be a dead write — the variable is
      // already up to date when ghost mode flips on or off.
      effect.from(fn(_dispatch) {
        ffi.set_body_class(body_class_ghost_mode, new_ghost)
      }),
      save_global_settings(new_defaults),
    ]),
  )
}

fn apply_set_ghost_opacity(
  model: Model,
  opacity: Float,
) -> #(Model, Effect(Msg)) {
  let clamped = clamp_float(opacity, min_ghost_opacity, max_ghost_opacity)
  let css_effect =
    effect.from(fn(_dispatch) {
      ffi.set_css_property(css_var_ghost_opacity, float.to_string(clamped))
    })
  let updated = Model(..model, ghost_opacity: clamped)
  case persist_target(updated) {
    PersistGlobal -> {
      let new_defaults =
        UserSettings(..updated.global_defaults, ghost_opacity: clamped)
      #(
        Model(..updated, global_defaults: new_defaults),
        effect.batch([css_effect, save_global_settings(new_defaults)]),
      )
    }
    PersistBook(id) -> {
      let overrides = case updated.book_settings {
        None -> empty_book_settings()
        Some(s) -> s
      }
      let new_overrides =
        BookSettings(..overrides, ghost_opacity: Some(clamped))
      #(
        Model(..updated, book_settings: Some(new_overrides)),
        effect.batch([css_effect, save_book_settings(id, new_overrides)]),
      )
    }
  }
}

fn apply_set_wpm(model: Model, value: Int) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(value, min_wpm, max_wpm)
  let updated = Model(..model, wpm: clamped)
  case persist_target(updated) {
    PersistGlobal -> {
      let new_defaults =
        UserSettings(..updated.global_defaults, default_wpm: clamped)
      #(
        Model(..updated, global_defaults: new_defaults),
        save_global_settings(new_defaults),
      )
    }
    PersistBook(id) -> {
      let overrides = case updated.book_settings {
        None -> empty_book_settings()
        Some(s) -> s
      }
      let new_overrides = BookSettings(..overrides, wpm: Some(clamped))
      #(
        Model(..updated, book_settings: Some(new_overrides)),
        save_book_settings(id, new_overrides),
      )
    }
  }
}

fn apply_set_paragraph_delay(
  model: Model,
  value: Int,
) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(value, min_paragraph_delay_ms, max_paragraph_delay_ms)
  let updated = Model(..model, paragraph_delay_ms: clamped)
  case persist_target(updated) {
    PersistGlobal -> {
      let new_defaults =
        UserSettings(
          ..updated.global_defaults,
          default_paragraph_delay_ms: clamped,
        )
      #(
        Model(..updated, global_defaults: new_defaults),
        save_global_settings(new_defaults),
      )
    }
    PersistBook(id) -> {
      let overrides = case updated.book_settings {
        None -> empty_book_settings()
        Some(s) -> s
      }
      let new_overrides =
        BookSettings(..overrides, paragraph_delay_ms: Some(clamped))
      #(
        Model(..updated, book_settings: Some(new_overrides)),
        save_book_settings(id, new_overrides),
      )
    }
  }
}

fn apply_set_page_delay(model: Model, value: Int) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(value, min_page_delay_ms, max_page_delay_ms)
  let updated = Model(..model, page_delay_ms: clamped)
  case persist_target(updated) {
    PersistGlobal -> {
      let new_defaults =
        UserSettings(..updated.global_defaults, default_page_delay_ms: clamped)
      #(
        Model(..updated, global_defaults: new_defaults),
        save_global_settings(new_defaults),
      )
    }
    PersistBook(id) -> {
      let overrides = case updated.book_settings {
        None -> empty_book_settings()
        Some(s) -> s
      }
      let new_overrides =
        BookSettings(..overrides, page_delay_ms: Some(clamped))
      #(
        Model(..updated, book_settings: Some(new_overrides)),
        save_book_settings(id, new_overrides),
      )
    }
  }
}

/// Toggle the OpenDyslexic body class. Unlike every other control on
/// the settings panel (`ToggleDarkMode`, `SetFontSize`,
/// `SetLineSpacing`, `ToggleGhostMode`, `SetGhostOpacity`, the four
/// pacing fields), `dyslexia_font` is **deliberately not persisted**:
/// it is not part of the wire-form `UserSettings` record and there is
/// no `user_settings.dyslexia_font` column on the server. The toggle
/// only modifies the in-memory `Model.dyslexia_font` and pushes the
/// body class through FFI; a page reload reverts to the compiled-in
/// default (`False`).
///
/// This divergence is intentional for the settings-persistence quest
/// (the original done-when did not enumerate dyslexia), but surfacing
/// it here so that a future operative does not copy this handler as a
/// precedent for a new persistable setting. Adding persistence later
/// requires extending `UserSettings` (server + client mirrors), the
/// `user_settings` schema (with an ALTER TABLE migration), the
/// JSON encoders / decoders, and routing this handler through
/// `save_global_settings` after the toggle — same shape as any other
/// `apply_set_*` arm in this file.
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
//   *       --SetMode(Manual)-->   Stopped  (mode switch always halts)
//
// There is no user-facing `StopFade` Msg: the engine reaches
// `Stopped` either through `SetMode(Manual)` (the back arrow on
// the reader header) or through document exhaustion in
// `advance_to_next_page_loop`. The internal `apply_stop_fade`
// helper is the implementation of that second path; the previous
// revision also exposed a `StopFade` Msg variant that had no view
// dispatcher, which left a reducer arm reachable only from tests.
// The variant was removed when no UI affordance materialised for
// it; if a future design wants an explicit "Stop" button distinct
// from "leave RealTime mode," reintroduce the Msg and route it
// through `apply_stop_fade`.
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
  // Read the cached `total_pages` rather than recomputing
  // `list.length(model.pages)`. The Model invariant guarantees the
  // two are equal, and reading the cache here matches the pattern
  // the view path already uses — leaving a single canonical source
  // of truth for "how many pages does this model have".
  advance_to_next_page_loop(model, model.current_page + 1, model.total_pages)
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
  // Read the cached `total_pages` — same rationale as
  // `advance_to_next_page`: the invariant
  // `total_pages == list.length(pages)` makes the cache the
  // canonical source, and using it everywhere prevents future
  // readers from wondering which call site is authoritative.
  let clamped = pagination.clamp_page_index(candidate, model.total_pages)
  case clamped == model.current_page {
    True -> model
    False -> {
      // Refresh the cached chapter title against the new page —
      // crossing chapter boundaries on `NextPage` (or the
      // navigation paths) is the routine cache-invalidation
      // trigger.
      let chapter_title =
        compute_current_chapter_title(model.text, model.pages, clamped)
      Model(
        ..model,
        current_page: clamped,
        undo_stack: [],
        current_chapter_title: chapter_title,
      )
    }
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

/// Top-level view. Dispatches on `model.view`: `Library` renders the
/// book grid plus the add-book bottom sheet; `Reader` renders the
/// paginated reading surface against `model.text`. The settings
/// panel rides as a sibling overlay rendered conditionally on
/// `model.settings_open` — it is only ever in the DOM when the
/// panel is open, so the surrounding rendering is unaffected by
/// settings state.
///
/// The shell `<div>` carries `class="vi-app"` rather than the older
/// `"reader"` because the surface now hosts both views; the CSS
/// rule it anchors (`#vi-shell` height) is selector-based and
/// unaffected by the class rename.
pub fn view(model: Model) -> Element(Msg) {
  let body = case model.view {
    Library -> view_library(model)
    Reader -> view_reader(model)
  }

  let overlay = case model.settings_open {
    True -> view_settings_panel(model)
    False -> element.none()
  }

  html.div([attribute.id("vi-shell"), attribute.class("vi-app")], [
    body,
    overlay,
  ])
}

/// Reader-view body. Renders a loading placeholder until a
/// `BookLoaded` (or, in tests, a `TextLoaded`) lands on the model,
/// then delegates to `view_paginated`.
fn view_reader(model: Model) -> Element(Msg) {
  case model.text {
    None -> view_placeholder()
    Some(_) -> view_paginated(model)
  }
}

/// Reader-view loading state. `BookLoaded(Error)` auto-routes back
/// to the library, but a `fetch_book` that simply hangs (slow
/// connection, server-side stall) leaves the reader stuck on this
/// surface unless an escape hatch is offered. The back glyph
/// dispatches `GoToLibrary` — the same Msg the populated reader's
/// header button uses — so the reader can always abandon a stuck
/// load without refreshing the page.
fn view_placeholder() -> Element(Msg) {
  html.div([attribute.class("reader-placeholder")], [
    html.button(
      [
        attribute.class("btn-icon reader-placeholder-back"),
        attribute.aria_label("Back to library"),
        attribute.type_("button"),
        event.on_click(GoToLibrary),
      ],
      [html.text("←")],
    ),
    html.div([attribute.class("reader-placeholder-label")], [
      html.text("Loading..."),
    ]),
  ])
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
  let total = model.total_pages
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

/// Sticky top chrome row. Three slots: back glyph (left), chapter
/// title (centre, ellipsised), settings gear (right). The back button
/// dispatches `GoToLibrary`, which stops any in-flight fade engine,
/// clears the reader's per-book scratch state, and flips
/// `model.view` back to `Library`. Pre-library-view the button
/// dispatched `SetMode(Manual)` so the reader could escape the
/// RealTime engine without a dedicated library — Act 4 now has a
/// real library view to return to.
///
/// The title slot is driven from the model: the chapter currently
/// being read carries an `Option(String)` title on `SegmentedText`,
/// and `current_chapter_title` looks it up by `chapter_index` on the
/// visible page's first paragraph. When the chapter has no title —
/// or the page list is still empty between `TextLoaded` and the
/// first measurement pass — the slot falls back to the active
/// book's title (looked up in `model.books` by `active_book_id`)
/// so an untitled-chapter book still has a name in the chrome.
/// The slot only renders an empty string when neither the chapter
/// nor the active book can supply a title (the test-only
/// `TextLoaded` entry point, which never stamps `active_book_id`).
fn view_reader_header(model: Model) -> Element(Msg) {
  // The title is read from the cached `current_chapter_title` field
  // on the model rather than walking the page → paragraph → chapter
  // chain on every render. The field is refreshed in the reducer
  // arms that mutate any of `text` / `pages` / `current_page`.
  let title = case model.current_chapter_title {
    "" -> active_book_title(model)
    chapter_title -> chapter_title
  }
  html.div([attribute.class("reader-header")], [
    html.div([attribute.class("reader-header-inner")], [
      html.button(
        [
          attribute.class("btn-icon"),
          attribute.aria_label("Back to library"),
          attribute.type_("button"),
          event.on_click(GoToLibrary),
        ],
        [html.text("←")],
      ),
      html.div([attribute.class("reader-title")], [html.text(title)]),
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

/// Resolve the title of the active book — the `BookMeta` in
/// `model.books` whose `id` matches `model.active_book_id`. Used
/// by the reader header as a fallback when the visible chapter
/// carries no title of its own (every chapter in the bundled
/// Tell-Tale Heart fixture, for instance, has `title: None`, so
/// the reader header would otherwise show an empty centre slot).
///
/// Falls through to `""` when there is no active book id (the
/// test-only `TextLoaded` entry point never stamps it) or when
/// the book is not in `model.books` (a path that does not occur
/// in production today — `BookCreated` prepends and `BooksLoaded`
/// supplies the meta before `OpenBook` fires — but the helper
/// stays total so a future direct-load entry point cannot crash
/// the header).
fn active_book_title(model: Model) -> String {
  case model.active_book_id {
    None -> ""
    Some(id) ->
      case list.find(model.books, fn(meta) { meta.id == id }) {
        Ok(meta) -> meta.title
        Error(_) -> ""
      }
  }
}

/// Look up the title of the chapter the current page sits in.
/// Returns the chapter's title when one is present, an empty
/// string otherwise. Called from the three reducer arms that
/// mutate any of `text` / `pages` / `current_page` to refresh
/// the cached `Model.current_chapter_title` field; the view
/// reads the cached field rather than calling this helper on
/// every render.
///
/// The lookup walks the page → first paragraph → `chapter_index`
/// chain so the slot tracks the reader as they cross chapter
/// boundaries: a page that opens inside chapter 1 shows chapter 1's
/// title even when the previous page belonged to chapter 0.
///
/// Falls through to `""` rather than crashing when:
/// * `text` is `None` (pre-`TextLoaded` — header is not rendered
///   today, but the helper stays total),
/// * `pages` is empty (the pagination-pending window after
///   `TextLoaded` and before the first `ParagraphsMeasured`),
/// * the resolved chapter carries `title: None`.
fn compute_current_chapter_title(
  text: Option(SegmentedText),
  pages: List(Page),
  current_page: Int,
) -> String {
  case text {
    None -> ""
    Some(t) ->
      case pagination.nth(pages, current_page) {
        None -> ""
        Some(page) ->
          case page.paragraphs {
            [] -> ""
            [first, ..] -> chapter_title_at(t, first.chapter_index)
          }
      }
  }
}

fn chapter_title_at(text: SegmentedText, chapter_index: Int) -> String {
  case list.find(text.chapters, fn(c) { c.index == chapter_index }) {
    Ok(chapter) -> option.unwrap(chapter.title, "")
    Error(_) -> ""
  }
}

/// Thin reading-progress bar between the header and the reading
/// area. The fill width is driven inline from the model:
///
/// * Manual mode — fraction of sentences erased over the whole text.
/// * RealTime mode — fraction of words faded over the whole text.
///
/// Both denominators are the whole-book totals cached on the model
/// (`total_sentence_count`, `total_word_count`) rather than the
/// current page's slice, so the bar reads as "progress through the
/// book" rather than "progress through this page". When the model
/// has no text yet, the cached totals are `0` and the fill is 0% —
/// the bar renders as an empty track until `TextLoaded` lands.
fn view_progress_bar(model: Model) -> Element(Msg) {
  let percent = progress_percentage(model)
  let width_value = float.to_string(percent) <> "%"
  // ARIA progressbar semantics let screen reader users hear where
  // they are in the book — the app's central affordance. The
  // `aria-valuenow` is rounded to the nearest whole percent so the
  // announcement reads cleanly ("forty-two percent") rather than
  // dictating the float's decimal tail. The fill div carries
  // `aria-hidden="true"` because its inline `width` style is purely
  // visual; the role/values on the track already convey the state.
  let value_now = int.to_string(float.round(percent))
  html.div(
    [
      attribute.class("reader-progress-track"),
      attribute.role("progressbar"),
      attribute.aria_valuemin("0"),
      attribute.aria_valuemax("100"),
      attribute.aria_valuenow(value_now),
      attribute.aria_label("Reading progress"),
    ],
    [
      html.div(
        [
          attribute.class("reader-progress-fill"),
          attribute.style("width", width_value),
          attribute.aria_hidden(True),
        ],
        [],
      ),
    ],
  )
}

/// Reading progress as a percentage, rounded to one decimal place.
///
/// The denominator is read from the cached `total_sentence_count` /
/// `total_word_count` fields on the model — those fields are
/// computed once per `TextLoaded` (see `total_counts`) so the
/// per-render cost here is constant. The previous revision walked
/// every chapter → paragraph → sentence (and word) on every call,
/// which compounded badly against the fade engine's ~3 dispatches
/// per second at 200 WPM plus every settings drag and keystroke.
///
/// `float.to_precision(_, 1)` snaps the result to a single decimal
/// digit so the serialised `width:<n>%` style is a clean prefix
/// (`33.3`, `40.0`) rather than the float's full-precision
/// expansion (`33.333333333333%`). The CSS transition reads the
/// truncated value just as faithfully, and the rendered HTML tests
/// can pin the full value instead of a prefix substring.
fn progress_percentage(model: Model) -> Float {
  let #(numerator, denominator) = case model.mode {
    Manual -> #(set.size(model.erased), model.total_sentence_count)
    RealTime -> #(set.size(model.erased_words), model.total_word_count)
  }
  case denominator {
    0 -> 0.0
    _ ->
      int.to_float(numerator) /. int.to_float(denominator) *. 100.0
      |> float.to_precision(1)
  }
}

/// Walk the segmented text once and return `#(sentences, words)`.
/// Called from the `TextLoaded` reducer so the result can be cached
/// on the model — the totals do not change between loads, so the
/// view layer reads them from constant fields instead of re-walking
/// the whole book on every render.
///
/// One fold is used rather than the previous twin `list.flat_map`
/// chains: at the design phase a 100k-word book would have driven
/// the view-time cost into the hundreds of thousands of list
/// traversals per second under fade-engine pacing. Caching removes
/// that cost; the single fold here also halves the one-time cost
/// at load.
fn total_counts(text: SegmentedText) -> #(Int, Int) {
  list.fold(text.chapters, #(0, 0), fn(chapter_acc, chapter) {
    list.fold(chapter.paragraphs, chapter_acc, fn(paragraph_acc, paragraph) {
      list.fold(paragraph.sentences, paragraph_acc, fn(sentence_acc, sentence) {
        let #(sentences, words) = sentence_acc
        #(sentences + 1, words + list.length(sentence.words))
      })
    })
  })
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
      attribute.aria_hidden(True),
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
/// * `Stopped` — render `▶` with the `.ready` accent background;
///   click dispatches `StartFade`.
/// * `Paused`  — render `▶` with the `.ready` accent background;
///   click dispatches `ResumeFade`.
/// * `Running` — render `⏸` with the default inverted background;
///   click dispatches `PauseFade`.
///
/// `Stopped` and `Paused` share the `.ready` modifier (rather
/// than a `.paused` class that mislabels the Stopped case as
/// "paused") because both states paint the same "press me to
/// resume / start" affordance.
///
/// No `event.stop_propagation` is required: the page-level touch
/// handlers (`gestures.on_touch_*`) sit on `#vi-reading-area` /
/// `.reader-page`, while this button lives inside
/// `.reader-bottom-bar`. The two are *siblings* under
/// `.reader-text`, not ancestor and descendant — DOM events bubble
/// up through ancestors only, so a tap on the play button never
/// reaches the reading-area touch handler and cannot fire the
/// engine transition twice.
fn view_bottom_realtime(model: Model) -> Element(Msg) {
  let #(button_label, button_class, play_msg, aria_label) = case
    model.engine_state
  {
    Running -> #("⏸", "btn-play", PauseFade, "Pause reading")
    Paused -> #("▶", "btn-play ready", ResumeFade, "Resume reading")
    Stopped -> #("▶", "btn-play ready", StartFade, "Start reading")
  }

  html.div([attribute.class("reader-bottom-realtime")], [
    html.div(
      [
        attribute.class("wpm-readout"),
        // `role="text"` collapses the element into a single text node
        // in the accessibility tree and exposes the aria-label as the
        // accessible name. Without a role, a roleless `<div>` is a
        // generic that JAWS and VoiceOver may skip in announcement
        // passes — dropping the verbose phrase silently. `role="status"`
        // would announce on every slider tick during a drag; we want
        // a static label, not a live region.
        attribute.role("text"),
        attribute.aria_label(
          "Reading speed: " <> int.to_string(model.wpm) <> " words per minute",
        ),
      ],
      [html.text(int.to_string(model.wpm) <> " wpm")],
    ),
    html.button(
      [
        attribute.class(button_class),
        attribute.type_("button"),
        attribute.aria_label(aria_label),
        event.on_click(play_msg),
      ],
      [html.text(button_label)],
    ),
    html.div(
      [
        attribute.class("btn-play-spacer"),
        attribute.aria_hidden(True),
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
      attribute.aria_hidden(True),
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
      attribute.role("dialog"),
      attribute.aria_modal(True),
      attribute.aria_label("Reader settings"),
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
        attribute.aria_hidden(True),
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
    view_book_override_section(model),
  ])
}

/// Per-book override controls. Rendered only when the reader is in
/// the reader view with an active book id — the library view has no
/// per-book scope to attach a reset to. The visible section is a
/// single "Reset to default" button: every slider in the panel above
/// it already routes its writes through `persist_target`, so a
/// dedicated per-book editing surface would duplicate the existing
/// controls. The reset button collapses every override to `None`,
/// applies the global defaults to the four overridable fields, and
/// PUTs the cleared record so the server row drops its values.
///
/// The footer note explains the scoping — without it the reader
/// would have no way to tell that pacing edits made while reading
/// only affect this book.
fn view_book_override_section(model: Model) -> Element(Msg) {
  case model.view, model.active_book_id {
    Reader, Some(_) -> view_book_override_panel(model)
    _, _ -> element.none()
  }
}

fn view_book_override_panel(model: Model) -> Element(Msg) {
  let has_overrides = case model.book_settings {
    None -> False
    Some(s) -> book_settings_has_overrides(s)
  }
  html.div([attribute.class("settings-book-overrides")], [
    html.hr([attribute.class("settings-divider")]),
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Per-book overrides")]),
    ]),
    html.div([attribute.class("settings-row-hint")], [
      html.text(
        "Pacing and ghost opacity changes while reading apply to this book only.",
      ),
    ]),
    html.button(
      [
        attribute.class("btn-bar"),
        attribute.type_("button"),
        attribute.disabled(!has_overrides),
        attribute.aria_label("Reset book overrides to defaults"),
        event.on_click(ResetBookSettings),
      ],
      [html.text("Reset to default")],
    ),
  ])
}

fn book_settings_has_overrides(settings: BookSettings) -> Bool {
  option.is_some(settings.wpm)
  || option.is_some(settings.paragraph_delay_ms)
  || option.is_some(settings.page_delay_ms)
  || option.is_some(settings.ghost_opacity)
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
        attribute.aria_label("Close settings"),
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
      attribute.aria_label("Font size in pixels"),
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
      attribute.aria_label("Line spacing multiplier"),
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
      attribute.aria_label("Words per minute"),
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
      attribute.aria_label("Paragraph pause in milliseconds"),
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
      attribute.aria_label("Page pause in milliseconds"),
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
      attribute.aria_label("Ghost mode opacity"),
      event.on_input(fn(value) {
        case float.parse(value) {
          Ok(parsed) -> SetGhostOpacity(parsed)
          Error(_) -> SetGhostOpacity(model.ghost_opacity)
        }
      }),
    ]),
  ])
}

// ---------------------------------------------------------------------------
// View — library
// ---------------------------------------------------------------------------
//
// Mirrors the mobile prototype at
// `local/design-mocks/vanishing-ink/mobile-library-prototype.html` —
// the warm app bar with the Vanishing Ink wordmark, a "Continue
// Reading" hero card for the most-recently-read book, a 2-column
// grid for the remaining titles, and a floating action button that
// opens the add-book bottom sheet. The empty state and the
// fetch-error state both surface inside the same `.lib-body`
// container so the chrome never reshuffles between states.

/// Render the library view: app bar + scrollable body (hero card,
/// grid or empty state, error banner) + FAB + add-book sheet.
fn view_library(model: Model) -> Element(Msg) {
  html.div([attribute.class("view-library")], [
    view_library_appbar(),
    html.div([attribute.class("lib-scroll")], [view_library_body(model)]),
    view_add_book_fab(),
    view_add_book_sheet(model),
    view_delete_confirm_overlay(model),
  ])
}

fn view_library_appbar() -> Element(Msg) {
  html.div([attribute.class("lib-appbar")], [
    html.div([attribute.class("lib-appbar-inner")], [
      html.div([attribute.class("app-wordmark")], [
        html.div(
          [
            attribute.class("wordmark-dot"),
            attribute.attribute("aria-hidden", "true"),
          ],
          [],
        ),
        html.span([], [html.text("Vanishing Ink")]),
      ]),
      // Settings is reachable from the library so global preferences
      // (theme, font, dyslexia mode, default pacing) can be tweaked
      // before any book is open — without this, the gear was only
      // available once the reader entered a book, hiding a useful
      // surface behind a navigation step.
      html.button(
        [
          attribute.class("btn-icon"),
          attribute.aria_label("Open settings"),
          attribute.type_("button"),
          event.on_click(ToggleSettings),
        ],
        [html.text("⚙")],
      ),
    ]),
  ])
}

/// Library body. Surface order — fetch error (if any) → hero card →
/// grid header + grid (or empty state). Keeps the chrome stable so
/// loading / error / populated states all use the same column.
fn view_library_body(model: Model) -> Element(Msg) {
  let error_banner = case model.library_error {
    None -> element.none()
    Some(message) -> view_library_error(message)
  }

  let sorted = sort_books_by_recency(model.books)
  let hero_book = hero_candidate(sorted)
  let grid_books = grid_candidates(sorted, hero_book)

  // The hero and each grid card need to know whether their delete
  // request is in flight so the × badge can render disabled. Threading
  // a closure (rather than the raw set) keeps the lookup out of the
  // view layer's vocabulary — `view_book_card` doesn't have to know
  // a `Set` exists, only that "is this id currently being deleted?"
  // is a one-call query.
  let is_deleting = fn(id: String) -> Bool {
    set.contains(model.deleting_book_ids, id)
  }

  let hero = case hero_book {
    None -> element.none()
    Some(book) -> view_hero_card(book, is_deleting(book.id))
  }

  let body_main = case model.books_loading, model.books {
    True, _ -> view_library_loading()
    False, [] -> view_library_empty()
    False, _ -> view_library_grid(grid_books, is_deleting)
  }

  html.div([attribute.class("lib-body")], [error_banner, hero, body_main])
}

/// Delete confirmation modal. Rendered as a full-screen overlay when
/// `confirm_delete_id` is `Some(_)`. Tapping the scrim cancels;
/// tapping Delete fires `ExecuteDelete`.
fn view_delete_confirm_overlay(model: Model) -> Element(Msg) {
  case model.confirm_delete_id {
    None -> element.none()
    Some(book_id) -> {
      let title = case list.find(model.books, fn(b) { b.id == book_id }) {
        Ok(book) -> book.title
        Error(_) -> "this book"
      }
      html.div(
        [
          attribute.class("sheet-overlay open"),
          attribute.attribute("role", "dialog"),
          attribute.attribute("aria-modal", "true"),
          attribute.aria_label("Confirm delete"),
          event.on_click(CancelDelete),
        ],
        [
          html.div(
            [
              attribute.class("delete-confirm-sheet"),
              stop_click_propagation(),
            ],
            [
              html.div([attribute.class("delete-confirm-title")], [
                html.text("Delete \"" <> title <> "\"?"),
              ]),
              html.div([attribute.class("delete-confirm-sub")], [
                html.text(
                  "This will permanently remove the book and its reading history.",
                ),
              ]),
              html.div([attribute.class("delete-confirm-actions")], [
                html.button(
                  [
                    attribute.class("btn-bar"),
                    attribute.type_("button"),
                    event.on_click(CancelDelete),
                  ],
                  [html.text("Cancel")],
                ),
                html.button(
                  [
                    attribute.class("btn-bar btn-bar-danger"),
                    attribute.type_("button"),
                    event.on_click(ExecuteDelete(book_id)),
                  ],
                  [html.text("Delete")],
                ),
              ]),
            ],
          ),
        ],
      )
    }
  }
}

/// Sort by `last_read_at` descending, with unread books (None)
/// falling to the end. Books with equal timestamps fall back to
/// `uploaded_at` descending so the order is total — equal-keyed
/// inputs would otherwise rely on `list.sort`'s stability for
/// readable output.
fn sort_books_by_recency(books: List(BookMeta)) -> List(BookMeta) {
  list.sort(books, compare_by_recency)
}

fn compare_by_recency(a: BookMeta, b: BookMeta) -> order.Order {
  case a.last_read_at, b.last_read_at {
    Some(a_ts), Some(b_ts) ->
      case string.compare(b_ts, a_ts) {
        order.Eq -> string.compare(b.uploaded_at, a.uploaded_at)
        ord -> ord
      }
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> string.compare(b.uploaded_at, a.uploaded_at)
  }
}

/// The "Continue Reading" hero is the most-recently-read book; it
/// is only surfaced when at least one book has a non-None
/// `last_read_at`. A brand-new account (every book unread) skips
/// the hero entirely so the reader is not encouraged to "continue"
/// reading something they never started.
fn hero_candidate(sorted: List(BookMeta)) -> Option(BookMeta) {
  case sorted {
    [first, ..] ->
      case first.last_read_at {
        Some(_) -> Some(first)
        None -> None
      }
    [] -> None
  }
}

/// Books shown in the grid. The hero book is filtered out of the
/// grid so the same card never appears twice; when there is no
/// hero, every book lands on the grid.
fn grid_candidates(
  sorted: List(BookMeta),
  hero: Option(BookMeta),
) -> List(BookMeta) {
  case hero {
    None -> sorted
    Some(hero_book) -> list.filter(sorted, fn(book) { book.id != hero_book.id })
  }
}

fn view_library_error(message: String) -> Element(Msg) {
  html.div(
    [attribute.class("lib-error"), attribute.attribute("role", "alert")],
    [html.text(message)],
  )
}

fn view_library_loading() -> Element(Msg) {
  html.div([attribute.class("lib-loading")], [
    html.text("Loading your library…"),
  ])
}

/// Empty state copy doubles as the only call-to-action the reader
/// gets on a fresh account — the FAB also opens the same sheet,
/// but the empty state plants the affordance front-and-centre so
/// a first-time user knows where to start.
fn view_library_empty() -> Element(Msg) {
  html.div([attribute.class("lib-empty")], [
    html.div([attribute.class("lib-empty-title")], [
      html.text("Your library is empty."),
    ]),
    html.div([attribute.class("lib-empty-subtitle")], [
      html.text("Tap the + button to add a book by pasting text."),
    ]),
  ])
}

/// The hero card is the most prominent affordance on the library
/// surface — the book the reader is most likely to want to remove
/// (just finished, abandoned, imported by mistake) is precisely the
/// one the × badge has to reach. The badge sits in a sibling layer
/// above the open-book button rather than inside it: nested
/// `<button>` is invalid HTML and would also collapse the click
/// targets in the accessibility tree.
fn view_hero_card(book: BookMeta, is_deleting: Bool) -> Element(Msg) {
  let color = cover_color_for_title(book.title)
  let author = option.unwrap(book.author, "")
  html.div([attribute.class("hero-card-wrapper")], [
    html.button(
      [
        attribute.class("hero-card"),
        attribute.type_("button"),
        attribute.aria_label("Continue reading " <> book.title),
        event.on_click(OpenBook(book.id)),
      ],
      [
        html.div([attribute.class("section-label")], [
          html.text("Continue Reading"),
        ]),
        html.div(
          [
            attribute.class("hero-cover"),
            attribute.style("background", color),
          ],
          [
            html.div(
              [
                attribute.class("hero-cover-gradient"),
                attribute.attribute("aria-hidden", "true"),
              ],
              [],
            ),
            html.div([attribute.class("hero-cover-text")], [
              html.div([attribute.class("hero-title")], [html.text(book.title)]),
              html.div([attribute.class("hero-author")], [html.text(author)]),
            ]),
          ],
        ),
        html.div([attribute.class("hero-meta")], [
          html.div([attribute.class("hero-meta-line")], [
            html.text(format_word_count(book.word_count) <> " words"),
          ]),
          html.div([attribute.class("hero-cta")], [
            html.text("Continue Reading"),
          ]),
        ]),
      ],
    ),
    view_delete_badge(book, is_deleting, ["btn-delete-hero"]),
  ])
}

/// Render the 2-column book grid. The wrapping container carries
/// the section label so the empty-grid case (a library with only
/// a hero book) collapses cleanly without leaving a dangling
/// header.
fn view_library_grid(
  books: List(BookMeta),
  is_deleting: fn(String) -> Bool,
) -> Element(Msg) {
  case books {
    [] -> element.none()
    _ ->
      html.div([attribute.class("lib-grid-section")], [
        html.div([attribute.class("section-label")], [
          html.text("Your Library"),
        ]),
        html.div(
          [attribute.class("book-grid")],
          list.map(books, fn(book) { view_book_card(book, is_deleting(book.id)) }),
        ),
      ])
  }
}

fn view_book_card(book: BookMeta, is_deleting: Bool) -> Element(Msg) {
  let color = cover_color_for_title(book.title)
  let author = option.unwrap(book.author, "")
  html.div([attribute.class("book-card-wrapper")], [
    html.button(
      [
        attribute.class("book-card"),
        attribute.type_("button"),
        attribute.aria_label("Open " <> book.title),
        event.on_click(OpenBook(book.id)),
      ],
      [
        html.div(
          [attribute.class("book-cover"), attribute.style("background", color)],
          [
            html.div([attribute.class("book-cover-title")], [
              html.text(book.title),
            ]),
          ],
        ),
        html.div([attribute.class("book-info")], [
          html.div([attribute.class("book-title")], [html.text(book.title)]),
          html.div([attribute.class("book-author")], [html.text(author)]),
          html.div([attribute.class("book-meta")], [
            html.text(format_word_count(book.word_count) <> " words"),
          ]),
        ]),
      ],
    ),
    view_delete_badge(book, is_deleting, []),
  ])
}

/// Shared × badge used by both the hero card and each grid card.
/// `is_deleting` mirrors `model.deleting_book_ids` for this id —
/// while a DELETE is in flight, the button renders disabled (and
/// no `on_click` is attached) so a second tap cannot fire a duplicate
/// request that would race the first's response. `extra_classes`
/// lets the hero card opt into its larger badge variant without
/// duplicating the base styles.
fn view_delete_badge(
  book: BookMeta,
  is_deleting: Bool,
  extra_classes: List(String),
) -> Element(Msg) {
  let base_classes = ["btn-delete-book", ..extra_classes]
  let class_attr = case is_deleting {
    True -> attribute.class(string.join(["is-deleting", ..base_classes], " "))
    False -> attribute.class(string.join(base_classes, " "))
  }
  let common = [
    class_attr,
    attribute.type_("button"),
    attribute.aria_label("Delete " <> book.title),
  ]
  let attrs = case is_deleting {
    True -> [
      attribute.disabled(True),
      attribute.attribute("aria-disabled", "true"),
      ..common
    ]
    False -> [event.on_click(ConfirmDelete(book.id)), ..common]
  }
  html.button(attrs, [html.text("×")])
}

/// Format a word count with thousands separators. The prototype's
/// `(122189).toLocaleString()` is what we're mirroring here —
/// `gleam_stdlib` has no localised number formatter, so we
/// hand-roll the comma every three digits.
fn format_word_count(count: Int) -> String {
  count
  |> int.to_string
  |> insert_thousands_separators
}

fn insert_thousands_separators(digits: String) -> String {
  digits
  |> string.to_graphemes
  |> list.reverse
  |> chunk_every_three([])
  |> list.map(fn(chunk) {
    chunk
    |> list.reverse
    |> string.concat
  })
  |> list.reverse
  |> string.join(",")
}

fn chunk_every_three(
  digits: List(String),
  acc: List(List(String)),
) -> List(List(String)) {
  case digits {
    [] -> list.reverse(acc)
    _ -> {
      let #(chunk, rest) = take_split(digits, 3, [])
      chunk_every_three(rest, [chunk, ..acc])
    }
  }
}

fn take_split(
  source: List(String),
  remaining: Int,
  acc: List(String),
) -> #(List(String), List(String)) {
  case remaining, source {
    0, _ -> #(list.reverse(acc), source)
    _, [] -> #(list.reverse(acc), [])
    _, [head, ..tail] -> take_split(tail, remaining - 1, [head, ..acc])
  }
}

fn view_add_book_fab() -> Element(Msg) {
  html.button(
    [
      attribute.class("fab"),
      attribute.type_("button"),
      attribute.aria_label("Add book"),
      event.on_click(ToggleAddBook),
    ],
    [html.text("+")],
  )
}

/// Add-book bottom sheet. Rendered as an overlay that catches taps
/// outside the sheet to close it (mirroring the settings panel's
/// scrim semantics). When `add_book_open` is `False`, the overlay
/// is absent from the DOM rather than hidden via CSS — keeps the
/// rendered tree small and the closed-state tests trivial.
fn view_add_book_sheet(model: Model) -> Element(Msg) {
  case model.add_book_open {
    False -> element.none()
    True ->
      html.div(
        [
          attribute.class("sheet-overlay open"),
          attribute.attribute("role", "dialog"),
          attribute.attribute("aria-modal", "true"),
          attribute.attribute("aria-label", "Add a book"),
          event.on_click(ToggleAddBook),
        ],
        [view_add_book_sheet_inner(model)],
      )
  }
}

fn view_add_book_sheet_inner(model: Model) -> Element(Msg) {
  let submit_disabled =
    model.paste_submitting
    || string.trim(model.paste_title) == ""
    || string.trim(model.paste_text) == ""

  let error_banner = case model.paste_error {
    None -> element.none()
    Some(message) ->
      html.div(
        [attribute.class("paste-error"), attribute.attribute("role", "alert")],
        [html.text(message)],
      )
  }

  html.div([attribute.class("bottom-sheet"), stop_click_propagation()], [
    html.div(
      [
        attribute.class("sheet-handle"),
        attribute.attribute("aria-hidden", "true"),
      ],
      [],
    ),
    html.div([attribute.class("add-sheet-body")], [
      html.div([attribute.class("add-sheet-title")], [html.text("Add a Book")]),
      html.div([attribute.class("add-sheet-sub")], [
        html.text("Paste text from anywhere to start reading."),
      ]),
      html.label([attribute.class("paste-label")], [html.text("Title")]),
      html.input([
        attribute.class("paste-input"),
        attribute.type_("text"),
        attribute.value(model.paste_title),
        attribute.attribute("placeholder", "Book title"),
        attribute.attribute("aria-label", "Book title"),
        event.on_input(SetPasteTitle),
      ]),
      html.label([attribute.class("paste-label")], [
        html.text("Paste your text"),
      ]),
      html.textarea(
        [
          attribute.class("paste-area"),
          attribute.attribute("placeholder", "Paste the text you want to read…"),
          attribute.attribute("aria-label", "Book text"),
          event.on_input(SetPasteText),
        ],
        model.paste_text,
      ),
      error_banner,
      html.button(
        [
          attribute.class("btn-add-book"),
          attribute.type_("button"),
          attribute.disabled(submit_disabled),
          attribute.aria_label("Add to library"),
          event.on_click(SubmitPaste),
        ],
        [
          html.text(case model.paste_submitting {
            True -> "Adding…"
            False -> "Add to Library"
          }),
        ],
      ),
    ]),
  ])
}
