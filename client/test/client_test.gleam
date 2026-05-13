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

import gleam/float
import gleam/int
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
  type Paragraph, type SegmentedText, type Sentence, Chapter, Paragraph,
  SegmentedText, Sentence, Word,
}

import client.{
  type Model, AdvanceWord, EraseFocused, EraseSentence, FocusNext,
  FocusParagraphDown, FocusParagraphUp, FocusPrevious, Manual, Model, NextPage,
  ParagraphsMeasured, PauseFade, Paused, RealTime, ResumeFade, Running,
  SetFontSize, SetGhostOpacity, SetLineSpacing, SetMode, SetPageDelay,
  SetParagraphDelay, SetWpm, SpacePressed, StartFade, StopFade, Stopped,
  TextLoaded, ToggleDarkMode, ToggleDyslexiaFont, ToggleGhostMode,
  ToggleSettings, TouchCancel, TouchEnd, TouchStart, Undo, ViewportResized,
}
import client/gestures
import client/pagination.{type Page, Page}
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
    focused_sentence: None,
    dark_mode: True,
    font_size: client.default_font_size,
    line_spacing: client.default_line_spacing,
    ghost_mode: False,
    ghost_opacity: client.default_ghost_opacity,
    dyslexia_font: False,
    reduced_motion: False,
    settings_open: False,
    mode: client.Manual,
    wpm: client.default_wpm,
    engine_state: client.Stopped,
    next_word_index: None,
    erased_words: set.new(),
    paragraph_delay_ms: client.default_paragraph_delay_ms,
    page_delay_ms: client.default_page_delay_ms,
    line_boxes: [],
    active_line: None,
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

