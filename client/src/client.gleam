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
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

import client/ffi
import client/pagination.{type Page, type PageParagraph}
import client/sample
import shared/segmenter.{
  type Paragraph, type SegmentedText, type Sentence, type Word,
}

// ---------------------------------------------------------------------------
// DOM selectors
// ---------------------------------------------------------------------------
//
// Centralised so the FFI calls in `update` and the element ids in
// `view` stay in lock-step. A drift here is the most plausible way
// the pagination engine can silently stop receiving measurements.

const measurement_container_selector: String = "#vi-measurement"

const page_content_selector: String = "#vi-page-content"

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

/// Top-level reader state.
///
/// * `text` — `None` before the sample (or a future server payload)
///   has been dispatched through the update loop, `Some(text)`
///   afterwards.
/// * `pages` — pre-calculated page boundaries. Empty between
///   `TextLoaded` and the first `ParagraphsMeasured`, and during a
///   resize while measurement is in flight.
/// * `current_page` — zero-based index into `pages`. Always clamped
///   into `[0, list.length(pages))` after a measurement.
/// * `viewport_height` — last measured `window.innerHeight`, kept on
///   the model so a future quest can react to size changes without
///   re-running FFI.
pub type Model {
  Model(
    text: Option(SegmentedText),
    pages: List(Page),
    current_page: Int,
    viewport_height: Float,
  )
}

/// Application messages.
pub type Msg {
  /// A book has been segmented and is ready to render. Fired from
  /// `init` with the hardcoded sample today; a future quest will
  /// dispatch the same message with a server payload.
  TextLoaded(SegmentedText)

  /// Browser paragraph heights have been read via FFI. Carries the
  /// `(global_index, height)` pairs alongside the latest viewport
  /// height and the available content-area height the pagination
  /// algorithm should fit pages into.
  ParagraphsMeasured(
    heights: List(#(Int, Float)),
    viewport_height: Float,
    available_height: Float,
  )

  /// Reader requested the next page (button or `ArrowRight`).
  NextPage

  /// Reader requested the previous page (button or `ArrowLeft`).
  PreviousPage

  /// Debounced `window.resize` fired. The handler re-runs the
  /// measurement effect — paragraph heights change with viewport
  /// width because of line wrapping.
  ViewportResized
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
    Model(text: None, pages: [], current_page: 0, viewport_height: 0.0)

  // Three independent boot effects: dispatch the sample text through
  // the update loop, install the debounced resize listener, and
  // install the arrow-key navigation listener. The listeners persist
  // for the lifetime of the page — they only need to fire once at
  // boot.
  let load = effect.from(fn(dispatch) { dispatch(TextLoaded(sample.text())) })
  let resize_listener =
    effect.from(fn(dispatch) {
      ffi.on_resize(fn() { dispatch(ViewportResized) })
    })
  let keyboard_listener =
    effect.from(fn(dispatch) {
      ffi.on_arrow_key(
        previous_callback: fn() { dispatch(PreviousPage) },
        next_callback: fn() { dispatch(NextPage) },
      )
    })

  #(model, effect.batch([load, resize_listener, keyboard_listener]))
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TextLoaded(text) -> #(
      Model(..model, text: Some(text), pages: [], current_page: 0),
      measure_after_paint(),
    )

    ParagraphsMeasured(heights, viewport_height, available_height) -> {
      let pages = case model.text {
        None -> []
        Some(text) ->
          pagination.calculate_pages(
            pagination.flatten(text),
            pagination.heights_from_pairs(heights),
            available_height,
          )
      }
      let total = list.length(pages)
      let clamped = pagination.clamp_page_index(model.current_page, total)
      #(
        Model(
          ..model,
          pages: pages,
          current_page: clamped,
          viewport_height: viewport_height,
        ),
        effect.none(),
      )
    }

    NextPage -> {
      let total = list.length(model.pages)
      let next = pagination.clamp_page_index(model.current_page + 1, total)
      #(Model(..model, current_page: next), effect.none())
    }

    PreviousPage -> {
      let total = list.length(model.pages)
      let prev = pagination.clamp_page_index(model.current_page - 1, total)
      #(Model(..model, current_page: prev), effect.none())
    }

    ViewportResized -> #(model, measure_after_paint())
  }
}

/// Schedule an `after_paint` effect that reads paragraph heights and
/// the available content-area height from the live DOM, then
/// dispatches `ParagraphsMeasured`. Falls back to `viewport_height`
/// when the page-content sentinel cannot be located so pagination
/// still produces output rather than getting wedged.
fn measure_after_paint() -> Effect(Msg) {
  effect.after_paint(fn(dispatch, _root) {
    let viewport_height = ffi.get_viewport_height()
    let available_height = case ffi.get_element_height(page_content_selector) {
      Ok(height) -> height
      Error(_) -> viewport_height
    }
    let heights = ffi.measure_paragraphs(measurement_container_selector)
    dispatch(ParagraphsMeasured(
      heights: heights,
      viewport_height: viewport_height,
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
    Some(text) -> view_paginated(text, model.pages, model.current_page)
  }

  html.div([attribute.id("vi-shell"), attribute.class("reader")], [body])
}

fn view_placeholder() -> Element(Msg) {
  html.div([attribute.class("reader-placeholder")], [html.text("Loading...")])
}

fn view_paginated(
  text: SegmentedText,
  pages: List(Page),
  current_page: Int,
) -> Element(Msg) {
  let flat = pagination.flatten(text)
  let total = list.length(pages)
  let visible = case pagination.nth(pages, current_page) {
    Some(page) -> view_page(page)
    None -> view_preparing()
  }

  html.div([attribute.class("reader-text")], [
    html.div([attribute.id("vi-reading-area"), attribute.class("reader-page")], [
      html.div(
        [
          attribute.id("vi-page-content"),
          attribute.class("reader-page-content"),
        ],
        [visible],
      ),
    ]),
    view_page_indicator(total, current_page),
    view_measurement_container(flat),
  ])
}

fn view_preparing() -> Element(Msg) {
  html.div([attribute.class("reader-preparing")], [
    html.text("Preparing pages..."),
  ])
}

fn view_page(page: Page) -> Element(Msg) {
  html.div(
    [
      attribute.class("page"),
      attribute.attribute("data-page-index", int.to_string(page.index)),
    ],
    list.map(page.paragraphs, view_page_paragraph),
  )
}

fn view_page_indicator(total: Int, current: Int) -> Element(Msg) {
  case total {
    0 -> element.none()
    _ ->
      html.div(
        [
          attribute.id("vi-page-indicator"),
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
  html.div(
    [
      attribute.id("vi-measurement"),
      attribute.class("reader-measurement"),
      attribute.attribute("aria-hidden", "true"),
    ],
    list.map(paragraphs, view_page_paragraph),
  )
}

fn view_page_paragraph(page_paragraph: PageParagraph) -> Element(Msg) {
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
    [title_element, view_paragraph(page_paragraph.paragraph)],
  )
}

fn view_paragraph(paragraph: Paragraph) -> Element(Msg) {
  // A literal " " text node between sentences keeps the gap visible
  // when each sentence's last word omits its trailing space.
  let sentence_elements =
    paragraph.sentences
    |> list.map(view_sentence)
    |> list.intersperse(html.text(" "))

  html.p([attribute.class("paragraph")], sentence_elements)
}

fn view_sentence(sentence: Sentence) -> Element(Msg) {
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

  html.span(
    [
      attribute.class("sentence"),
      attribute.attribute(
        "data-sentence-index",
        int.to_string(sentence.global_index),
      ),
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
