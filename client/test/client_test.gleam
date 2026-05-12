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
import gleam/set
import gleam/string
import gleeunit
import lustre/element
import lustre/vdom/vattr
import lustre/vdom/vnode
import shared
import shared/segmenter.{
  type SegmentedText, Chapter, Paragraph, SegmentedText, Sentence, Word,
}

import client.{
  type Model, EraseSentence, Model, NextPage, ParagraphsMeasured, PreviousPage,
  TextLoaded, TouchCancel, TouchEnd, TouchStart, Undo, ViewportResized,
}
import client/gestures
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
  Model(
    text: None,
    flat_paragraphs: [],
    pages: [],
    current_page: 0,
    erased: set.new(),
    undo_stack: [],
    touch_start: None,
  )
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
  // so the renderer stops drawing the placeholder, (b) refresh the
  // cached `flat_paragraphs` so neither `update` nor `view` has to
  // re-flatten the book on every page-change keystroke, and (c)
  // reset the paginated view state — empty pages, current_page
  // back to 0. The follow-up `ParagraphsMeasured` from the
  // after_paint effect is what fills `pages` in, so the immediate
  // post-`TextLoaded` state is "text loaded, pagination pending".
  // Asserting on the full model pins all three transitions in one
  // place.
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
      flat_paragraphs: pagination.flatten(payload),
      pages: [],
      current_page: 0,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
    )
}