/// Eight-paragraph, eight-sentence fixture used by the
/// post-repagination focus tests. One sentence per paragraph;
/// `Sentence.global_index` matches the paragraph index so the test
/// can name the focused sentence by paragraph number.
fn eight_paragraph_text() -> SegmentedText {
  let paragraph = fn(idx: Int) -> Paragraph {
    Paragraph(index: idx, sentences: [
      Sentence(index: idx, global_index: idx, words: [
        Word(index: 0, global_index: idx, text: "para."),
      ]),
    ])
  }

  SegmentedText(chapters: [
    Chapter(index: 0, title: None, paragraphs: [
      paragraph(0),
      paragraph(1),
      paragraph(2),
      paragraph(3),
      paragraph(4),
      paragraph(5),
      paragraph(6),
      paragraph(7),
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
      ..empty_model(),
      text: Some(payload),
      flat_paragraphs: pagination.flatten(payload),
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
      ..empty_model(),
      text: Some(first),
      flat_paragraphs: pagination.flatten(first),
      pages: [Page(index: 0, paragraphs: [])],
    )

  let #(updated, _effect) = client.update(prior, TextLoaded(second))

  assert updated
    == Model(
      ..empty_model(),
      text: Some(second),
      flat_paragraphs: pagination.flatten(second),
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

pub fn update_paragraphs_measured_reanchors_focused_sentence_when_repagination_moves_it_off_current_page_test() {
  // Repagination shifts the focused sentence onto an earlier page
  // than the visible one. Without the re-anchor in `ParagraphsMeasured`,
  // the next vim keypress would invoke `change_page` with a target
  // below `current_page` (the vim path does not pass through the
  // forward-only `go_to_page` guard), regressing the page index and
  // breaking the PR's "no backward page navigation" guarantee.
  //
  // Setup: eight 100px paragraphs, 200px budget → 4 pages of two
  // paragraphs each. Reader is on page 1 (paragraphs 2-3), focused
  // on the sentence in paragraph 2. A resize widens the budget to
  // 400px → 2 pages of four paragraphs each. `current_page` does
  // not clamp (still valid: 1 < 2), but paragraph 2 now lives on
  // page 0. Re-anchor must move the cursor to the first non-erased
  // sentence on the new `current_page` (sentence 4, the first on
  // the four-paragraph page 1).
  let text = eight_paragraph_text()
  let heights_narrow = [
    #(0, 100.0),
    #(1, 100.0),
    #(2, 100.0),
    #(3, 100.0),
    #(4, 100.0),
    #(5, 100.0),
    #(6, 100.0),
    #(7, 100.0),
  ]
  let initial =
    Model(
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: pagination.flatten(text),
    )
  let #(measured, _) =
    client.update(
      initial,
      ParagraphsMeasured(heights: heights_narrow, available_height: 200.0),
    )
  let prior = Model(..measured, current_page: 1, focused_sentence: Some(2))

  let #(updated, _effect) =
    client.update(
      prior,
      ParagraphsMeasured(heights: heights_narrow, available_height: 400.0),
    )

  assert list.length(updated.pages) == 2
  assert updated.current_page == 1
  assert updated.focused_sentence == Some(4)
}

pub fn update_paragraphs_measured_preserves_focused_sentence_when_it_stays_on_current_page_test() {
  // Repagination that leaves the focused sentence on the visible
  // page must not move the cursor. The re-anchor only fires when
  // the focused sentence has shifted off `current_page`; an
  // identity re-measure (or any pagination that lands the cursor
  // on the same page index) should be a no-op for the cursor.
  let text = eight_paragraph_text()
  let heights = [
    #(0, 100.0),
    #(1, 100.0),
    #(2, 100.0),
    #(3, 100.0),
    #(4, 100.0),
    #(5, 100.0),
    #(6, 100.0),
    #(7, 100.0),
  ]
  let initial =
    Model(
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: pagination.flatten(text),
    )
  let #(measured, _) =
    client.update(
      initial,
      ParagraphsMeasured(heights: heights, available_height: 200.0),
    )
  let prior = Model(..measured, current_page: 1, focused_sentence: Some(2))

  // Re-measure with the same heights and budget.
  let #(updated, _effect) =
    client.update(
      prior,
      ParagraphsMeasured(heights: heights, available_height: 200.0),
    )

  assert updated.current_page == 1
  assert updated.focused_sentence == Some(2)
}

pub fn update_paragraphs_measured_with_no_focused_sentence_keeps_focus_none_test() {
  // Repagination with no vim cursor active must not introduce one.
  // The re-anchor logic is gated on `focused_sentence: Some(_)` so
  // a reader in touch-only mode stays in touch-only mode across a
  // viewport resize.
  let text = eight_paragraph_text()
  let heights = [
    #(0, 100.0),
    #(1, 100.0),
    #(2, 100.0),
    #(3, 100.0),
    #(4, 100.0),
    #(5, 100.0),
    #(6, 100.0),
    #(7, 100.0),
  ]
  let prior =
    Model(
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: pagination.flatten(text),
      current_page: 1,
      focused_sentence: None,
    )

  let #(updated, _effect) =
    client.update(
      prior,
      ParagraphsMeasured(heights: heights, available_height: 400.0),
    )

  assert updated.focused_sentence == None
}

// ---------------------------------------------------------------------------
// update — NextPage
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
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: flat,
      pages: pages,
      current_page: 1,
    )

  let rendered = client.view(model) |> element.to_string

  assert string.contains(
    rendered,
    "<div class=\"reader-page-indicator\">Page 2 of 3</div>",
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
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: flat,
      pages: pages,
      current_page: 2,
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
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: flat,
      pages: pages,
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
  // Whole-Model comparison so an incidental mutation of any other
  // field (e.g. a future bug that resets `current_page` on erase)
  // also fails here.
  let prior = empty_model()

  let #(updated, _effect) = client.update(prior, EraseSentence(7))

  assert updated == Model(..prior, erased: set.from_list([7]), undo_stack: [7])
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
  // accidental reversal of the recency order. Whole-Model
  // comparison so an unrelated field bouncing during the six-step
  // run also fails here — `erased` carries all six indices
  // (including the one that fell off the undo stack), and no
  // other field is touched by EraseSentence.
  let after_5 =
    list.fold([0, 1, 2, 3, 4], empty_model(), fn(model, index) {
      let #(updated, _) = client.update(model, EraseSentence(index))
      updated
    })

  let #(after_6, _) = client.update(after_5, EraseSentence(5))

  assert after_6
    == Model(
      ..empty_model(),
      erased: set.from_list([0, 1, 2, 3, 4, 5]),
      undo_stack: [5, 4, 3, 2, 1],
    )
}

// ---------------------------------------------------------------------------
// update — Undo
// ---------------------------------------------------------------------------

pub fn update_undo_restores_most_recent_erase_and_pops_stack_test() {
  // Undo with a non-empty stack must (a) remove the top index from
  // `undo_stack` and (b) delete its `erased` entry — restoring the
  // sentence to visible. Earlier entries on the stack stay intact.
  // Whole-Model comparison so an incidental mutation of any other
  // field (page index, touch_start, etc.) by a future Undo refactor
  // is caught here too.
  let prior =
    Model(..empty_model(), erased: set.from_list([2, 7]), undo_stack: [7, 2])

  let #(updated, _effect) = client.update(prior, Undo)

  assert updated == Model(..prior, erased: set.from_list([2]), undo_stack: [2])
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
  // invisible when the reader pages back later. Whole-Model
  // comparison so an unintended mutation of `pages`, `text`, or
  // `touch_start` on a page turn also fails here.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 0,
      erased: set.from_list([0, 1]),
      undo_stack: [1, 0],
    )

  let #(updated, _effect) = client.update(prior, NextPage)

  assert updated == Model(..prior, current_page: 1, undo_stack: [])
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

  assert updated == prior
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

  assert updated == Model(..prior, touch_start: None)
}

// ---------------------------------------------------------------------------
// update — touch gestures
// ---------------------------------------------------------------------------

pub fn update_touch_start_records_start_coordinates_test() {
  let prior = empty_model()

  let #(updated, _effect) = client.update(prior, TouchStart(120.0, 240.0))

  assert updated == Model(..prior, touch_start: Some(#(120.0, 240.0)))
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

  assert updated == Model(..prior, touch_start: None)
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

  assert updated == Model(..prior, current_page: 1, touch_start: None)
}

pub fn update_touch_end_swipe_right_with_undo_stack_undoes_test() {
  // A right swipe with a non-empty undo stack must call Undo. The
  // reader has unfinished erase work on the current page — losing
  // it via any other backward action would not be what the user
  // asked for.
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

  assert updated
    == Model(..prior, erased: set.new(), undo_stack: [], touch_start: None)
}

pub fn update_touch_end_swipe_right_with_empty_undo_is_noop_test() {
  // Swipe-right with an empty undo stack is a no-op — backward page
  // navigation is disabled. The only effect is clearing `touch_start`.
  let prior =
    Model(
      ..empty_model(),
      pages: [Page(index: 0, paragraphs: []), Page(index: 1, paragraphs: [])],
      current_page: 1,
      touch_start: Some(#(100.0, 200.0)),
    )

  let #(updated, _effect) = client.update(prior, TouchEnd(300.0, 198.0))

  assert updated == Model(..prior, touch_start: None)
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

  assert updated == Model(..prior, touch_start: None)
}

pub fn update_touch_end_after_cancel_is_safe_test() {
  // Integration shape: a cancelled touch followed by an unrelated
  // touchend (e.g. an out-of-band finger lift the system delivered
  // after the cancellation) must not produce a phantom swipe. With
  // `TouchCancel` clearing `touch_start`, the subsequent `TouchEnd`
  // hits the `None` branch and exits cleanly. The final whole-Model
  // assertion pins both intermediate steps (cancel clears
  // `touch_start`; end-after-cancel keeps everything else inert).
  let prior = Model(..empty_model(), touch_start: Some(#(100.0, 200.0)))

  let #(after_cancel, _effect) = client.update(prior, TouchCancel)
  let #(after_end, _effect) =
    client.update(after_cancel, TouchEnd(500.0, 200.0))

  assert after_end == Model(..prior, touch_start: None)
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
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: flat,
      pages: pages,
      current_page: 1,
      erased: set.from_list([1]),
      undo_stack: [1],
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
    client.view_sentence(
      sentence,
      set.new(),
      None,
      True,
      "0",
      set.new(),
      Manual,
    )
    |> click_event_names

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
    client.view_sentence(
      sentence,
      set.new(),
      None,
      False,
      "0",
      set.new(),
      Manual,
    )
    |> click_event_names

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

pub fn view_paginated_attaches_touch_handlers_to_reading_area_test() {
  // The three touch listeners on `#vi-reading-area`
  // (`gestures.on_touch_start`, `on_touch_end`, `on_touch_cancel`)
  // are the *only* path from the browser's touch event stream into
  // the reducer — every `TouchStart` / `TouchEnd` / `TouchCancel`
  // reducer test bypasses the view entirely. A refactor that
  // accidentally drops one of those listeners (or moves them off
  // the reading-area div) would not register on the reducer suite;
  // mobile gesture handling would silently break. Pinning the
  // contract here, with the same `vnode/vattr` introspection used
  // by `click_event_names`, closes that gap.
  //
  // `element.to_string` strips event attributes, so we walk the
  // rendered tree, locate the element with `id="vi-reading-area"`,
  // and inspect its Event attribute names directly.
  let text = two_chapter_text()
  let flat = pagination.flatten(text)
  let pages = list.index_map(flat, fn(p, i) { Page(index: i, paragraphs: [p]) })
  let model =
    Model(
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: flat,
      pages: pages,
    )

  let assert Ok(reading_area) =
    client.view(model) |> find_element_by_id("vi-reading-area")
  // Lustre's `attribute.prepare` sorts attributes by name on insert,
  // so the rendered tree carries the three Event attributes in
  // alphabetical order. Asserting the whole sorted list catches both
  // accidental drops *and* accidental additions (a future fourth
  // touch listener would show up here, not silently).
  let touch_events = reading_area |> touch_event_names

  assert touch_events == ["touchcancel", "touchend", "touchstart"]
}

fn find_element_by_id(
  rendered: element.Element(msg),
  target_id: String,
) -> Result(element.Element(msg), Nil) {
  case rendered {
    vnode.Element(attributes:, children:, ..) -> {
      let has_id =
        list.any(attributes, fn(attr) {
          case attr {
            vattr.Attribute(name: "id", value:, ..) -> value == target_id
            _ -> False
          }
        })
      case has_id {
        True -> Ok(rendered)
        False -> find_in_children(children, target_id)
      }
    }
    vnode.Fragment(children:, ..) -> find_in_children(children, target_id)
    _ -> Error(Nil)
  }
}

fn find_in_children(
  children: List(element.Element(msg)),
  target_id: String,
) -> Result(element.Element(msg), Nil) {
  case children {
    [] -> Error(Nil)
    [head, ..rest] ->
      case find_element_by_id(head, target_id) {
        Ok(found) -> Ok(found)
        Error(_) -> find_in_children(rest, target_id)
      }
  }
}

fn touch_event_names(rendered: element.Element(msg)) -> List(String) {
  case rendered {
    vnode.Element(attributes:, ..) ->
      attributes
      |> list.filter_map(fn(attr) {
        case attr {
          vattr.Event(name:, ..) -> Ok(name)
          _ -> Error(Nil)
        }
      })
      |> list.filter(fn(name) { string.starts_with(name, "touch") })
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
      ..empty_model(),
      text: Some(text),
      flat_paragraphs: flat,
      pages: pages,
      current_page: 1,
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

// ---------------------------------------------------------------------------
// vim-keys fixtures
// ---------------------------------------------------------------------------
//
// The vim-keys integration tests use a hand-built two-page layout
// rather than `two_chapter_text()` + `pagination.flatten` /
// `pagination.calculate_pages` so the page/paragraph/sentence
// indices the assertions read off the model are fixed at the test
// source rather than dependent on the pagination algorithm. If the
// pagination engine ever changes how it groups paragraphs into
// pages, these tests still describe the keyboard navigation
// contract on the same nominal layout.
//
// Layout:
//   Page 0:
//     Paragraph 0 (global) — sentences 0, 1
//     Paragraph 1 (global) — sentence  2
//   Page 1:
//     Paragraph 2 (global) — sentence  3
//     Paragraph 3 (global) — sentences 4, 5

fn vim_sentence(local_index: Int, global_index: Int) -> Sentence {
  Sentence(index: local_index, global_index: global_index, words: [
    Word(index: 0, global_index: global_index, text: "x"),
  ])
}

fn vim_paragraph(local_index: Int, sentences: List(Sentence)) -> Paragraph {
  Paragraph(index: local_index, sentences: sentences)
}

fn vim_page_paragraph(
  global_index: Int,
  paragraph: Paragraph,
) -> pagination.PageParagraph {
  pagination.PageParagraph(
    global_index: global_index,
    chapter_index: 0,
    chapter_title: None,
    paragraph: paragraph,
  )
}

fn vim_text() -> SegmentedText {
  SegmentedText(chapters: [
    Chapter(index: 0, title: None, paragraphs: [
      vim_paragraph(0, [vim_sentence(0, 0), vim_sentence(1, 1)]),
      vim_paragraph(1, [vim_sentence(0, 2)]),
      vim_paragraph(2, [vim_sentence(0, 3)]),
      vim_paragraph(3, [vim_sentence(0, 4), vim_sentence(1, 5)]),
    ]),
  ])
}

fn vim_pages() -> List(Page) {
  [
    Page(index: 0, paragraphs: [
      vim_page_paragraph(
        0,
        vim_paragraph(0, [vim_sentence(0, 0), vim_sentence(1, 1)]),
      ),
      vim_page_paragraph(1, vim_paragraph(1, [vim_sentence(0, 2)])),
    ]),
    Page(index: 1, paragraphs: [
      vim_page_paragraph(2, vim_paragraph(2, [vim_sentence(0, 3)])),
      vim_page_paragraph(
        3,
        vim_paragraph(3, [vim_sentence(0, 4), vim_sentence(1, 5)]),
      ),
    ]),
  ]
}

fn vim_model_on_page(page_index: Int) -> Model {
  Model(
    ..empty_model(),
    text: Some(vim_text()),
    flat_paragraphs: pagination.flatten(vim_text()),
    pages: vim_pages(),
    current_page: page_index,
  )
}

// ---------------------------------------------------------------------------
// update — FocusNext / FocusPrevious initialisation
// ---------------------------------------------------------------------------

pub fn update_focus_next_initialises_cursor_when_dormant_test() {
  // A first vim-key press on a fresh page must wake the cursor up
  // rather than move it: there's nothing to move from. The cursor
  // lands on the first non-erased sentence of the current page —
  // sentence 0 on page 0 — so the reader sees the cursor appear
  // exactly where it would expect.
  let prior = vim_model_on_page(0)

  let #(updated, _) = client.update(prior, FocusNext)

  assert updated == Model(..prior, focused_sentence: Some(0))
}

pub fn update_focus_previous_initialises_cursor_when_dormant_test() {
  // Symmetry: even `h` (Backward) initialises to the *first*
  // non-erased sentence on the current page. The first press wakes
  // the cursor, the next press is what actually moves — landing on
  // the last sentence of the previous page on the very first press
  // would skip past the visible current page entirely.
  let prior = vim_model_on_page(1)

  let #(updated, _) = client.update(prior, FocusPrevious)

  assert updated == Model(..prior, focused_sentence: Some(3))
}

pub fn update_focus_next_initialises_skipping_erased_test() {
  // First press with sentence 0 already erased (e.g. via click)
  // must initialise to sentence 1, not land on the invisible
  // erased sentence.
  let prior =
    Model(..vim_model_on_page(0), erased: set.from_list([0]), undo_stack: [0])

  let #(updated, _) = client.update(prior, FocusNext)

  assert updated == Model(..prior, focused_sentence: Some(1))
}

// ---------------------------------------------------------------------------
// update — FocusNext / FocusPrevious movement
// ---------------------------------------------------------------------------

pub fn update_focus_next_advances_one_sentence_test() {
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(0))

  let #(updated, _) = client.update(prior, FocusNext)

  assert updated == Model(..prior, focused_sentence: Some(1))
}

pub fn update_focus_next_skips_erased_sentence_test() {
  // Sentence 1 erased; FocusNext from sentence 0 must skip it and
  // land on sentence 2. Pinning the skip is the core contract for
  // `l` on a partially-erased page.
  let prior =
    Model(
      ..vim_model_on_page(0),
      erased: set.from_list([1]),
      undo_stack: [1],
      focused_sentence: Some(0),
    )

  let #(updated, _) = client.update(prior, FocusNext)

  assert updated == Model(..prior, focused_sentence: Some(2))
}

pub fn update_focus_next_at_end_holds_test() {
  // FocusNext from the document's final sentence is a no-op. The
  // cursor stays put rather than wrapping around to the start.
  let prior = Model(..vim_model_on_page(1), focused_sentence: Some(5))

  let #(updated, _) = client.update(prior, FocusNext)

  assert updated == prior
}

pub fn update_focus_previous_steps_back_one_sentence_test() {
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(2))

  let #(updated, _) = client.update(prior, FocusPrevious)

  assert updated == Model(..prior, focused_sentence: Some(1))
}

pub fn update_focus_previous_at_start_holds_test() {
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(0))

  let #(updated, _) = client.update(prior, FocusPrevious)

  assert updated == prior
}

// ---------------------------------------------------------------------------
// update — FocusNext / FocusPrevious page-boundary crossing
// ---------------------------------------------------------------------------

pub fn update_focus_next_crosses_page_forward_test() {
  // Cursor at the last sentence of page 0 (sentence 2); FocusNext
  // must advance the page to 1 AND set focus to the first non-erased
  // sentence on the new page (sentence 3). The transition is one
  // logical action — the reader presses `l` once and the cursor
  // appears at the top of the next page without a separate
  // ArrowRight press.
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(2))

  let #(updated, _) = client.update(prior, FocusNext)

  assert updated == Model(..prior, current_page: 1, focused_sentence: Some(3))
}

pub fn update_focus_previous_at_page_start_stops_test() {
  // `h` stops at the page boundary. Cursor at the first sentence of
  // page 1 (sentence 3) — there is no previous sentence on page 1,
  // so FocusPrevious is a no-op rather than crossing to page 0.
  let prior = Model(..vim_model_on_page(1), focused_sentence: Some(3))

  let #(updated, _) = client.update(prior, FocusPrevious)

  assert updated == prior
}

pub fn update_focus_next_crossing_page_clears_undo_stack_test() {
  // The vim path through `change_page` shares the same undo-stack
  // contract as the arrow-key path: a real page change commits
  // every undoable erase on the page being left. Pinning this means
  // a future vim-handler that forgot to thread through `change_page`
  // (and skipped the undo clear) fails here.
  let prior =
    Model(
      ..vim_model_on_page(0),
      erased: set.from_list([1]),
      undo_stack: [1],
      focused_sentence: Some(2),
    )

  let #(updated, _) = client.update(prior, FocusNext)

  assert updated
    == Model(
      ..prior,
      current_page: 1,
      undo_stack: [],
      focused_sentence: Some(3),
    )
}

// ---------------------------------------------------------------------------
// update — FocusParagraphDown / FocusParagraphUp
// ---------------------------------------------------------------------------

pub fn update_focus_paragraph_down_jumps_to_next_paragraph_test() {
  // From sentence 0 (paragraph 0), `j` must land on the *first*
  // sentence of paragraph 1 — sentence 2 — not the next sentence in
  // the current paragraph (sentence 1).
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(0))

  let #(updated, _) = client.update(prior, FocusParagraphDown)

  assert updated == Model(..prior, focused_sentence: Some(2))
}

pub fn update_focus_paragraph_down_crosses_page_test() {
  // Paragraph-down from paragraph 1 (last paragraph on page 0)
  // must cross to page 1 and land on the first sentence of
  // paragraph 2.
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(2))

  let #(updated, _) = client.update(prior, FocusParagraphDown)

  assert updated == Model(..prior, current_page: 1, focused_sentence: Some(3))
}

pub fn update_focus_paragraph_up_lands_on_first_of_previous_test() {
  // `k` lands on the *first* sentence of the previous paragraph —
  // sentence 0, not sentence 1 — even though sentence 1 is the
  // closest sentence in the previous paragraph going backward.
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(2))

  let #(updated, _) = client.update(prior, FocusParagraphUp)

  assert updated == Model(..prior, focused_sentence: Some(0))
}

pub fn update_focus_paragraph_up_at_page_start_stops_test() {
  // `k` stops at the page boundary. Cursor at the first paragraph of
  // page 1 (sentence 3 in paragraph 2) — there is no earlier
  // paragraph on page 1, so FocusParagraphUp is a no-op rather than
  // crossing to page 0.
  let prior = Model(..vim_model_on_page(1), focused_sentence: Some(3))

  let #(updated, _) = client.update(prior, FocusParagraphUp)

  assert updated == prior
}

pub fn update_focus_paragraph_down_skips_fully_erased_paragraph_test() {
  // Paragraph 1 is fully erased (sentence 2). `j` from paragraph 0
  // must skip past paragraph 1 and land on the first sentence of
  // paragraph 2 — the cursor doesn't stall on a paragraph with no
  // remaining visible text. The page advance from 0 → 1 also
  // clears the undo stack: page changes commit erases regardless of
  // what triggered them.
  let prior =
    Model(
      ..vim_model_on_page(0),
      erased: set.from_list([2]),
      undo_stack: [2],
      focused_sentence: Some(0),
    )

  let #(updated, _) = client.update(prior, FocusParagraphDown)

  assert updated
    == Model(
      ..prior,
      current_page: 1,
      undo_stack: [],
      focused_sentence: Some(3),
    )
}

// ---------------------------------------------------------------------------
// update — EraseFocused
// ---------------------------------------------------------------------------

pub fn update_erase_focused_erases_and_advances_test() {
  // Space on a focused sentence must (a) insert that sentence's
  // index into `erased`, (b) push it onto `undo_stack`, and (c)
  // advance the cursor forward to the next non-erased sentence.
  // Pinning all three together as one whole-Model comparison stops
  // a future refactor from separating them — losing any one of the
  // three would break the keyboard-erase flow.
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(0))

  let #(updated, _) = client.update(prior, EraseFocused)

  assert updated
    == Model(
      ..prior,
      erased: set.from_list([0]),
      undo_stack: [0],
      focused_sentence: Some(1),
    )
}

pub fn update_erase_focused_advances_page_when_last_visible_test() {
  // Erasing the focused sentence when it's the last visible
  // sentence on the page must advance the cursor (and the page) to
  // the first non-erased sentence on the next page. The reader's
  // erase flow doesn't get wedged at the end of a page.
  //
  // The undo stack clears on the page advance — every page change
  // commits every erase on the page being left, including the one
  // that just triggered the advance. This is consistent with
  // ArrowRight: any page change commits, regardless of what
  // triggered it.
  let prior =
    Model(
      ..vim_model_on_page(0),
      erased: set.from_list([0, 1]),
      undo_stack: [1, 0],
      focused_sentence: Some(2),
    )

  let #(updated, _) = client.update(prior, EraseFocused)

  assert updated
    == Model(
      ..prior,
      current_page: 1,
      erased: set.from_list([0, 1, 2]),
      undo_stack: [],
      focused_sentence: Some(3),
    )
}

pub fn update_erase_focused_with_no_focus_is_noop_test() {
  // Space pressed before any vim navigation key — there is no
  // cursor to act on. The reducer must hold the model unchanged
  // rather than initialising the cursor first.
  let prior = vim_model_on_page(0)

  let #(updated, _) = client.update(prior, EraseFocused)

  assert updated == prior
}

pub fn update_erase_focused_at_end_of_document_clears_cursor_test() {
  // Erasing the final visible sentence anywhere has no forward
  // target to advance to. The reducer parks the cursor as `None`;
  // the next vim key from the reader re-initialises.
  let prior = Model(..vim_model_on_page(1), focused_sentence: Some(5))

  let #(updated, _) = client.update(prior, EraseFocused)

  assert updated
    == Model(
      ..prior,
      erased: set.from_list([5]),
      undo_stack: [5],
      focused_sentence: None,
    )
}

// ---------------------------------------------------------------------------
// update — click/tap erase leaves cursor alone
// ---------------------------------------------------------------------------

pub fn update_erase_sentence_does_not_move_focused_cursor_test() {
  // Click/tap and keyboard are independent input modes. An
  // `EraseSentence` triggered by a click on a non-focused sentence
  // must not move the keyboard cursor — the reader using both
  // hands (mouse + keyboard) would otherwise lose their cursor
  // position every time they clicked.
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(0))

  let #(updated, _) = client.update(prior, EraseSentence(1))

  assert updated
    == Model(
      ..prior,
      erased: set.from_list([1]),
      undo_stack: [1],
      // focused_sentence stays at Some(0), untouched.
    )
}

// ---------------------------------------------------------------------------
// update — page navigation resets cursor in vim mode
// ---------------------------------------------------------------------------

pub fn update_next_page_resets_cursor_when_vim_mode_active_test() {
  // The reader paged forward with ArrowRight while the keyboard
  // cursor was active. The cursor must move to the first non-erased
  // sentence on the new page so it stays on screen — leaving it on
  // the previous page's sentence would let it disappear from view
  // without an obvious recovery.
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(0))

  let #(updated, _) = client.update(prior, NextPage)

  assert updated == Model(..prior, current_page: 1, focused_sentence: Some(3))
}

pub fn update_next_page_keeps_dormant_cursor_dormant_test() {
  // The reader is on a touch device (no vim keys yet). ArrowRight /
  // swipe-left advances the page without waking the cursor up; the
  // visible reading area shouldn't suddenly grow a highlight just
  // because the page turned.
  let prior = vim_model_on_page(0)

  let #(updated, _) = client.update(prior, NextPage)

  assert updated == Model(..prior, current_page: 1)
}

// ---------------------------------------------------------------------------
// view — focused class rendering
// ---------------------------------------------------------------------------

pub fn view_renders_sentence_focused_class_for_cursor_test() {
  // The focused sentence must pick up the `sentence-focused` class
  // so the CSS cursor styling applies. The class appears exactly
  // once in the rendered output (the off-screen measurement
  // container passes `focused: None` and therefore stays unstyled),
  // and it appears on the sentence whose `data-sentence-index`
  // matches `focused_sentence`.
  let prior = Model(..vim_model_on_page(0), focused_sentence: Some(1))

  let rendered = client.view(prior) |> element.to_string

  let focused_chunks =
    rendered |> string.split("sentence sentence-focused") |> list.length
  assert focused_chunks == 2
  assert string.contains(
    rendered,
    "<span class=\"sentence sentence-focused\" data-sentence-index=\"1\">",
  )
}

pub fn view_omits_focused_class_when_cursor_dormant_test() {
  // With `focused_sentence: None`, no sentence carries the cursor
  // styling — neither the visible page nor the measurement mirror.
  // The inverse pin guards against a regression where the class is
  // always emitted (e.g. defaulting to sentence 0).
  let prior = vim_model_on_page(0)

  let rendered = client.view(prior) |> element.to_string

  assert !string.contains(rendered, "sentence-focused")
}

// ---------------------------------------------------------------------------
// update — settings panel toggle
// ---------------------------------------------------------------------------

pub fn update_toggle_settings_opens_then_closes_panel_test() {
  // `ToggleSettings` is a pure model flip — no FFI side effect, no
  // re-pagination. Asserting the whole model both ways pins the
  // invariant that *only* `settings_open` changes; every other field
  // must round-trip unchanged so a future "remember last setting"
  // refactor cannot accidentally reset font size on every gear tap.
  let initial = empty_model()

  let #(opened, _e1) = client.update(initial, ToggleSettings)
  assert opened == Model(..initial, settings_open: True)

  let #(closed, _e2) = client.update(opened, ToggleSettings)
  assert closed == initial
}

// ---------------------------------------------------------------------------
// update — dark / light theme
// ---------------------------------------------------------------------------

pub fn update_toggle_dark_mode_flips_dark_field_test() {
  // Starting from the dark default, one toggle moves us to light.
  // The body-class FFI side effect is observable in production but
  // not in this test environment; the reducer's job is to surface
  // the new model field, which is what we pin.
  let initial = empty_model()

  let #(light, _) = client.update(initial, ToggleDarkMode)
  assert light == Model(..initial, dark_mode: False)

  let #(dark_again, _) = client.update(light, ToggleDarkMode)
  assert dark_again == initial
}

// ---------------------------------------------------------------------------
// update — font size slider
// ---------------------------------------------------------------------------

pub fn update_set_font_size_clamps_below_min_test() {
  // The reducer clamps regardless of slider attributes — a programmatic
  // call (or a malformed event) bypassing the `min=14` HTML attribute
  // must not poison the model. Clamps at the lo rail.
  let #(updated, _) = client.update(empty_model(), SetFontSize(8))
  assert updated == Model(..empty_model(), font_size: client.min_font_size)
}

pub fn update_set_font_size_clamps_above_max_test() {
  // Same clamp invariant at the hi rail.
  let #(updated, _) = client.update(empty_model(), SetFontSize(48))
  assert updated == Model(..empty_model(), font_size: client.max_font_size)
}

pub fn update_set_font_size_stores_in_range_value_test() {
  // A mid-range value is written verbatim — the clamp is a guard,
  // not a quantiser.
  let #(updated, _) = client.update(empty_model(), SetFontSize(22))
  assert updated == Model(..empty_model(), font_size: 22)
}

// ---------------------------------------------------------------------------
// update — line spacing slider
// ---------------------------------------------------------------------------

pub fn update_set_line_spacing_clamps_below_min_test() {
  let #(updated, _) = client.update(empty_model(), SetLineSpacing(0.5))
  assert updated
    == Model(..empty_model(), line_spacing: client.min_line_spacing)
}

pub fn update_set_line_spacing_clamps_above_max_test() {
  let #(updated, _) = client.update(empty_model(), SetLineSpacing(3.5))
  assert updated
    == Model(..empty_model(), line_spacing: client.max_line_spacing)
}

pub fn update_set_line_spacing_stores_in_range_value_test() {
  let #(updated, _) = client.update(empty_model(), SetLineSpacing(1.8))
  assert updated == Model(..empty_model(), line_spacing: 1.8)
}

// ---------------------------------------------------------------------------
// update — ghost mode and ghost opacity
// ---------------------------------------------------------------------------

pub fn update_toggle_ghost_mode_flips_field_test() {
  let initial = empty_model()

  let #(on, _) = client.update(initial, ToggleGhostMode)
  assert on == Model(..initial, ghost_mode: True)

  let #(off, _) = client.update(on, ToggleGhostMode)
  assert off == initial
}

pub fn update_set_ghost_opacity_clamps_below_min_test() {
  // `min_ghost_opacity` is 0.0, but a negative slider value is still
  // clamped — the lo-rail guard is the same shape as the int case.
  let #(updated, _) = client.update(empty_model(), SetGhostOpacity(-0.1))
  assert updated
    == Model(..empty_model(), ghost_opacity: client.min_ghost_opacity)
}

pub fn update_set_ghost_opacity_clamps_above_max_test() {
  let #(updated, _) = client.update(empty_model(), SetGhostOpacity(0.9))
  assert updated
    == Model(..empty_model(), ghost_opacity: client.max_ghost_opacity)
}

pub fn update_set_ghost_opacity_stores_in_range_value_test() {
  let #(updated, _) = client.update(empty_model(), SetGhostOpacity(0.12))
  assert updated == Model(..empty_model(), ghost_opacity: 0.12)
}

// ---------------------------------------------------------------------------
// update — dyslexia-friendly font
// ---------------------------------------------------------------------------

pub fn update_toggle_dyslexia_font_flips_field_test() {
  let initial = empty_model()

  let #(on, _) = client.update(initial, ToggleDyslexiaFont)
  assert on == Model(..initial, dyslexia_font: True)

  let #(off, _) = client.update(on, ToggleDyslexiaFont)
  assert off == initial
}

// ---------------------------------------------------------------------------
// clamp helpers
// ---------------------------------------------------------------------------
//
// `clamp_int` and `clamp_float` are exposed for testing because every
// settings-slider reducer arm delegates to them; pinning the boundary
// behaviour here means a future refactor that swaps the comparison
// operators (e.g. inclusive vs. exclusive bounds) will fail at this
// unit level rather than producing surprising slider behaviour at the
// rails.

pub fn clamp_int_below_lo_returns_lo_test() {
  assert client.clamp_int(-5, 0, 10) == 0
}

pub fn clamp_int_above_hi_returns_hi_test() {
  assert client.clamp_int(99, 0, 10) == 10
}

pub fn clamp_int_in_range_returns_value_test() {
  assert client.clamp_int(7, 0, 10) == 7
}

pub fn clamp_int_at_lo_returns_lo_test() {
  // Boundary inclusivity: `value < lo` not `value <= lo`, so the lo
  // rail itself is "in range" and passes through.
  assert client.clamp_int(0, 0, 10) == 0
}

pub fn clamp_int_at_hi_returns_hi_test() {
  // Mirror inclusivity check at the hi rail.
  assert client.clamp_int(10, 0, 10) == 10
}

pub fn clamp_float_below_lo_returns_lo_test() {
  assert client.clamp_float(-1.5, 0.0, 1.0) == 0.0
}

pub fn clamp_float_above_hi_returns_hi_test() {
  assert client.clamp_float(2.5, 0.0, 1.0) == 1.0
}

pub fn clamp_float_in_range_returns_value_test() {
  assert client.clamp_float(0.42, 0.0, 1.0) == 0.42
}

pub fn clamp_float_at_lo_returns_lo_test() {
  assert client.clamp_float(0.0, 0.0, 1.0) == 0.0
}

pub fn clamp_float_at_hi_returns_hi_test() {
  assert client.clamp_float(1.0, 0.0, 1.0) == 1.0
}

// ---------------------------------------------------------------------------
// erased_opacity_value
// ---------------------------------------------------------------------------

pub fn erased_opacity_value_false_branch_returns_zero_test() {
  // Ghost-mode off — every existing rendering test indirectly pins
  // this branch via `style="opacity:0"` substrings, but having a
  // direct assertion here makes the contract explicit.
  let model = Model(..empty_model(), ghost_mode: False, ghost_opacity: 0.25)
  assert client.erased_opacity_value(model) == "0"
}

pub fn erased_opacity_value_true_branch_returns_ghost_opacity_test() {
  // Ghost-mode on — the value is the configured `ghost_opacity`
  // float, formatted through `float.to_string`. Previously this
  // branch was never exercised in tests, so a refactor that
  // replaced `float.to_string(model.ghost_opacity)` with the literal
  // `"0"` would have passed CI; this assertion catches that.
  let model = Model(..empty_model(), ghost_mode: True, ghost_opacity: 0.18)
  assert client.erased_opacity_value(model) == "0.18"
}

pub fn erased_opacity_value_true_branch_at_default_test() {
  // Default `ghost_opacity` rounds-trips through `float.to_string`
  // — pin the exact string form so a future locale change in the
  // stdlib (e.g. comma decimal separator) is caught.
  let model = Model(..empty_model(), ghost_mode: True)
  assert client.erased_opacity_value(model) == "0.06"
}

// ---------------------------------------------------------------------------
// view — settings panel
// ---------------------------------------------------------------------------
//
// The settings overlay is the only view branch conditional on
// `settings_open`. Closed: no settings markup at all. Open: an
// accessible dialog with three sliders and three toggles. The tests
// below pin the structural contract — aria attributes, slider
// min/max/step values from the public constants, close-button wiring
// — so a refactor of the panel layout cannot silently drop
// accessibility or detune a slider's range.

pub fn view_omits_settings_panel_when_closed_test() {
  let rendered = client.view(empty_model()) |> element.to_string
  assert !string.contains(rendered, "settings-overlay")
  assert !string.contains(rendered, "settings-panel")
}

pub fn view_renders_settings_overlay_when_open_test() {
  // The scrim carries `role="dialog"`, `aria-modal="true"`, and the
  // panel title — all three are required for screen-reader
  // semantics, and dropping any one of them is the kind of change a
  // refactor might make without realising.
  let model = Model(..empty_model(), settings_open: True)

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "aria-label=\"Reader settings\"")
  assert string.contains(rendered, "aria-modal=\"true\"")
  assert string.contains(rendered, "role=\"dialog\"")
  assert string.contains(rendered, "class=\"settings-overlay\"")
  assert string.contains(rendered, "class=\"settings-panel\"")
  assert string.contains(rendered, "Reader settings")
}

