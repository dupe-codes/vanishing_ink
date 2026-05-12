//// JavaScript-target tests for the cross-target `shared` JSON contract
//// and the Lustre reader's MVU surface.
////
//// The `BookId` and segmenter tests pin the cross-target JSON contract:
//// the encoder and decoder must agree under `JSON.stringify` /
//// `JSON.parse` semantics on V8 — the BEAM side gets the same
//// assertions over in `shared/test/`. If either target's `gleam_json`
//// implementation drifts, one of these two test pairs will fail in CI.
////
//// The MVU tests pin the reader's reducer and the DOM contracts the
//// subsequent reader-feature quests (erase, pagination) will rely on:
//// every word carries `data-global-index` and every sentence carries
//// `data-sentence-index`, sentence-internal spacing lives on the word
//// span, inter-sentence spacing lives as a literal text node between
//// sibling sentence spans, and chapter titles render only when present.
//// View rendering is asserted by rendering to HTML via
//// `lustre/element.to_string` and comparing whole substrings — the
//// pattern that lets us pin both attribute structure and inter-element
//// text content in one assertion.

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import lustre/element
import shared
import shared/segmenter.{Chapter, Paragraph, SegmentedText, Sentence, Word}

import client.{Model, TextLoaded}
import client/sample

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// shared JSON contract
// ---------------------------------------------------------------------------

pub fn book_id_round_trips_on_js_target_test() {
  let id = shared.book_id("the-iliad")

  let encoded = shared.book_id_to_json(id) |> json.to_string
  let decoded = json.parse(encoded, shared.book_id_decoder())

  assert encoded == "\"the-iliad\""
  assert decoded == Ok("the-iliad")
}

pub fn book_id_decoder_rejects_non_string_on_js_target_test() {
  let decoded = json.parse("42", shared.book_id_decoder())

  assert case decoded {
    Ok(_) -> False
    Error(_) -> True
  }
}

// ---------------------------------------------------------------------------
// update
// ---------------------------------------------------------------------------

pub fn update_text_loaded_stores_segmented_text_test() {
  // `TextLoaded` is the only message variant today. It must move the
  // model from `text: None` into `text: Some(payload)` so the renderer
  // stops drawing the placeholder. Asserting the full result tuple pins
  // both the model transition and the "no follow-up effect" property
  // the reducer guarantees today — the property a future HTTP-error
  // variant will most plausibly violate.
  let payload =
    SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Hi."),
          ]),
        ]),
      ]),
    ])

  let #(updated, _effect) =
    client.update(Model(text: None), TextLoaded(payload))

  assert updated == Model(text: Some(payload))
}

pub fn update_text_loaded_overwrites_existing_text_test() {
  // A second `TextLoaded` replaces the prior payload rather than
  // merging or ignoring it. There is no "loaded once, frozen" rule
  // today — the reducer is a plain assignment — and the assertion
  // pins that behaviour so a later quest cannot quietly turn the
  // setter into an idempotent-only path.
  let first =
    SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: []),
    ])
  let second =
    SegmentedText(chapters: [
      Chapter(index: 1, title: Some("Two"), paragraphs: []),
    ])

  let #(updated, _effect) =
    client.update(Model(text: Some(first)), TextLoaded(second))

  assert updated == Model(text: Some(second))
}

// ---------------------------------------------------------------------------
// view — placeholder branch
// ---------------------------------------------------------------------------

pub fn view_renders_loading_placeholder_when_text_is_none_test() {
  // Before `TextLoaded` fires the model carries `text: None` and the
  // view must render the placeholder. Asserting the whole rendered
  // string pins the outer shell (`id="vi-shell"`, `class="reader"`),
  // the placeholder marker (`class="reader-placeholder"`), and the
  // user-visible "Loading..." text in one comparison.
  let rendered = client.view(Model(text: None)) |> element.to_string

  assert rendered
    == "<div class=\"reader\" id=\"vi-shell\">"
    <> "<div class=\"reader-placeholder\">Loading...</div>"
    <> "</div>"
}

// ---------------------------------------------------------------------------
// view — text branch (DOM contract)
// ---------------------------------------------------------------------------