pub fn update_text_loaded_overwrites_existing_text_and_resets_pagination_test() {
  // A second `TextLoaded` replaces the prior payload rather than
  // merging it; it also resets `pages`, `current_page`, and the
  // cached `flat_paragraphs` so the reader cannot land on a stale
  // page index from the prior book while measurement of the new
  // payload is in flight.
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
      flat_paragraphs: pagination.flatten(first),
      pages: [Page(index: 0, paragraphs: [])],
      current_page: 0,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
    )

  let #(updated, _effect) = client.update(prior, TextLoaded(second))

  assert updated
    == Model(
      text: Some(second),
      flat_paragraphs: pagination.flatten(second),
      pages: [],
      current_page: 0,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
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
  let prior =
    Model(
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: pagination.flatten(text),
    )
  let heights = [#(0, 100.0), #(1, 100.0), #(2, 100.0)]

  let #(updated, _effect) =
    client.update(
      prior,
      ParagraphsMeasured(heights: heights, available_height: 250.0),
    )

  assert list.length(updated.pages) == 2
  assert updated.current_page == 0
}

pub fn update_paragraphs_measured_clamps_current_page_into_new_total_test() {
  // A resize shrinks the page budget and the document repaginates
  // to fewer pages. The reader's `current_page` must clamp down so
  // the visible page index is valid for the new `pages` length —
  // otherwise the view would try to render a page that no longer
  // exists and fall through to the "preparing" branch.
  let text = two_chapter_text()
  let prior =
    Model(
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: pagination.flatten(text),
      current_page: 5,
    )

  // 25px budget forces one paragraph per page → 3 pages total.
  let heights = [#(0, 100.0), #(1, 100.0), #(2, 100.0)]
  let #(updated, _effect) =
    client.update(
      prior,
      ParagraphsMeasured(heights: heights, available_height: 25.0),
    )

  assert list.length(updated.pages) == 3
  assert updated.current_page == 2
}

pub fn update_paragraphs_measured_with_no_text_produces_no_pages_test() {
  // Defensive: a measurement that arrives while `text` is still
  // `None` (in practice impossible without a future bug) must not
  // panic; the reducer just leaves pages empty so the view stays
  // on the loading placeholder.
  let #(updated, _effect) =
    client.update(
      empty_model(),
      ParagraphsMeasured(heights: [], available_height: 380.0),
    )

  assert updated.pages == []
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
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: pagination.flatten(text),
      pages: [Page(index: 0, paragraphs: [])],
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
  let model =
    Model(
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: pagination.flatten(text),
    )

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
      flat_paragraphs: flat,
      pages: pages,
      current_page: 1,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
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
      flat_paragraphs: flat,
      pages: pages,
      current_page: 2,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
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
      flat_paragraphs: flat,
      pages: pages,
      current_page: 0,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
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
// update — EraseSentence
// ---------------------------------------------------------------------------

pub fn update_erase_sentence_marks_sentence_and_pushes_undo_test() {
  // Tapping a fresh sentence must (a) insert the sentence's
  // `global_index` into `erased` and (b) push that index onto the
  // front of `undo_stack`. Both halves are pinned together because
  // erase without undo entry would orphan the undo handler, and
  // undo entry without erase would make Undo a visible no-op.
  let prior = empty_model()

  let #(updated, _effect) = client.update(prior, EraseSentence(7))

  assert set.contains(updated.erased, 7)
  assert updated.undo_stack == [7]
}

pub fn update_erase_sentence_is_idempotent_on_already_erased_test() {
  // Re-tapping a sentence already in `erased` must be a no-op. The
  // undo stack would otherwise grow with duplicate entries — undo
  // would then have to be pressed N times to actually restore a
  // sentence the reader meant to erase once.
  let prior =
    Model(..empty_model(), erased: set.from_list([3]), undo_stack: [3])

  let #(updated, _effect) = client.update(prior, EraseSentence(3))

  assert updated == prior
}

pub fn update_erase_sentence_caps_undo_stack_at_five_entries_test() {
  // Rapidly erasing six sentences must leave only the most recent
  // five in `undo_stack`; the earliest erase commits and becomes
  // permanent for the duration of the current page. Pinning the
  // exact stack contents catches both off-by-one truncation and
  // accidental reversal of the recency order.
  let after_5 =
    list.fold([0, 1, 2, 3, 4], empty_model(), fn(model, index) {
      let #(updated, _) = client.update(model, EraseSentence(index))
      updated
    })

  let #(after_6, _) = client.update(after_5, EraseSentence(5))

  assert after_6.undo_stack == [5, 4, 3, 2, 1]
  // Every erased sentence — including the one that fell off the
  // undo stack — stays erased on the model.
  assert set.contains(after_6.erased, 0)
  assert set.contains(after_6.erased, 5)
}

// ---------------------------------------------------------------------------
// update — Undo
// ---------------------------------------------------------------------------

pub fn update_undo_restores_most_recent_erase_and_pops_stack_test() {
  // Undo with a non-empty stack must (a) remove the top index from
  // `undo_stack` and (b) delete its `erased` entry — restoring the
  // sentence to visible. Earlier entries on the stack stay intact.
  let prior =
    Model(..empty_model(), erased: set.from_list([2, 7]), undo_stack: [7, 2])

  let #(updated, _effect) = client.update(prior, Undo)

  assert updated.undo_stack == [2]
  assert !set.contains(updated.erased, 7)
  assert set.contains(updated.erased, 2)
}

pub fn update_undo_is_noop_when_stack_empty_test() {
  // The reader can press Cmd+Z (or swipe right with nothing to
  // undo) before any erases have happened. The reducer must hold
  // the model unchanged — in particular, it must not touch
  // `erased` or accidentally introduce a phantom undo entry.
  let prior = empty_model()

  let #(updated, _effect) = client.update(prior, Undo)

  assert updated == prior
}

// ---------------------------------------------------------------------------
// update — page commitment
// ---------------------------------------------------------------------------

pub fn update_next_page_clears_undo_stack_but_keeps_erased_test() {
  // Navigating forward must clear `undo_stack` — erases on the
  // page being left commit and are no longer undoable. The
  // `erased` map keeps every prior entry so the sentences stay
  // invisible when the reader pages back later.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 0,
      erased: set.from_list([0, 1]),
      undo_stack: [1, 0],
    )

  let #(updated, _effect) = client.update(prior, NextPage)

  assert updated.current_page == 1
  assert updated.undo_stack == []
  assert set.contains(updated.erased, 0)
  assert set.contains(updated.erased, 1)
}

pub fn update_previous_page_also_clears_undo_stack_test() {
  // Symmetry with `NextPage`: paging *backwards* also commits
  // erases on the page being left, so the undo stack must clear in
  // both directions. Without this, a reader who erased a sentence
  // on page 2 and paged back to page 1 could undo a sentence from
  // page 2 while reading page 1 — confusing at best, broken at
  // worst.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 1,
      erased: set.from_list([4]),
      undo_stack: [4],
    )

  let #(updated, _effect) = client.update(prior, PreviousPage)

  assert updated.current_page == 0
  assert updated.undo_stack == []
  assert set.contains(updated.erased, 4)
}

pub fn update_next_page_at_last_page_preserves_undo_stack_test() {
  // A reader on the last page has unfinished erase work and presses
  // ArrowRight (or swipes left) by reflex. `current_page` clamps to
  // itself — no actual page boundary is crossed — so the undo stack
  // must survive. The previous implementation cleared it
  // unconditionally and silently destroyed undoable erases.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 1,
      erased: set.from_list([8]),
      undo_stack: [8],
    )

  let #(updated, _effect) = client.update(prior, NextPage)

  assert updated.current_page == 1
  assert updated.undo_stack == [8]
  assert set.contains(updated.erased, 8)
}