pub fn view_settings_close_button_has_accessible_label_test() {
  // The `✕` glyph is visual-only; sighted readers can hit it on
  // shape alone, but a screen-reader needs the aria-label to
  // announce its purpose. The label string is pinned here so the
  // L10n quest that eventually replaces it has one place to update.
  let model = Model(..empty_model(), settings_open: True)

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "aria-label=\"Close settings\"")
}

pub fn view_settings_font_size_slider_carries_bounds_from_constants_test() {
  // The slider's `min` / `max` / `step` attributes come from the
  // public constants on the `client` module. Pinning them here
  // means a future change that raises the cap also has to update
  // the test, which is the right shape — the test enforces the
  // single source of truth.
  let model = Model(..empty_model(), settings_open: True, font_size: 22)

  let rendered = client.view(model) |> element.to_string

  // The aria-label uniquely identifies this slider; from there we
  // can pin every attribute on the same element.
  assert string.contains(rendered, "aria-label=\"Font size in pixels\"")
  assert string.contains(
    rendered,
    "max=\"" <> int.to_string(client.max_font_size) <> "\"",
  )
  assert string.contains(
    rendered,
    "min=\"" <> int.to_string(client.min_font_size) <> "\"",
  )
  assert string.contains(rendered, "step=\"1\"")
  assert string.contains(rendered, "value=\"22\"")
  // The label readout uses the same field, but with a "px" suffix
  // so the reader sees real units rather than a bare integer.
  assert string.contains(rendered, "22px")
}

