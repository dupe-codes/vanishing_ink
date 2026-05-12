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

const page_indicator_id: String = "vi-page-indicator"

const measurement_id: String = "vi-measurement"

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
pub type Model {
  Model(
    text: Option(SegmentedText),
    flat_paragraphs: List(PageParagraph),
    pages: List(Page),
    current_page: Int,
    erased: Set(Int),
    undo_stack: List(Int),
    touch_start: Option(#(Float, Float)),
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
  let model =
    Model(
      text: None,
      flat_paragraphs: [],
      pages: [],
      current_page: 0,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
    )

  // Four independent boot effects: dispatch the sample text through
  // the update loop, install the debounced resize listener, the
  // arrow-key navigation listener, and the platform-undo key
  // listener. The listeners persist for the lifetime of the page —
  // they only need to fire once at boot.
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

  #(model, effect.batch([load, resize_listener, arrow_listener, undo_listener]))
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TextLoaded(text) -> #(
      Model(
        text: Some(text),
        flat_paragraphs: pagination.flatten(text),
        pages: [],
        current_page: 0,
        erased: set.new(),
        undo_stack: [],
        touch_start: None,
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

    EraseSentence(global_index) -> {
      case set.contains(model.erased, global_index) {
        True -> #(model, effect.none())
        False -> {
          let next_erased = set.insert(model.erased, global_index)
          let next_undo =
            [global_index, ..model.undo_stack] |> list.take(undo_stack_depth)
          #(
            Model(..model, erased: next_erased, undo_stack: next_undo),
            effect.none(),
          )
        }
      }
    }

    Undo -> {
      case model.undo_stack {
        [] -> #(model, effect.none())
        [last, ..rest] -> {
          let next_erased = set.delete(model.erased, last)
          #(
            Model(..model, erased: next_erased, undo_stack: rest),
            effect.none(),
          )
        }
      }
    }

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
                [last, ..rest] -> {
                  let next_erased = set.delete(cleared.erased, last)
                  #(
                    Model(..cleared, erased: next_erased, undo_stack: rest),
                    effect.none(),
                  )
                }
              }
          }
      }
    }
  }
}

/// Move the reader to `candidate` after clamping to the current
/// `pages` range. Clears `undo_stack` only when `clamped` differs
/// from `current_page` — a real page change commits every erase
/// that has not yet been undone, but a clamp-to-self (ArrowRight on
/// the last page, ArrowLeft on the first) must leave the undo stack
/// intact so a reader's stray reflex tap does not silently destroy
/// erases that were undoable a moment earlier.
fn go_to_page(model: Model, candidate: Int) -> Model {
  let total = list.length(model.pages)
  let clamped = pagination.clamp_page_index(candidate, total)
  let undo_stack = case clamped == model.current_page {
    True -> model.undo_stack
    False -> []
  }
  Model(..model, current_page: clamped, undo_stack: undo_stack)
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

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  let body = case model.text {
    None -> view_placeholder()
    Some(_) ->
      view_paginated(
        model.flat_paragraphs,
        model.pages,
        model.current_page,
        model.erased,
      )
  }

  html.div([attribute.id("vi-shell"), attribute.class("reader")], [body])
}

fn view_placeholder() -> Element(Msg) {
  html.div([attribute.class("reader-placeholder")], [html.text("Loading...")])
}

fn view_paginated(
  flat_paragraphs: List(PageParagraph),
  pages: List(Page),
  current_page: Int,
  erased: Set(Int),
) -> Element(Msg) {
  let total = list.length(pages)
  let visible = case pagination.nth(pages, current_page) {
    Some(page) -> view_page(page, erased)
    None -> view_preparing()
  }

  // Touch gesture handlers live on `.reader-page` rather than on the
  // outer `.reader-text` so the page-indicator's own taps don't
  // accidentally register as page swipes. The measurement container
  // is `pointer-events: none`, so its descendants never receive
  // touch events even though it's a child of `.reader-text`.
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
    view_page_indicator(total, current_page),
    view_measurement_container(flat_paragraphs),
  ])
}

fn view_preparing() -> Element(Msg) {
  html.div([attribute.class("reader-preparing")], [
    html.text("Preparing pages..."),
  ])
}

fn view_page(page: Page, erased: Set(Int)) -> Element(Msg) {
  html.div(
    [
      attribute.class("page"),
      attribute.attribute("data-page-index", int.to_string(page.index)),
    ],
    list.map(page.paragraphs, fn(p) { view_page_paragraph(p, erased) }),
  )
}

fn view_page_indicator(total: Int, current: Int) -> Element(Msg) {
  case total {
    0 -> element.none()
    _ ->
      html.div(
        [
          attribute.id(page_indicator_id),
          attribute.class("reader-page-indicator"),
        ],
        [
          html.text(
            "Page "
            <> int.to_string(current + 1)
            <> " of "
            <> int.to_string(total),
          ),
        ],
      )
  }
}

fn view_measurement_container(paragraphs: List(PageParagraph)) -> Element(Msg) {
  // Off-screen mirror of the visible reading area. Carries the same
  // class hierarchy (`reader-text` → paragraph spans) so paragraph
  // line-wrap heights match what the visible page will render. CSS
  // hides it from layout flow (`position: absolute; visibility:
  // hidden`) without removing it from the DOM, so
  // `getBoundingClientRect().height` still reports valid pixel
  // values to the FFI.
  //
  // The measurement mirror is always rendered with an empty erase
  // map: opacity 0 doesn't affect `getBoundingClientRect().height`,
  // so the visual state never reaches the DOM here regardless, but
  // emitting the erase styles into a `pointer-events: none` subtree
  // would also confuse any DOM query that didn't scope to
  // `#vi-page-content` (the briefing flags this footgun explicitly).
  html.div(
    [
      attribute.id(measurement_id),
      attribute.class("reader-measurement"),
      attribute.attribute("aria-hidden", "true"),
    ],
    list.map(paragraphs, fn(p) { view_page_paragraph(p, set.new()) }),
  )
}

fn view_page_paragraph(
  page_paragraph: PageParagraph,
  erased: Set(Int),
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
    [title_element, view_paragraph(page_paragraph.paragraph, erased)],
  )
}

fn view_paragraph(
  paragraph: Paragraph,
  erased: Set(Int),
) -> Element(Msg) {
  // A literal " " text node between sentences keeps the gap visible
  // when each sentence's last word omits its trailing space.
  let sentence_elements =
    paragraph.sentences
    |> list.map(fn(s) { view_sentence(s, erased) })
    |> list.intersperse(html.text(" "))

  html.p([attribute.class("paragraph")], sentence_elements)
}

fn view_sentence(sentence: Sentence, erased: Set(Int)) -> Element(Msg) {
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
  let erase_attrs = case is_erased {
    True -> [attribute.style("opacity", "0")]
    False -> []
  }

  // `on_click` covers both desktop clicks and mobile-synthesized
  // taps. The synthesized click only fires when the touch movement
  // stays below the browser's own click-cancellation threshold (~10
  // –15px), which is well under `gestures.swipe_threshold`, so a
  // real swipe never lands an accidental erase.
  let base_attrs = [
    attribute.class("sentence"),
    attribute.attribute(
      "data-sentence-index",
      int.to_string(sentence.global_index),
    ),
    event.on_click(EraseSentence(sentence.global_index)),
  ]

  html.span(list.append(base_attrs, erase_attrs), words)
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