pub fn update_previous_page_at_first_page_preserves_undo_stack_test() {
  // Mirror of the previous test for the page-0 boundary: an
  // ArrowLeft at the start of the book must not destroy the undo
  // stack either.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 0,
      erased: set.from_list([2]),
      undo_stack: [2],
    )

  let #(updated, _effect) = client.update(prior, PreviousPage)

  assert updated.current_page == 0
  assert updated.undo_stack == [2]
  assert set.contains(updated.erased, 2)
}

pub fn update_swipe_left_at_last_page_preserves_undo_stack_test() {
  // The touch-gesture path threads through `go_to_page` too — a
  // SwipeLeft on the last page must not clear the undo stack any
  // more than a keyboard ArrowRight does.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 1,
      erased: set.from_list([5]),
      undo_stack: [5],
      touch_start: Some(#(300.0, 200.0)),
    )

  // -150px horizontal, +5px vertical → SwipeLeft → NextPage path.
  let #(updated, _effect) = client.update(prior, TouchEnd(150.0, 205.0))

  assert updated.current_page == 1
  assert updated.undo_stack == [5]
  assert set.contains(updated.erased, 5)
  assert updated.touch_start == None
}

// ---------------------------------------------------------------------------
// update — touch gestures
// ---------------------------------------------------------------------------

