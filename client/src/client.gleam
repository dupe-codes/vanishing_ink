//// Vanishing Ink Lustre client. Mounts the reader as a Model-View-
//// Update application on `#app` and renders a `SegmentedText` as
//// styled, span-per-word HTML so subsequent quests can hang
//// per-word/per-sentence interactivity off stable DOM addresses.
////
//// The scaffold loads a hardcoded sample text at init — the HTTP
//// client is intentionally absent (see the `gleam.toml` note on
//// `lustre_http`) so a later quest will replace the sample wiring with
//// a real server request without changing the message shape.

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

import client/sample
import shared/segmenter.{
  type Chapter, type Paragraph, type SegmentedText, type Sentence, type Word,
}

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

/// Top-level reader state. The loaded book lives here as an
/// `Option(SegmentedText)`: `None` before the sample has been
/// dispatched through the update loop, `Some(text)` afterwards.
pub type Model {
  Model(text: Option(SegmentedText))
}

/// Application messages. Currently just the loaded-text path —
/// extra variants (erase a sentence, change page, update a setting)
/// arrive with the quests that need them.
pub type Msg {
  /// A book has been segmented and is ready to render. Fired from
  /// `init` with the hardcoded sample today; will carry a server
  /// payload once the HTTP path is restored.
  TextLoaded(SegmentedText)
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
  let model = Model(text: None)

  // Dispatch the sample text through the update loop so the
  // `TextLoaded` wiring is exercised end-to-end. When the HTTP path
  // is restored this effect will be swapped for a real request that
  // dispatches the same message — keeping `init` and `update`
  // untouched.
  let load = effect.from(fn(dispatch) { dispatch(TextLoaded(sample.text())) })
  #(model, load)
}

pub fn update(_model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TextLoaded(text) -> #(Model(text: Some(text)), effect.none())
  }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  let body = case model.text {
    None -> view_placeholder()
    Some(text) -> view_text(text)
  }

  html.div([attribute.id("vi-shell"), attribute.class("reader")], [body])
}

fn view_placeholder() -> Element(Msg) {
  html.div([attribute.class("reader-placeholder")], [html.text("Loading...")])
}

fn view_text(text: SegmentedText) -> Element(Msg) {
  html.div(
    [attribute.class("reader-text")],
    list.map(text.chapters, view_chapter),
  )
}

fn view_chapter(chapter: Chapter) -> Element(Msg) {
  let title_element = case chapter.title {
    Some(title) ->
      html.h2([attribute.class("chapter-title")], [html.text(title)])
    None -> element.none()
  }

  let paragraphs = list.map(chapter.paragraphs, view_paragraph)

  html.section(
    [
      attribute.class("chapter"),
      attribute.attribute("data-chapter-index", int.to_string(chapter.index)),
    ],
    [title_element, ..paragraphs],
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
      // sentence drops the space — the inter-sentence separator above
      // owns that boundary instead.
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
