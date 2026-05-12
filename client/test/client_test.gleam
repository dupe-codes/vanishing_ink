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
//// subsequent reader-feature quests (erase, etc.) will rely on:
//// every word carries `data-global-index`, every sentence carries
//// `data-sentence-index`, every paginated paragraph carries
//// `data-paragraph-global-index`, the off-screen measurement
//// container mirrors the visible reading area so paragraph heights
//// reflect what the reader will see, and the page indicator reads
//// `Page N of M` with a one-based current page. View rendering is
//// asserted by rendering to HTML via `lustre/element.to_string` and
//// comparing whole substrings — the pattern that lets us pin both
//// attribute structure and inter-element text content in one
//// assertion.

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import lustre/element
import shared
import shared/segmenter.{
  type SegmentedText, Chapter, Paragraph, SegmentedText, Sentence, Word,
}

import client.{
  type Model, Model, NextPage, ParagraphsMeasured, PreviousPage, TextLoaded,
  ViewportResized,
}
import client/pagination.{Page}
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
// fixtures
// ---------------------------------------------------------------------------

fn empty_model() -> Model {
  Model(text: None, pages: [], current_page: 0, viewport_height: 0.0)
}

fn two_chapter_text() -> SegmentedText {
  SegmentedText(chapters: [
    Chapter(index: 0, title: None, paragraphs: [
      Paragraph(index: 0, sentences: [
        Sentence(index: 0, global_index: 0, words: [
          Word(index: 0, global_index: 0, text: "Hello"),
          Word(index: 1, global_index: 1, text: "world."),
        ]),
      ]),
      Paragraph(index: 1, sentences: [
        Sentence(index: 1, global_index: 1, words: [
          Word(index: 0, global_index: 2, text: "Second"),
          Word(index: 1, global_index: 3, text: "para."),
        ]),
      ]),
    ]),
    Chapter(index: 1, title: Some("Two"), paragraphs: [
      Paragraph(index: 0, sentences: [
        Sentence(index: 2, global_index: 2, words: [
          Word(index: 0, global_index: 4, text: "Third."),
        ]),
      ]),
    ]),
  ])
}

// ---------------------------------------------------------------------------
// update — TextLoaded
// ---------------------------------------------------------------------------

pub fn update_text_loaded_stores_segmented_text_and_resets_pagination_test() {
  // `TextLoaded` must (a) move `text: None` into `text: Some(payload)`
  // so the renderer stops drawing the placeholder, and (b) reset the
  // paginated view state — empty pages, current_page back to 0. The
  // follow-up `ParagraphsMeasured` from the after_paint effect is
  // what fills `pages` in, so the immediate post-`TextLoaded` state
  // is "text loaded, pagination pending". Asserting on the full
  // model pins both transitions in one place.
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

  let #(updated, _effect) = client.update(empty_model(), TextLoaded(payload))

  assert updated
    == Model(
      text: Some(payload),
      pages: [],
      current_page: 0,
      viewport_height: 0.0,
    )
}

pub fn update_text_loaded_overwrites_existing_text_and_resets_pagination_test() {
  // A second `TextLoaded` replaces the prior payload rather than
  // merging it; it also resets `pages` and `current_page` so the
  // reader cannot land on a stale page index from the prior book
  // while measurement of the new payload is in flight.
  let first =
    SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: []),
    ])
  let second =
    SegmentedText(chapters: [
      Chapter(index: 1, title: Some("Two"), paragraphs: []),
    ])
  let prior =
    Model(
      text: Some(first),
      pages: [Page(index: 0, paragraphs: [])],
      current_page: 0,
      viewport_height: 800.0,
    )

  let #(updated, _effect) = client.update(prior, TextLoaded(second))

  assert updated
    == Model(
      text: Some(second),
      pages: [],
      current_page: 0,
      viewport_height: 800.0,
    )
}

// ---------------------------------------------------------------------------
// update — ParagraphsMeasured
// ---------------------------------------------------------------------------