pub fn view_settings_line_spacing_slider_carries_bounds_test() {
  let model = Model(..empty_model(), settings_open: True, line_spacing: 1.8)

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "aria-label=\"Line spacing multiplier\"")
  assert string.contains(
    rendered,
    "max=\"" <> float.to_string(client.max_line_spacing) <> "\"",
  )
  assert string.contains(
    rendered,
    "min=\"" <> float.to_string(client.min_line_spacing) <> "\"",
  )
  assert string.contains(rendered, "step=\"0.1\"")
  assert string.contains(rendered, "value=\"1.8\"")
}

pub fn view_settings_ghost_opacity_slider_carries_bounds_test() {
  let model = Model(..empty_model(), settings_open: True, ghost_opacity: 0.12)

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "aria-label=\"Ghost mode opacity\"")
  assert string.contains(
    rendered,
    "max=\"" <> float.to_string(client.max_ghost_opacity) <> "\"",
  )
  assert string.contains(
    rendered,
    "min=\"" <> float.to_string(client.min_ghost_opacity) <> "\"",
  )
  assert string.contains(rendered, "step=\"0.01\"")
  assert string.contains(rendered, "value=\"0.12\"")
}

pub fn view_settings_toggles_reflect_model_state_test() {
  // All three toggles read from the model. Pinning the labels
  // confirms each toggle is rendered; pinning the `checked`-attribute
  // count under known model state confirms each toggle's `checked`
  // attribute is wired to the matching model field. Lustre serialises
  // `checked=True` as the bare attribute ` checked` (see
  // `vattr.to_string_tree` — `value: ""` collapses to ` <name>`),
  // so we split on that exact substring.
  let all_on =
    Model(
      ..empty_model(),
      settings_open: True,
      ghost_mode: True,
      dyslexia_font: True,
    )

  let rendered = client.view(all_on) |> element.to_string

  // All three toggle labels are present, in any order.
  assert string.contains(rendered, "Dark mode")
  assert string.contains(rendered, "Ghost mode")
  assert string.contains(rendered, "Dyslexia-friendly font")

  // Three `checked` checkbox renders ⇒ four `split` chunks.
  let checked_chunks = rendered |> string.split(" checked") |> list.length
  assert checked_chunks == 4
}

