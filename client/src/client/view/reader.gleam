//// Reader view. Sticky header, reading-progress bar, paginated
//// content, mode-aware bottom bar, off-screen measurement container,
//// and the active-line overlay that the fade engine anchors against.
////
//// The chrome rows (`view_reader_header`, `view_progress_bar`,
//// `view_bottom_bar`) flank the central `.reader-page` so the
//// reading area is the flex-grow child between two `flex: 0 0 auto`
//// frames. The header carries the back glyph, current book title,
//// and settings gear; the bottom bar swaps shape with `model.mode`
//// — Manual gets undo / page indicator / turn-page, RealTime gets
//// WPM readout / play-pause / spacer.
////
//// The `#vi-measurement` container receives all paragraphs from the
//// whole book — not just the current page. This lets
//// `measure_after_paint` read every paragraph height in a single DOM
//// pass after `TextLoaded` or `ViewportResized`, rather than
//// re-measuring on every page turn.
////
//// Touch handlers are placed on `.reader-page` rather than the outer
//// `.reader-text` so neither the chrome rows nor the off-screen
//// measurement container can intercept page swipes. The measurement
//// container is `pointer-events: none` (see `.reader-measurement` in
//// `styles.css`) so its descendants cannot receive any touch or
//// click events.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/gestures
import client/msg.{
  type Msg, EraseSentence, GoToLibrary, NextPage, PauseFade, ResumeFade,
  StartFade, ToggleSettings, TouchCancel, TouchEnd, TouchStart, Undo,
}
import client/pagination.{type Page, type PageParagraph}
import client/state.{
  type LineBox, type Mode, type Model, Manual, Paused, RealTime, Running,
  Stopped, erased_opacity_value, measurement_id, page_content_id,
  progress_percentage, reading_area_id,
}
import shared/segmenter.{type Paragraph, type Sentence, type Word}

/// Reader-view body. Renders a loading placeholder until a
/// `BookLoaded` (or, in tests, a `TextLoaded`) lands on the model,
/// then delegates to `view_paginated`.
pub fn view(model: Model) -> Element(Msg) {
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