pub fn update_paragraphs_measured_calculates_pages_from_text_test() {
  // With text loaded, `ParagraphsMeasured` runs the pagination
  // engine and stores the resulting page boundaries on the model.
  // Three 100px paragraphs into a 250px budget pack as 2 + 1; this
  // pin catches a regression in either the wiring (heights or
  // budget dropped from the message) or the pagination algorithm
  // (greedy fit broken).
  let text = two_chapter_text()
  let prior = Model(..empty_model(), text: Some(text))
  let heights = [#(0, 100.0), #(1, 100.0), #(2, 100.0)]

  let #(updated, _effect) =
    client.update(
      prior,
      ParagraphsMeasured(
        heights: heights,
        viewport_height: 600.0,
        available_height: 250.0,
      ),
    )

  assert list.length(updated.pages) == 2
  assert updated.viewport_height == 600.0
  assert updated.current_page == 0
}

pub fn update_paragraphs_measured_clamps_current_page_into_new_total_test() {
  // A resize shrinks the page budget and the document repaginates
  // to fewer pages. The reader's `current_page` must clamp down so
  // the visible page index is valid for the new `pages` length —
  // otherwise the view would try to render a page that no longer
  // exists and fall through to the "preparing" branch.
  let text = two_chapter_text()
  let prior = Model(..empty_model(), text: Some(text), current_page: 5)

  // 25px budget forces one paragraph per page → 3 pages total.
  let heights = [#(0, 100.0), #(1, 100.0), #(2, 100.0)]
  let #(updated, _effect) =
    client.update(
      prior,
      ParagraphsMeasured(
        heights: heights,
        viewport_height: 300.0,
        available_height: 25.0,
      ),
    )

  assert list.length(updated.pages) == 3
  assert updated.current_page == 2
}

pub fn update_paragraphs_measured_with_no_text_produces_no_pages_test() {
  // Defensive: a measurement that arrives while `text` is still
  // `None` (in practice impossible without a future bug) must not
  // panic; the reducer just records the viewport and leaves pages
  // empty so the view stays on the loading placeholder.
  let #(updated, _effect) =
    client.update(
      empty_model(),
      ParagraphsMeasured(
        heights: [],
        viewport_height: 420.0,
        available_height: 380.0,
      ),
    )

  assert updated.pages == []
  assert updated.viewport_height == 420.0
}

// ---------------------------------------------------------------------------
// update — NextPage / PreviousPage
// ---------------------------------------------------------------------------

pub fn update_next_page_advances_one_when_not_on_last_page_test() {
  let prior =
    Model(
      ..empty_model(),
      pages: [
        Page(index: 0, paragraphs: []),
        Page(index: 1, paragraphs: []),
        Page(index: 2, paragraphs: []),
      ],
      current_page: 0,
    )

  let #(updated, _effect) = client.update(prior, NextPage)

  assert updated.current_page == 1
}

pub fn update_next_page_holds_on_last_page_test() {
  // Bounds: NextPage is a no-op when the reader is already on the
  // last page. The pinned behaviour is "stop", not "wrap". A future
  // quest that wants wrap-around will need a new message variant
  // rather than redefining this one.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 1,
    )

  let #(updated, _effect) = client.update(prior, NextPage)

  assert updated.current_page == 1
}

pub fn update_previous_page_steps_back_when_not_on_first_page_test() {
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 1,
    )

  let #(updated, _effect) = client.update(prior, PreviousPage)

  assert updated.current_page == 0
}

pub fn update_previous_page_holds_on_first_page_test() {
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 0,
    )

  let #(updated, _effect) = client.update(prior, PreviousPage)

  assert updated.current_page == 0
}

pub fn update_next_page_holds_when_no_pages_yet_test() {
  // Reader pressed ArrowRight before pagination finished. With no
  // pages to navigate, `current_page` stays at 0 — the clamp uses
  // `total <= 0` to short-circuit and avoids producing -1.
  let prior = Model(..empty_model(), pages: [], current_page: 0)

  let #(updated, _effect) = client.update(prior, NextPage)

  assert updated.current_page == 0
}

// ---------------------------------------------------------------------------
// update — ViewportResized
// ---------------------------------------------------------------------------

pub fn update_viewport_resized_leaves_model_unchanged_test() {
  // The resize itself doesn't change pagination — it kicks off the
  // measurement effect that, once the next paint settles, dispatches
  // `ParagraphsMeasured`. The reducer step is therefore identity on
  // the model. Pinning this means a future refactor that
  // accidentally clears `pages` on every resize (causing a flash of
  // the "preparing" placeholder) will fail this test.
  let text = two_chapter_text()
  let prior =
    Model(
      text: Some(text),
      pages: [Page(index: 0, paragraphs: [])],
      current_page: 0,
      viewport_height: 800.0,
    )

  let #(updated, _effect) = client.update(prior, ViewportResized)

  assert updated == prior
}

// ---------------------------------------------------------------------------
// view — placeholder branch
// ---------------------------------------------------------------------------

pub fn view_renders_loading_placeholder_when_text_is_none_test() {
  let rendered = client.view(empty_model()) |> element.to_string

  assert rendered
    == "<div class=\"reader\" id=\"vi-shell\">"
    <> "<div class=\"reader-placeholder\">Loading...</div>"
    <> "</div>"
}

// ---------------------------------------------------------------------------
// view — paginated branch (pre-measurement)
// ---------------------------------------------------------------------------