pub fn view_settings_dyslexia_toggle_unchecked_when_field_false_test() {
  // Asymmetric coverage of the previous test: with only `dark_mode`
  // on, exactly one `checked` substring should appear in the
  // settings panel. This catches a regression where the ghost / dyslexia
  // checkboxes default to checked regardless of model state.
  let model = Model(..empty_model(), settings_open: True)

  let rendered = client.view(model) |> element.to_string

  let checked_chunks = rendered |> string.split(" checked") |> list.length
  assert checked_chunks == 2
}

// ---------------------------------------------------------------------------
// Real-time fade engine
// ---------------------------------------------------------------------------
//
// Fade-engine fixture: two short paragraphs, one sentence each,
// two words per sentence. Word `global_index` runs 0..3 in
// reading order: 0 ("One") and 1 ("two.") in paragraph 0,
// sentence 0; 2 ("Three") and 3 ("four.") in paragraph 1,
// sentence 1. Paginated as two single-paragraph pages so the
// boundary tests can exercise the page-advance path without
// arithmetic acrobatics.

fn fade_text() -> SegmentedText {
  SegmentedText(chapters: [
    Chapter(index: 0, title: None, paragraphs: [
      Paragraph(index: 0, sentences: [
        Sentence(index: 0, global_index: 0, words: [
          Word(index: 0, global_index: 0, text: "One"),
          Word(index: 1, global_index: 1, text: "two."),
        ]),
      ]),
      Paragraph(index: 1, sentences: [
        Sentence(index: 0, global_index: 1, words: [
          Word(index: 0, global_index: 2, text: "Three"),
          Word(index: 1, global_index: 3, text: "four."),
        ]),
      ]),
    ]),
  ])
}

