//// Application-state types and compile-time constants. This module
//// sits at the foundation of the client's dependency graph: it
//// depends only on `client/types`, `client/pagination`, and
//// `shared/segmenter`, and is imported by every other client module
//// that touches the model.
////
//// The pure model-mutation helpers (`go_to_page`, `change_page`,
//// `total_counts`, `progress_percentage`, `compute_current_chapter_title`,
//// `chapter_title_at`, `clamp_int`, `clamp_float`, `erased_opacity_value`)
//// live in the sibling `client/state/helpers` module so this file
//// stays within the 800-line file budget.
////
//// **Cached-field invariant.** Several `Model` fields are caches over
//// other fields; the reducer is responsible for keeping them in
//// lock-step:
////
//// * Writing `pages` requires writing `total_pages`
////   (`total_pages == list.length(pages)`).
//// * Writing `current_page` requires writing
////   `current_chapter_title` (refresh via
////   `compute_current_chapter_title` from `client/state/helpers`).
//// * Writing `text` requires writing `total_sentence_count` /
////   `total_word_count` (refresh via `total_counts` from
////   `client/state/helpers`).
////
//// The pure helpers in `client/state/helpers` (`go_to_page`,
//// `change_page`) refresh the cached fields as they mutate, so
//// callers that go through those helpers do not need to worry about
//// drift. Direct `Model(..model, pages: ...)` updates in the reducer
//// must mirror the invariant by hand.

import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/set.{type Set}
import gleam/string

import client/pagination.{type Page, type PageParagraph}
import client/types.{
  type BookMeta, type BookSettings, type UserSettings, BookSettings,
  UserSettings,
}
import shared/segmenter.{type SegmentedText}

// ---------------------------------------------------------------------------
// Undo
// ---------------------------------------------------------------------------

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
pub const ms_per_minute: Int = 60_000

/// Compile-time fallback `UserSettings` used to seed `Model.global_defaults`
/// before the `SettingsLoaded` round trip lands. The values mirror the
/// server's `user_settings` column defaults so a fresh boot — even one
/// where the server response is delayed — applies the same baseline the
/// persisted record would surface. `dark_mode` is the only field whose
/// runtime seed (`prefers-color-scheme`) differs from the server default;
/// the caller supplies the OS preference at construction time so the
/// in-memory baseline matches the rendered theme until the server
/// response overwrites both.
pub fn fallback_user_settings(dark_mode: Bool) -> UserSettings {
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
pub fn empty_book_settings() -> BookSettings {
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
// Centralised so the FFI calls in the reducer and the `attribute.id(...)`
// calls in the view stay in lock-step. A drift here is the most
// plausible way the pagination engine can silently stop receiving
// measurements. Selector strings ("#vi-...") are built at the call
// site by prepending `"#"` so the selector form cannot diverge from
// the attribute form.

pub const reading_area_id: String = "vi-reading-area"

pub const page_content_id: String = "vi-page-content"

pub const measurement_id: String = "vi-measurement"

// ---------------------------------------------------------------------------
// CSS custom property and body-class names
// ---------------------------------------------------------------------------
//
// Mirrors the names declared in `assets/styles.css`. Defining them as
// constants on the Gleam side keeps the FFI calls in the reducer and
// the CSS rules from drifting apart: a rename in the stylesheet means
// a rename here, and the failure mode is a Gleam compile error rather
// than a silently broken setting.

pub const css_var_font_size: String = "--vi-base-font-size"

pub const css_var_line_height: String = "--vi-line-height"

pub const css_var_ghost_opacity: String = "--vi-ghost-opacity"

pub const body_class_light_mode: String = "vi-light-mode"

pub const body_class_ghost_mode: String = "vi-ghost-mode"

pub const body_class_dyslexia_font: String = "vi-dyslexia-font"

pub const body_class_reduced_motion: String = "vi-reduced-motion"

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

/// One chapter's position in the paginated book. `title` is the
/// chapter title taken from the segmenter's `Chapter.title` (callers
/// drop chapters whose title is `None` — those land on the reader's
/// menu only as page numbers, not as a named entry). `page_index` is
/// the zero-based index of the page on which the chapter's first
/// paragraph lives. Used by the Jump Ahead menu to render forward
/// chapters as tappable rows.
pub type ChapterEntry {
  ChapterEntry(title: String, page_index: Int)
}

/// Snapshot of pre-jump reader state, captured at the moment the
/// reader taps a chapter / page row in the Jump Ahead menu. Held on
/// `Model.jump_preview` while the reader is previewing the target
/// page; `LockInJump` discards it (the jump commits, undoing back to
/// the original page is no longer offered) and `UndoJump` restores
/// each field onto the model.
///
/// The three fields are exactly the model state Jump Ahead mutates:
///
/// * `source_page` — where the reader was when the jump started, so
///   `UndoJump` lands them back on the same page.
/// * `prior_engine_state` — the fade engine's lifecycle state at the
///   moment of the jump. The jump pauses the engine for the preview
///   so the reader can inspect the page without words fading out
///   underneath them; lock-in / undo restore the prior state.
/// * `prior_next_word_index` — the word the engine would have faded
///   next, paired with `prior_engine_state` so the engine resumes at
///   the same word on undo. `Running` engines always carry
///   `Some(_)` here (see the `Running, None` panic in
///   `engine.apply_advance_word`), and the snapshot mirrors that
///   invariant.
pub type JumpPreview {
  JumpPreview(
    source_page: Int,
    prior_engine_state: EngineState,
    prior_next_word_index: Option(Int),
  )
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
/// * `paste_warning` — `Some(message)` when the ePub import
///   succeeded but skipped one or more spine sections;
///   `None` otherwise. Distinct from `paste_error` so the view
///   can render it with `role="status"` rather than `role="alert"`
///   — a partial-success import should not announce as a failure
///   to screen readers, and the visual treatment is non-error
///   (muted surface, no accent border). Cleared on every action
///   that begins a fresh import attempt or that supersedes the
///   prior import (file pick, opening the sheet, typing in the
///   title / text inputs, successful POST, failed POST).
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
    paste_warning: Option(String),
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
    /// `True` while the Jump Ahead modal is visible. `ToggleJumpMenu`
    /// flips it. Opening fires no fetch — the chapter list lives on
    /// `chapter_entries`, which is refreshed whenever pagination runs.
    /// Closing the menu while a preview is in flight is independent of
    /// the preview's lifecycle: the modal is dismissed without
    /// committing, but the reader stays on the previewed page until
    /// they tap Lock In or Go Back. Holding the modal closed during
    /// preview keeps the scrim/sheet markup off the DOM so the bottom
    /// banner is unobstructed.
    jump_menu_open: Bool,
    /// `Some(_)` while the reader is previewing a target page from
    /// the Jump Ahead menu; `None` otherwise. The snapshot is the
    /// pre-jump position, engine state, and word pointer — exactly
    /// what `UndoJump` needs to restore, and exactly what
    /// `LockInJump` discards.
    jump_preview: Option(JumpPreview),
    /// Forward-only chapter list rendered by the Jump Ahead menu.
    /// Refreshed whenever pagination changes (`ParagraphsMeasured`)
    /// or the current page advances, so opening the menu sees an
    /// up-to-date "chapters after where I am" list. Entries are
    /// strictly ahead of `current_page` — backward navigation is
    /// disabled across the app, and showing already-visited
    /// chapters in this menu would invite a tap that the reducer
    /// would silently reject.
    chapter_entries: List(ChapterEntry),
  )
}