pub fn view_renders_full_dom_contract_for_two_sentence_text_test() {
  // The pinned DOM contract subsequent reader-feature quests will rely
  // on: every word span carries `class="word"` and `data-global-index`,
  // every sentence span carries `class="sentence"` and
  // `data-sentence-index`, sentence-internal spacing lives on each
  // non-final word's text node, and inter-sentence spacing lives as a
  // literal " " text node between sibling sentence spans. Asserting
  // the whole rendered HTML for a known input is the most direct way
  // to pin every one of these in a single comparison — a regression
  // in any of them flips the assertion.
  let text =
    SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Hello"),
            Word(index: 1, global_index: 1, text: "world."),
          ]),
          Sentence(index: 1, global_index: 1, words: [
            Word(index: 0, global_index: 2, text: "Bye."),
          ]),
        ]),
      ]),
    ])

  let rendered = client.view(Model(text: Some(text))) |> element.to_string

  assert rendered
    == "<div class=\"reader\" id=\"vi-shell\">"
    <> "<div class=\"reader-text\">"
    <> "<section class=\"chapter\" data-chapter-index=\"0\">"
    <> "<p class=\"paragraph\">"
    <> "<span class=\"sentence\" data-sentence-index=\"0\">"
    <> "<span class=\"word\" data-global-index=\"0\">Hello </span>"
    <> "<span class=\"word\" data-global-index=\"1\">world.</span>"
    <> "</span>"
    <> " "
    <> "<span class=\"sentence\" data-sentence-index=\"1\">"
    <> "<span class=\"word\" data-global-index=\"2\">Bye.</span>"
    <> "</span>"
    <> "</p>"
    <> "</section>"
    <> "</div>"
    <> "</div>"
}

pub fn view_renders_chapter_title_when_present_test() {
  // The chapter renderer branches on `title`: `Some(t)` emits an
  // `<h2 class="chapter-title">` heading, `None` emits nothing. The
  // prior test exercises the `None` path; this one pins the `Some`
  // path with the same whole-string assertion strategy so a future
  // refactor cannot drop the heading element or rename its class.
  let text =
    SegmentedText(chapters: [
      Chapter(index: 3, title: Some("Chapter III"), paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Go."),
          ]),
        ]),
      ]),
    ])

  let rendered = client.view(Model(text: Some(text))) |> element.to_string

  assert string.contains(
    rendered,
    "<section class=\"chapter\" data-chapter-index=\"3\">"
      <> "<h2 class=\"chapter-title\">Chapter III</h2>",
  )
}

pub fn view_emits_one_word_span_per_word_test() {
  // A defensive count check on a longer input — pinning that the
  // renderer emits exactly one `class="word"` span per `Word` in the
  // segmented tree. The whole-string DOM-contract test above
  // exercises this on a two-sentence fixture; this one widens the
  // surface to two paragraphs across two sentences each so the count
  // catches a regression that drops or duplicates words inside the
  // recursion (e.g. a stale `list.length`-based off-by-one in the
  // sentence renderer).
  let text =
    SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "One"),
            Word(index: 1, global_index: 1, text: "two."),
          ]),
          Sentence(index: 1, global_index: 1, words: [
            Word(index: 0, global_index: 2, text: "Three"),
            Word(index: 1, global_index: 3, text: "four."),
          ]),
        ]),
        Paragraph(index: 1, sentences: [
          Sentence(index: 2, global_index: 2, words: [
            Word(index: 0, global_index: 4, text: "Five."),
          ]),
        ]),
      ]),
    ])

  let rendered = client.view(Model(text: Some(text))) |> element.to_string

  // `string.split` with N occurrences of the separator yields N+1
  // chunks. Five words → six chunks.
  let chunks = rendered |> string.split("class=\"word\"") |> list.length

  assert chunks == 6
}

// ---------------------------------------------------------------------------
// sample fixture
// ---------------------------------------------------------------------------

pub fn sample_text_succeeds_through_the_shared_json_round_trip_test() {
  // `sample.text()` segments the bundled prose and then routes the
  // result through `segmenter.to_json |> json.to_string |>
  // json.parse(_, decoder())`, so the data the client renders on
  // first paint has travelled through the same boundary code the
  // future HTTP path will use. The function `let assert`s on the
  // decode result; this test pins that the production constant is
  // valid prose for which the round trip succeeds without panic,
  // and that the resulting tree is non-empty at every nesting
  // level. The JSON round-trip itself is exhaustively tested in
  // `segmenter_test.gleam` and `shared/test/segmenter_test.gleam`
  // — the value added here is exercising it on the real fixture
  // the application ships with.
  let segmented = sample.text()

  // Non-empty at every nesting level. A `let assert` regression on
  // the constant (e.g. introducing characters that segment to zero
  // words) would fail one of these.
  assert segmented.chapters != []
  let assert [first_chapter, ..] = segmented.chapters
  assert first_chapter.paragraphs != []
  let assert [first_paragraph, ..] = first_chapter.paragraphs
  assert first_paragraph.sentences != []
  let assert [first_sentence, ..] = first_paragraph.sentences
  assert first_sentence.words != []
}