fn fade_pages() -> List(Page) {
  let flat = pagination.flatten(fade_text())
  list.index_map(flat, fn(p, i) { Page(index: i, paragraphs: [p]) })
}

fn fade_model() -> Model {
  let text = fade_text()
  Model(
    ..empty_model(),
    text: Some(text),
    flat_paragraphs: pagination.flatten(text),
    pages: fade_pages(),
    mode: RealTime,
  )
}

// Variant of `fade_pages` that packs both paragraphs onto a
// single page so an `AdvanceWord` tick can cross a paragraph
// boundary without crossing a page boundary. The default
// `fade_pages` puts one paragraph per page, which makes the
// `crosses_paragraph: True` branch of `apply_advance_word`
// geometrically unreachable — every within-page next-target
// resolution lives in the same paragraph.
fn fade_pages_single() -> List(Page) {
  let flat = pagination.flatten(fade_text())
  [Page(index: 0, paragraphs: flat)]
}

fn fade_model_single_page() -> Model {
  let text = fade_text()
  Model(
    ..empty_model(),
    text: Some(text),
    flat_paragraphs: pagination.flatten(text),
    pages: fade_pages_single(),
    mode: RealTime,
  )
}

// ---------------------------------------------------------------------------
// update — SetMode
// ---------------------------------------------------------------------------

pub fn update_set_mode_realtime_flips_mode_only_test() {
  // A Manual → RealTime switch must not auto-start the engine.
  // The reader has to press Space/tap to begin; `mode` flips but
  // `engine_state` stays `Stopped` and `next_word_index` stays
  // `None`. Pinning all three together catches any future "helpful"
  // refactor that decides to start the engine on the mode change.
  let prior = empty_model()

  let #(updated, _effect) = client.update(prior, SetMode(RealTime))

  assert updated == Model(..prior, mode: RealTime)
}

pub fn update_set_mode_manual_stops_running_engine_test() {
  // A RealTime → Manual switch must halt any running engine — the
  // bitset state survives (so previously-faded words stay faded)
  // but `engine_state` resets to `Stopped` and `next_word_index`
  // resets to `None`. The FFI `clear_word_timer` runs as a side
  // effect; we cannot inspect the effect runtime here so we pin the
  // model transition and trust the FFI to honour its contract.
  let prior =
    Model(
      ..fade_model(),
      engine_state: Running,
      next_word_index: Some(2),
      erased_words: set.from_list([0, 1]),
    )

  let #(updated, _effect) = client.update(prior, SetMode(Manual))

  assert updated.mode == Manual
  assert updated.engine_state == Stopped
  assert updated.next_word_index == None
  // Bitsets survive the mode switch — previously faded words stay
  // faded so the reader's progress isn't lost on the toggle.
  assert updated.erased_words == set.from_list([0, 1])
}

// ---------------------------------------------------------------------------
// update — StartFade
// ---------------------------------------------------------------------------

pub fn update_start_fade_initialises_to_first_eligible_word_test() {
  // From a clean RealTime state, StartFade picks the first word in
  // document order on the current page and transitions to Running.
  // Word 0 ("One") is the first word on page 0; it becomes the
  // first fade target.
  let prior = fade_model()

  let #(updated, _effect) = client.update(prior, StartFade)

  assert updated.engine_state == Running
  assert updated.next_word_index == Some(0)
}

pub fn update_start_fade_skips_already_faded_individual_words_test() {
  // The first word on page 0 is already in `erased_words` (e.g.
  // the engine ran once, the reader paused on Stop, and is now
  // restarting via SpacePressed → StartFade after the engine
  // halted mid-page). StartFade must skip that word and pick
  // word 1 — the next eligible word on the current page in
  // document order.
  let prior = Model(..fade_model(), erased_words: set.from_list([0]))

  let #(updated, _effect) = client.update(prior, StartFade)

  assert updated.engine_state == Running
  assert updated.next_word_index == Some(1)
}

pub fn update_start_fade_is_noop_when_no_eligible_word_on_page_test() {
  // Every word on page 0 is already in the bitset (worst case: the
  // reader switched to RealTime after manually erasing the only
  // sentence on this page). StartFade has nothing to schedule, so
  // it stays Stopped. Without this guard, the engine would set
  // `next_word_index` to one of the already-erased words and the
  // first AdvanceWord would no-op forever.
  let prior = Model(..fade_model(), erased_words: set.from_list([0, 1]))

  let #(updated, _effect) = client.update(prior, StartFade)

  assert updated.engine_state == Stopped
  assert updated.next_word_index == None
}

// ---------------------------------------------------------------------------
// update — PauseFade / ResumeFade / StopFade
// ---------------------------------------------------------------------------

pub fn update_pause_fade_transitions_running_to_paused_test() {
  // Pause must (a) flip the engine state and (b) keep
  // `next_word_index` intact so resume picks up at the same word.
  let prior =
    Model(..fade_model(), engine_state: Running, next_word_index: Some(2))

  let #(updated, _effect) = client.update(prior, PauseFade)

  assert updated.engine_state == Paused
  assert updated.next_word_index == Some(2)
}

pub fn update_pause_fade_is_noop_when_not_running_test() {
  // Paused → Paused is a stable state; ditto Stopped → Stopped.
  // Without the guard, a stray Pause from a debounced UI control
  // could overwrite a valid Stopped state with Paused and leave
  // the engine wedged.
  let prior_paused = Model(..fade_model(), engine_state: Paused)
  let prior_stopped = Model(..fade_model(), engine_state: Stopped)

  let #(after_pause_on_paused, _) = client.update(prior_paused, PauseFade)
  let #(after_pause_on_stopped, _) = client.update(prior_stopped, PauseFade)

  assert after_pause_on_paused == prior_paused
  assert after_pause_on_stopped == prior_stopped
}

pub fn update_resume_fade_transitions_paused_to_running_test() {
  let prior =
    Model(..fade_model(), engine_state: Paused, next_word_index: Some(1))

  let #(updated, _effect) = client.update(prior, ResumeFade)

  assert updated.engine_state == Running
  assert updated.next_word_index == Some(1)
}