pub fn update_touch_start_records_start_coordinates_test() {
  let prior = empty_model()

  let #(updated, _effect) = client.update(prior, TouchStart(120.0, 240.0))

  assert updated.touch_start == Some(#(120.0, 240.0))
}

pub fn update_touch_end_below_threshold_does_nothing_test() {
  // A tap (no swipe) leaves erase state alone — the synthesized
  // browser `click` event is what carries erase intent, so a Tap
  // outcome from gestures.classify must NOT trigger any reducer
  // mutation beyond clearing `touch_start`.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 0,
      touch_start: Some(#(100.0, 200.0)),
    )

  let #(updated, _effect) = client.update(prior, TouchEnd(102.0, 199.0))

  assert updated.current_page == 0
  assert updated.touch_start == None
}

pub fn update_touch_end_swipe_left_advances_page_test() {
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 0,
      touch_start: Some(#(300.0, 200.0)),
    )

  // -150px horizontal, +5px vertical → SwipeLeft → NextPage.
  let #(updated, _effect) = client.update(prior, TouchEnd(150.0, 205.0))

  assert updated.current_page == 1
  assert updated.touch_start == None
}

pub fn update_touch_end_swipe_right_with_undo_stack_undoes_test() {
  // A right swipe with a non-empty undo stack must call Undo, not
  // PreviousPage. The reader has unfinished erase work on the
  // current page — going back would commit it via the page
  // boundary clear, which the user did not ask for.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 1,
      erased: set.from_list([9]),
      undo_stack: [9],
      touch_start: Some(#(100.0, 200.0)),
    )

  // +200px horizontal → SwipeRight.
  let #(updated, _effect) = client.update(prior, TouchEnd(300.0, 198.0))

  assert updated.current_page == 1
  assert updated.undo_stack == []
  assert !set.contains(updated.erased, 9)
  assert updated.touch_start == None
}

pub fn update_touch_end_swipe_right_with_empty_undo_goes_back_test() {
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 1,
      touch_start: Some(#(100.0, 200.0)),
    )

  let #(updated, _effect) = client.update(prior, TouchEnd(300.0, 198.0))

  assert updated.current_page == 0
  assert updated.touch_start == None
}

pub fn update_touch_cancel_clears_stale_touch_start_test() {
  // The browser steals an in-flight touch — system back gesture,
  // notification pull-down, modal scrim — and fires `touchcancel`
  // with no matching `touchend`. Without this handler `touch_start`
  // retains the cancelled gesture's coordinates indefinitely; the
  // next legitimate `touchend` then classifies against those stale
  // coordinates and produces a swipe the reader never made. The
  // handler resets `touch_start: None` and touches nothing else.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 0,
      erased: set.from_list([3]),
      undo_stack: [3],
      touch_start: Some(#(100.0, 200.0)),
    )

  let #(updated, _effect) = client.update(prior, TouchCancel)

  assert updated.touch_start == None
  assert updated.current_page == 0
  assert updated.undo_stack == [3]
  assert set.contains(updated.erased, 3)
}

pub fn update_touch_end_after_cancel_is_safe_test() {
  // Integration shape: a cancelled touch followed by an unrelated
  // touchend (e.g. an out-of-band finger lift the system delivered
  // after the cancellation) must not produce a phantom swipe. With
  // `TouchCancel` clearing `touch_start`, the subsequent `TouchEnd`
  // hits the `None` branch and exits cleanly.
  let prior = Model(..empty_model(), touch_start: Some(#(100.0, 200.0)))

  let #(after_cancel, _effect) = client.update(prior, TouchCancel)
  let #(after_end, _effect) =
    client.update(after_cancel, TouchEnd(500.0, 200.0))

  assert after_end.touch_start == None
  assert after_end.current_page == 0
}

pub fn update_touch_end_without_matching_start_is_safe_test() {
  // Defensive: a `touchend` without a matching `touchstart` (e.g.
  // a touch initiated during a modal or scroll the page never
  // saw) must be ignored cleanly. Without the `None` guard, the
  // gesture classifier would still fire with bogus coordinates.
  let prior = empty_model()

  let #(updated, _effect) = client.update(prior, TouchEnd(500.0, 100.0))

  assert updated == prior
}

// ---------------------------------------------------------------------------
// gestures.classify — pure classification
// ---------------------------------------------------------------------------

pub fn gestures_classify_tap_below_threshold_test() {
  assert gestures.classify(100.0, 200.0, 110.0, 205.0) == gestures.Tap
}

pub fn gestures_classify_tap_when_vertical_dominates_test() {
  // 60px horizontal looks like a swipe on the horizontal axis
  // alone, but the vertical motion is even larger (80px) — the
  // discrimination rule rejects diagonal motion as Tap so a
  // reader's accidental drag-and-scroll doesn't flip pages.
  assert gestures.classify(100.0, 200.0, 160.0, 280.0) == gestures.Tap
}

pub fn gestures_classify_swipe_left_test() {
  assert gestures.classify(300.0, 200.0, 200.0, 210.0) == gestures.SwipeLeft
}

pub fn gestures_classify_swipe_right_test() {
  assert gestures.classify(100.0, 200.0, 200.0, 210.0) == gestures.SwipeRight
}

pub fn gestures_classify_exactly_at_threshold_is_tap_test() {
  // The threshold is a strict ">", not ">=" — a motion exactly at
  // 50px stays a tap so the boundary is unambiguous in both
  // directions.
  assert gestures.classify(100.0, 200.0, 150.0, 200.0) == gestures.Tap
}

// ---------------------------------------------------------------------------
// view — erase rendering
// ---------------------------------------------------------------------------

pub fn view_renders_opacity_zero_on_erased_sentence_test() {
  // The visible page's sentence span carries an inline opacity
  // style only when it's in `erased`. The off-screen measurement
  // mirror is rendered with an empty erase map so an erased
  // sentence appears exactly once with `opacity:0` in the full
  // output (the measurement copy stays unstyled).
  let text = two_chapter_text()
  let flat = pagination.flatten(text)
  let pages = list.index_map(flat, fn(p, i) { Page(index: i, paragraphs: [p]) })
  let model =
    Model(
      text: Some(text),
      flat_paragraphs: flat,
      pages: pages,
      current_page: 1,
      erased: set.from_list([1]),
      undo_stack: [1],
      touch_start: None,
    )

  let rendered = client.view(model) |> element.to_string

  let opacity_chunks = rendered |> string.split("opacity:0;") |> list.length
  assert opacity_chunks == 2
  assert string.contains(rendered, "data-sentence-index=\"1\"")
}

pub fn view_sentence_attaches_click_handler_when_interactive_test() {
  // Lustre's `to_string` strips `event.*` attributes from the
  // rendered HTML, so a contract test that checks for the `on_click`
  // wiring has to inspect the returned `Element` directly. The
  // visible reading area passes `interactive: True` to
  // `view_sentence`, and the click handler — the only path that
  // produces `EraseSentence` — must come back as a `click` event on
  // the span. A future refactor that drops or relocates the handler
  // would not show up in the HTML-substring assertions; it would
  // show up here.
  let sentence =
    Sentence(index: 0, global_index: 4, words: [
      Word(index: 0, global_index: 0, text: "Hi."),
    ])

  let click_events =
    client.view_sentence(sentence, set.new(), True) |> click_event_names

  assert click_events == ["click"]
}

pub fn view_sentence_omits_click_handler_when_not_interactive_test() {
  // The measurement-mirror branch passes `interactive: False`, and
  // the resulting span must carry no `click` event. Pinning the
  // negative case alongside the positive one stops a future
  // "always-on" refactor that ignores the flag from silently
  // re-attaching N dead handlers across the whole book.
  let sentence =
    Sentence(index: 0, global_index: 4, words: [
      Word(index: 0, global_index: 0, text: "Hi."),
    ])

  let click_events =
    client.view_sentence(sentence, set.new(), False) |> click_event_names

  assert click_events == []
}

fn click_event_names(rendered: element.Element(msg)) -> List(String) {
  case rendered {
    vnode.Element(attributes:, ..) ->
      attributes
      |> list.filter_map(fn(attr) {
        case attr {
          vattr.Event(name:, ..) -> Ok(name)
          _ -> Error(Nil)
        }
      })
      |> list.filter(fn(name) { name == "click" })
    _ -> []
  }
}

pub fn view_omits_opacity_when_no_sentences_erased_test() {
  // The inverse: a model with an empty `erased` map renders no
  // inline opacity at all — neither on the visible page nor in
  // the measurement mirror. This catches accidental always-on
  // opacity rendering, which would suppress the CSS transition.
  let text = two_chapter_text()
  let flat = pagination.flatten(text)
  let pages = list.index_map(flat, fn(p, i) { Page(index: i, paragraphs: [p]) })
  let model =
    Model(
      text: Some(text),
      flat_paragraphs: flat,
      pages: pages,
      current_page: 1,
      erased: set.new(),
      undo_stack: [],
      touch_start: None,
    )

  let rendered = client.view(model) |> element.to_string

  assert !string.contains(rendered, "opacity")
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