pub fn view_renders_measurement_container_and_preparing_when_pages_empty_test() {
  // After `TextLoaded` but before the first `ParagraphsMeasured`,
  // the visible reading area shows the "Preparing pages..."
  // placeholder while the off-screen `#vi-measurement` container
  // already holds every paragraph the FFI will measure. Pinning the
  // pair in one rendered string catches regressions in either
  // direction: dropping the placeholder (the user sees a blank
  // page) or dropping the measurement container (pagination never
  // gets heights).
  let text =
    SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "One."),
          ]),
        ]),
      ]),
    ])
  let model = Model(..empty_model(), text: Some(text))

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "<div class=\"reader-preparing\">")
  assert string.contains(rendered, "Preparing pages...")
  assert string.contains(
    rendered,
    "<div aria-hidden=\"true\" class=\"reader-measurement\" id=\"vi-measurement\">",
  )
  assert string.contains(rendered, "data-paragraph-global-index=\"0\"")
}

// ---------------------------------------------------------------------------
// view — paginated branch (post-measurement)
// ---------------------------------------------------------------------------

pub fn view_renders_current_page_and_indicator_when_pages_populated_test() {
  // With pages calculated, the visible reading area renders only
  // the current page's paragraphs and the page indicator reads the
  // one-based current page out of the total. The measurement
  // container is still in the DOM (with every paragraph, not just
  // the current page's) so a subsequent resize can re-measure
  // without rebuilding it.
  let text = two_chapter_text()
  let flat = pagination.flatten(text)
  // Build a 3-page slice manually — one paragraph per page.
  let pages = list.index_map(flat, fn(p, i) { Page(index: i, paragraphs: [p]) })
  let model =
    Model(
      text: Some(text),
      pages: pages,
      current_page: 1,
      viewport_height: 600.0,
    )

  let rendered = client.view(model) |> element.to_string

  assert string.contains(
    rendered,
    "<div class=\"reader-page-indicator\" id=\"vi-page-indicator\">Page 2 of 3</div>",
  )
  assert string.contains(rendered, "<div class=\"page\" data-page-index=\"1\">")
  // The visible page (#1) renders paragraph 1 — but not 0 or 2.
  assert string.contains(rendered, "data-paragraph-global-index=\"1\"")
  // The measurement container always contains every paragraph; it
  // appears once. The visible page only contains paragraph 1, so
  // paragraph 0 must appear *only* in the measurement container.
  let paragraph_0_chunks =
    rendered |> string.split("data-paragraph-global-index=\"0\"") |> list.length
  assert paragraph_0_chunks == 2
}

pub fn view_attaches_chapter_title_to_first_paragraph_of_titled_chapter_test() {
  // Chapter titles ride with the first paragraph of their chapter
  // so a page boundary in the middle of a chapter does not orphan
  // the title onto an empty preceding page. The previous-chapter
  // paragraphs carry `chapter_title: None`; only the first
  // paragraph of the next titled chapter carries the heading
  // element. The pinned substrings hit both the `<h2
  // class="chapter-title">` heading and the wrapping
  // `.page-paragraph` that now carries `data-chapter-index` for
  // every paragraph (so untitled chapters stay inspectable too).
  let text = two_chapter_text()
  let flat = pagination.flatten(text)
  let pages = list.index_map(flat, fn(p, i) { Page(index: i, paragraphs: [p]) })
  let model =
    Model(
      text: Some(text),
      pages: pages,
      current_page: 2,
      viewport_height: 600.0,
    )

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "<h2 class=\"chapter-title\">Two</h2>")
  assert string.contains(rendered, "data-chapter-index=\"1\"")
}

// ---------------------------------------------------------------------------
// view — DOM contract for word/sentence spans on a rendered page
// ---------------------------------------------------------------------------

pub fn view_emits_one_word_span_per_word_on_visible_page_test() {
  // Defensive count check — every `Word` on the visible page must
  // emit exactly one `class="word"` span. The whole-string DOM
  // assertion above exercises the surface structure; this one pins
  // that the recursive word renderer doesn't drop or duplicate
  // words on a page that contains multiple sentences.
  let text =
    SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "One"),
            Word(index: 1, global_index: 1, text: "two."),
          ]),
          Sentence(index: 1, global_index: 1, words: [
            Word(index: 0, global_index: 2, text: "Three."),
          ]),
        ]),
      ]),
    ])
  let flat = pagination.flatten(text)
  let pages = [Page(index: 0, paragraphs: flat)]
  let model =
    Model(
      text: Some(text),
      pages: pages,
      current_page: 0,
      viewport_height: 600.0,
    )

  let rendered = client.view(model) |> element.to_string

  // The single paragraph appears twice in the rendered string —
  // once on the visible page and once in the measurement
  // container. Three words × two renderings = six word spans, so
  // splitting on `class="word"` yields seven chunks.
  let chunks = rendered |> string.split("class=\"word\"") |> list.length
  assert chunks == 7
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