pub fn update_resume_fade_is_noop_when_not_paused_test() {
  // Symmetric guard to PauseFade. A resume on a Running or Stopped
  // engine is meaningless and must not re-schedule a timer.
  let prior_running = Model(..fade_model(), engine_state: Running)
  let prior_stopped = Model(..fade_model(), engine_state: Stopped)

  let #(after_resume_on_running, _) = client.update(prior_running, ResumeFade)
  let #(after_resume_on_stopped, _) = client.update(prior_stopped, ResumeFade)

  assert after_resume_on_running == prior_running
  assert after_resume_on_stopped == prior_stopped
}

pub fn update_stop_fade_clears_engine_state_and_next_word_test() {
  let prior =
    Model(
      ..fade_model(),
      engine_state: Running,
      next_word_index: Some(2),
      erased_words: set.from_list([0, 1]),
    )

  let #(updated, _effect) = client.update(prior, StopFade)

  assert updated.engine_state == Stopped
  assert updated.next_word_index == None
  // Erased words persist past Stop — the reader expects the
  // already-faded prose to stay faded; only the *timer* stops.
  assert updated.erased_words == set.from_list([0, 1])
}

// ---------------------------------------------------------------------------
// update — AdvanceWord
// ---------------------------------------------------------------------------

pub fn update_advance_word_fades_current_and_picks_next_on_page_test() {
  // Running tick: the current `next_word_index` is added to
  // `erased_words` and the next eligible word in document order
  // becomes the new `next_word_index`. With word 0 in flight on
  // page 0, the new target is word 1 (still in the same sentence
  // / paragraph — no boundary crossing).
  let prior =
    Model(..fade_model(), engine_state: Running, next_word_index: Some(0))

  let #(updated, _effect) = client.update(prior, AdvanceWord)

  assert updated.engine_state == Running
  assert updated.next_word_index == Some(1)
  assert updated.erased_words == set.from_list([0])
}

pub fn update_advance_word_is_noop_when_engine_stopped_test() {
  // Stale-tick guard. A timer callback that survives the
  // synchronous FFI clear (it shouldn't, but the reducer is the
  // belt to the FFI's braces) must not mutate state. Pinning the
  // whole-model equality so a regression that, say, drops a word
  // into `erased_words` without changing `engine_state` also fails
  // here.
  let prior =
    Model(..fade_model(), engine_state: Stopped, next_word_index: None)

  let #(updated, _effect) = client.update(prior, AdvanceWord)

  assert updated == prior
}

pub fn update_advance_word_is_noop_when_engine_paused_test() {
  // Pause-induced stale-tick guard. Same rationale as the Stopped
  // case — a callback that fires after `PauseFade` should be
  // absorbed without changing the bitset.
  let prior =
    Model(..fade_model(), engine_state: Paused, next_word_index: Some(1))

  let #(updated, _effect) = client.update(prior, AdvanceWord)

  assert updated == prior
}

pub fn update_advance_word_advances_to_next_page_when_current_page_exhausted_test() {
  // Word 1 is the last eligible word on page 0. After fading it,
  // the engine must walk forward to page 1, set the target to the
  // first eligible word on that page (word 2), and stay Running.
  // The page-delay milliseconds are baked into the scheduled
  // effect (not directly observable here) — the model-level pin
  // is the page change plus the new word target.
  let prior =
    Model(
      ..fade_model(),
      engine_state: Running,
      next_word_index: Some(1),
      erased_words: set.from_list([0]),
    )

  let #(updated, _effect) = client.update(prior, AdvanceWord)

  assert updated.engine_state == Running
  assert updated.current_page == 1
  assert updated.next_word_index == Some(2)
  assert updated.erased_words == set.from_list([0, 1])
}

pub fn update_advance_word_crosses_paragraph_boundary_within_same_page_test() {
  // The `crosses_paragraph: True` branch of `apply_advance_word`
  // is load-bearing for the Paragraph-pause slider: when the
  // engine ticks forward from the last word of one paragraph
  // into the first word of the next paragraph on the *same*
  // page, the schedule should add `paragraph_delay_ms` on top
  // of the per-word interval. The single-page fixture packs
  // both paragraphs onto page 0 so word 1 → word 2 crosses a
  // paragraph boundary without crossing a page boundary; the
  // default `fade_pages` puts one paragraph per page, which
  // makes this branch geometrically unreachable.
  //
  // The delay value itself lives inside the scheduled
  // `schedule_advance_word` Effect and is opaque to tests — the
  // model-level pin is the next-target selection, which
  // exercises the cross-paragraph arm of `next_eligible_after`.
  // A regression that mis-resolves the paragraph boundary
  // (e.g. treats the page as a single paragraph and skips
  // straight to `None`, falling through to
  // `advance_to_next_page`) would fail this pin by reporting
  // `current_page == 1`.
  let prior =
    Model(
      ..fade_model_single_page(),
      engine_state: Running,
      next_word_index: Some(1),
      erased_words: set.from_list([0]),
    )

  let #(updated, _effect) = client.update(prior, AdvanceWord)

  assert updated.engine_state == Running
  assert updated.current_page == 0
  assert updated.next_word_index == Some(2)
  assert updated.erased_words == set.from_list([0, 1])
}

pub fn update_advance_word_skips_words_in_manually_erased_sentences_test() {
  // Sentence 1 was manually erased before the engine started.
  // After fading word 1 on page 0, the engine looks ahead and
  // finds no eligible word on page 0 (correct — page 0 is done),
  // crosses to page 1 to look for the next target, and finds
  // *none* there either because both words on page 1 belong to
  // erased sentence 1. The engine then stops gracefully rather
  // than spinning on an empty document.
  let prior =
    Model(
      ..fade_model(),
      engine_state: Running,
      next_word_index: Some(1),
      erased: set.from_list([1]),
      erased_words: set.from_list([0]),
    )

  let #(updated, _effect) = client.update(prior, AdvanceWord)

  assert updated.engine_state == Stopped
  assert updated.next_word_index == None
  assert updated.erased_words == set.from_list([0, 1])
}

pub fn update_advance_word_stops_engine_at_end_of_document_test() {
  // Word 3 is the last word of the last page. After fading it,
  // there is no next eligible word anywhere — the engine
  // transitions to Stopped and clears `next_word_index` so a
  // subsequent SpacePressed will Start-from-scratch instead of
  // pretending to Resume.
  let prior =
    Model(
      ..fade_model(),
      current_page: 1,
      engine_state: Running,
      next_word_index: Some(3),
      erased_words: set.from_list([0, 1, 2]),
    )

  let #(updated, _effect) = client.update(prior, AdvanceWord)

  assert updated.engine_state == Stopped
  assert updated.next_word_index == None
  assert updated.erased_words == set.from_list([0, 1, 2, 3])
}

// ---------------------------------------------------------------------------
// update — SpacePressed
// ---------------------------------------------------------------------------

pub fn update_space_pressed_in_realtime_starts_engine_when_stopped_test() {
  let prior = fade_model()

  let #(updated, _effect) = client.update(prior, SpacePressed)

  assert updated.engine_state == Running
  assert updated.next_word_index == Some(0)
}

pub fn update_space_pressed_in_realtime_pauses_running_engine_test() {
  let prior =
    Model(..fade_model(), engine_state: Running, next_word_index: Some(1))

  let #(updated, _effect) = client.update(prior, SpacePressed)

  assert updated.engine_state == Paused
  assert updated.next_word_index == Some(1)
}

pub fn update_space_pressed_in_realtime_resumes_paused_engine_test() {
  let prior =
    Model(..fade_model(), engine_state: Paused, next_word_index: Some(2))

  let #(updated, _effect) = client.update(prior, SpacePressed)

  assert updated.engine_state == Running
  assert updated.next_word_index == Some(2)
}

pub fn update_space_pressed_in_manual_mode_invokes_erase_focused_test() {
  // In Manual mode `SpacePressed` must be equivalent to the
  // pre-fade-engine `EraseFocused` keybind: erase the focused
  // sentence and advance the cursor to the next visible one. The
  // sentinel is the focused-sentence transition — pre: 0, post: 1.
  // The mode field stays `Manual` and the engine state stays
  // `Stopped`, so the fade machinery is fully bypassed.
  let prior = Model(..fade_model(), mode: Manual, focused_sentence: Some(0))

  let #(updated, _effect) = client.update(prior, SpacePressed)

  assert updated.mode == Manual
  assert updated.engine_state == Stopped
  assert set.contains(updated.erased, 0)
  assert updated.focused_sentence == Some(1)
}

// ---------------------------------------------------------------------------
// update — Set* clamping on the new sliders
// ---------------------------------------------------------------------------

pub fn update_set_wpm_clamps_into_range_test() {
  let prior = empty_model()
  let #(low, _) = client.update(prior, SetWpm(0))
  let #(high, _) = client.update(prior, SetWpm(10_000))
  let #(mid, _) = client.update(prior, SetWpm(220))

  assert low.wpm == client.min_wpm
  assert high.wpm == client.max_wpm
  assert mid.wpm == 220
}

pub fn update_set_paragraph_delay_clamps_into_range_test() {
  let prior = empty_model()
  let #(low, _) = client.update(prior, SetParagraphDelay(-500))
  let #(high, _) = client.update(prior, SetParagraphDelay(99_999))
  let #(mid, _) = client.update(prior, SetParagraphDelay(1500))

  assert low.paragraph_delay_ms == client.min_paragraph_delay_ms
  assert high.paragraph_delay_ms == client.max_paragraph_delay_ms
  assert mid.paragraph_delay_ms == 1500
}

pub fn update_set_page_delay_clamps_into_range_test() {
  let prior = empty_model()
  let #(low, _) = client.update(prior, SetPageDelay(-100))
  let #(high, _) = client.update(prior, SetPageDelay(99_999))
  let #(mid, _) = client.update(prior, SetPageDelay(2500))

  assert low.page_delay_ms == client.min_page_delay_ms
  assert high.page_delay_ms == client.max_page_delay_ms
  assert mid.page_delay_ms == 2500
}

// ---------------------------------------------------------------------------
// update — TouchEnd routing in RealTime mode
// ---------------------------------------------------------------------------

pub fn update_touch_end_tap_in_realtime_mode_starts_fade_engine_test() {
  // The touch-end Tap classification, which is a no-op in Manual
  // mode (taps on sentences erase via the synthesised `click`
  // event, not through the `Tap` outcome), routes to
  // `SpacePressed` in RealTime mode. From a Stopped engine this
  // starts the fade.
  let prior = Model(..fade_model(), touch_start: Some(#(100.0, 100.0)))

  // Coordinates close to the start coordinate → classifies as Tap.
  let #(updated, _effect) = client.update(prior, TouchEnd(101.0, 101.0))

  assert updated.touch_start == None
  assert updated.engine_state == Running
  assert updated.next_word_index == Some(0)
}

pub fn update_touch_end_tap_in_realtime_mode_pauses_running_engine_test() {
  // Same Tap path, this time toggling a Running engine into Paused
  // — the page-tap pause/resume affordance the brief calls out.
  let prior =
    Model(
      ..fade_model(),
      engine_state: Running,
      next_word_index: Some(1),
      touch_start: Some(#(100.0, 100.0)),
    )

  let #(updated, _effect) = client.update(prior, TouchEnd(102.0, 100.0))

  assert updated.engine_state == Paused
  assert updated.next_word_index == Some(1)
}

pub fn update_touch_end_swipe_left_still_advances_page_in_realtime_mode_test() {
  // The page-swipe gesture must remain wired to NextPage even in
  // RealTime mode — the reader still needs a way to skip ahead
  // manually. This pins that the RealTime tap-routing addition
  // didn't accidentally swallow swipe gestures alongside taps.
  let prior = Model(..fade_model(), touch_start: Some(#(200.0, 100.0)))

  // dx = -100 → SwipeLeft (> swipe_threshold, mostly horizontal).
  let #(updated, _effect) = client.update(prior, TouchEnd(100.0, 100.0))

  assert updated.current_page == 1
}

// ---------------------------------------------------------------------------
// view — word-level fade rendering
// ---------------------------------------------------------------------------

pub fn view_word_in_erased_words_carries_opacity_style_test() {
  // The fade engine writes a word's `global_index` into
  // `erased_words`; the view must reflect that as an inline
  // `style="opacity:..."` on the matching word span. The CSS
  // transition does the visible fade; the inline style is the
  // hook the rule transitions against.
  let model = Model(..fade_model(), erased_words: set.from_list([0]))

  let rendered = client.view(model) |> element.to_string

  // Inline-styled word with global_index 0, opacity 0. Pinning
  // the substring against the rendered span verifies the
  // attribute is on the word — not, say, on the parent sentence.
  // Lustre emits CSS declarations with a trailing semicolon
  // (`opacity:0;`), so the substring matches that exact form.
  assert string.contains(
    rendered,
    "data-global-index=\"0\" style=\"opacity:0;\"",
  )
  // The companion word (global_index 1) on the same page is NOT
  // in `erased_words`, so it must NOT carry the inline opacity.
  // A negative substring assertion catches the symmetric failure
  // mode: a future change that inlines opacity on every word
  // (regardless of bitset membership) would still pass the
  // positive case above.
  assert !string.contains(rendered, "data-global-index=\"1\" style=\"opacity")
}

pub fn view_word_in_realtime_mode_disables_sentence_click_handler_test() {
  // In RealTime mode, sentence spans must not carry a click
  // handler — a tap on a sentence pauses/resumes the engine via
  // the page-level Tap routing, not erases the sentence.
  let sentence =
    Sentence(index: 0, global_index: 0, words: [
      Word(index: 0, global_index: 0, text: "Hi."),
    ])

  let click_events =
    client.view_sentence(
      sentence,
      set.new(),
      None,
      True,
      "0",
      set.new(),
      RealTime,
    )
    |> click_event_names

  assert click_events == []
}

// ---------------------------------------------------------------------------
// view — settings panel (fade-engine additions)
// ---------------------------------------------------------------------------

pub fn view_settings_mode_toggle_renders_with_realtime_off_by_default_test() {
  // The mode toggle is the entry point to RealTime mode. With
  // the default model (`Manual`), the toggle must render
  // unchecked. Asserting just the label string is insufficient —
  // a regression that flipped `default_mode` to `RealTime` or
  // hard-coded `attribute.checked(True)` would pass silently.
  //
  // `empty_model()` defaults to `dark_mode: True` and every
  // other toggleable setting `False`, so a settings panel with
  // the default model should render exactly one `checked`
  // attribute (the dark-mode toggle). Two split chunks ⇒ one
  // checked substring, which pins the mode toggle's off state
  // by elimination.
  let model = Model(..empty_model(), settings_open: True)

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "Real-time fade mode")
  let checked_chunks = rendered |> string.split(" checked") |> list.length
  assert checked_chunks == 2
}

pub fn view_settings_mode_toggle_renders_checked_when_realtime_test() {
  // Asymmetric counterpart to the off-by-default test: when
  // `model.mode == RealTime`, the mode toggle must render
  // checked. With `dark_mode: True` (the `empty_model` default)
  // and `mode: RealTime`, the settings panel should render
  // exactly two `checked` attributes — three split chunks —
  // catching a regression where `view_mode_toggle` hard-codes
  // `attribute.checked(False)`.
  let model = Model(..empty_model(), settings_open: True, mode: RealTime)

  let rendered = client.view(model) |> element.to_string

  let checked_chunks = rendered |> string.split(" checked") |> list.length
  assert checked_chunks == 3
}

pub fn view_settings_wpm_slider_carries_bounds_from_constants_test() {
  let model = Model(..empty_model(), settings_open: True, wpm: 250)

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "aria-label=\"Words per minute\"")
  assert string.contains(
    rendered,
    "max=\"" <> int.to_string(client.max_wpm) <> "\"",
  )
  assert string.contains(
    rendered,
    "min=\"" <> int.to_string(client.min_wpm) <> "\"",
  )
  assert string.contains(rendered, "step=\"10\"")
  assert string.contains(rendered, "value=\"250\"")
  assert string.contains(rendered, "250 wpm")
}

pub fn view_settings_paragraph_delay_slider_carries_bounds_test() {
  let model =
    Model(..empty_model(), settings_open: True, paragraph_delay_ms: 1500)

  let rendered = client.view(model) |> element.to_string

  assert string.contains(
    rendered,
    "aria-label=\"Paragraph pause in milliseconds\"",
  )
  assert string.contains(
    rendered,
    "max=\"" <> int.to_string(client.max_paragraph_delay_ms) <> "\"",
  )
  assert string.contains(
    rendered,
    "min=\"" <> int.to_string(client.min_paragraph_delay_ms) <> "\"",
  )
  assert string.contains(rendered, "value=\"1500\"")
  assert string.contains(rendered, "1500 ms")
}

pub fn view_settings_page_delay_slider_carries_bounds_test() {
  let model = Model(..empty_model(), settings_open: True, page_delay_ms: 2500)

  let rendered = client.view(model) |> element.to_string

  assert string.contains(rendered, "aria-label=\"Page pause in milliseconds\"")
  assert string.contains(
    rendered,
    "max=\"" <> int.to_string(client.max_page_delay_ms) <> "\"",
  )
  assert string.contains(
    rendered,
    "min=\"" <> int.to_string(client.min_page_delay_ms) <> "\"",
  )
  assert string.contains(rendered, "value=\"2500\"")
  assert string.contains(rendered, "2500 ms")
}
