//// Unit tests for the `client/navigation` module. All assertions
//// run on hand-built page fixtures so the test surface matches the
//// shape `client.gleam` produces from `pagination.flatten`/
//// `pagination.calculate_pages` — same field names, same global
//// indices — without going through the segmenter.

import gleam/option.{None, Some}
import gleam/set

import gleeunit

import client/navigation.{
  Backward, Forward, SentenceLocation, first_on_page, locate, locate_sentences,
  next_paragraph_sentence, next_sentence,
}
import client/pagination.{type Page, type PageParagraph, Page, PageParagraph}
import shared/segmenter.{
  type Paragraph, type Sentence, Paragraph, Sentence, Word,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

/// Build a single-word sentence carrying the supplied indices. The
/// word's `global_index` is set to the same value as the
/// sentence's, which is enough for the navigation tests — they
/// never inspect word indices.
fn sentence(local_index: Int, global_index: Int) -> Sentence {
  Sentence(index: local_index, global_index: global_index, words: [
    Word(index: 0, global_index: global_index, text: "x"),
  ])
}

fn paragraph(local_index: Int, sentences: List(Sentence)) -> Paragraph {
  Paragraph(index: local_index, sentences: sentences)
}

fn page_paragraph(
  global_index: Int,
  chapter_index: Int,
  paragraph: Paragraph,
) -> PageParagraph {
  PageParagraph(
    global_index: global_index,
    chapter_index: chapter_index,
    chapter_title: None,
    paragraph: paragraph,
  )
}

/// Two pages, two paragraphs each, three sentences total.
///
/// Page 0:
///   Paragraph 0 — sentences 0, 1
///   Paragraph 1 — sentence  2
/// Page 1:
///   Paragraph 2 — sentence  3
///   Paragraph 3 — sentences 4, 5
fn two_page_layout() -> List(Page) {
  [
    Page(index: 0, paragraphs: [
      page_paragraph(0, 0, paragraph(0, [sentence(0, 0), sentence(1, 1)])),
      page_paragraph(1, 0, paragraph(1, [sentence(0, 2)])),
    ]),
    Page(index: 1, paragraphs: [
      page_paragraph(2, 0, paragraph(0, [sentence(0, 3)])),
      page_paragraph(3, 0, paragraph(1, [sentence(0, 4), sentence(1, 5)])),
    ]),
  ]
}

// ---------------------------------------------------------------------------
// locate_sentences
// ---------------------------------------------------------------------------

pub fn locate_sentences_flattens_pages_in_document_order_test() {
  // Every sentence on every page must appear exactly once, in
  // document order, with the correct page and paragraph indices.
  // This is the foundation every other navigation helper builds on
  // — if the flattening is wrong, every subsequent test would still
  // pass against the wrong underlying order.
  let locations = locate_sentences(two_page_layout())

  assert locations
    == [
      SentenceLocation(
        page_index: 0,
        paragraph_global_index: 0,
        sentence_global_index: 0,
      ),
      SentenceLocation(
        page_index: 0,
        paragraph_global_index: 0,
        sentence_global_index: 1,
      ),
      SentenceLocation(
        page_index: 0,
        paragraph_global_index: 1,
        sentence_global_index: 2,
      ),
      SentenceLocation(
        page_index: 1,
        paragraph_global_index: 2,
        sentence_global_index: 3,
      ),
      SentenceLocation(
        page_index: 1,
        paragraph_global_index: 3,
        sentence_global_index: 4,
      ),
      SentenceLocation(
        page_index: 1,
        paragraph_global_index: 3,
        sentence_global_index: 5,
      ),
    ]
}

pub fn locate_sentences_on_empty_pages_returns_empty_test() {
  // Before pagination has produced any pages (initial paint after
  // `TextLoaded`), navigation queries must still return well-typed
  // empty results rather than panicking.
  assert locate_sentences([]) == []
}

// ---------------------------------------------------------------------------
// first_on_page
// ---------------------------------------------------------------------------

pub fn first_on_page_returns_first_non_erased_in_document_order_test() {
  let locations = locate_sentences(two_page_layout())

  assert first_on_page(locations, 0, set.new())
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 0,
      sentence_global_index: 0,
    ))
}

pub fn first_on_page_skips_erased_sentences_test() {
  // Erasing the first two sentences must push the cursor onto the
  // third sentence (still on page 0), not silently land on an erased
  // entry — the visual would put the cursor on invisible text.
  let locations = locate_sentences(two_page_layout())

  assert first_on_page(locations, 0, set.from_list([0, 1]))
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 1,
      sentence_global_index: 2,
    ))
}

pub fn first_on_page_returns_none_when_every_sentence_erased_test() {
  // A page with every sentence erased has no valid landing spot.
  // The caller is expected to either advance the page or stash the
  // cursor as `None` until the reader takes another action.
  let locations = locate_sentences(two_page_layout())

  assert first_on_page(locations, 0, set.from_list([0, 1, 2])) == None
}

pub fn first_on_page_returns_none_for_unknown_page_test() {
  let locations = locate_sentences(two_page_layout())

  assert first_on_page(locations, 99, set.new()) == None
}

// ---------------------------------------------------------------------------
// next_sentence — forward
// ---------------------------------------------------------------------------

pub fn next_sentence_forward_steps_one_sentence_test() {
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 0, set.new(), Forward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 0,
      sentence_global_index: 1,
    ))
}

pub fn next_sentence_forward_skips_erased_test() {
  // Sentence 1 is erased — Forward navigation from 0 must skip past
  // it and land on sentence 2. Pinning the skip is the core
  // contract for `l` over a partially-erased page.
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 0, set.from_list([1]), Forward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 1,
      sentence_global_index: 2,
    ))
}

pub fn next_sentence_forward_crosses_page_boundary_test() {
  // Sentence 2 is the last on page 0; Forward must land on the
  // first sentence of page 1. The reducer reads `page_index` off
  // the returned location to drive the page change.
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 2, set.new(), Forward)
    == Some(SentenceLocation(
      page_index: 1,
      paragraph_global_index: 2,
      sentence_global_index: 3,
    ))
}

pub fn next_sentence_forward_at_end_of_document_returns_none_test() {
  // Sentence 5 is the last sentence anywhere; Forward must return
  // `None` so the reducer holds the cursor in place rather than
  // wrapping to the document start.
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 5, set.new(), Forward) == None
}

pub fn next_sentence_forward_when_current_already_erased_test() {
  // The cursor is parked on a sentence that has been erased via
  // click (input modes are independent). Forward navigation must
  // still advance — the cursor isn't trapped on an erased sentence
  // even when it happened to start there.
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 1, set.from_list([1]), Forward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 1,
      sentence_global_index: 2,
    ))
}

// ---------------------------------------------------------------------------
// next_sentence — backward
// ---------------------------------------------------------------------------

pub fn next_sentence_backward_steps_one_sentence_test() {
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 2, set.new(), Backward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 0,
      sentence_global_index: 1,
    ))
}

pub fn next_sentence_backward_skips_erased_test() {
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 2, set.from_list([1]), Backward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 0,
      sentence_global_index: 0,
    ))
}

pub fn next_sentence_backward_crosses_page_boundary_test() {
  // Sentence 3 is the first on page 1; Backward must land on the
  // last sentence of page 0.
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 3, set.new(), Backward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 1,
      sentence_global_index: 2,
    ))
}

pub fn next_sentence_backward_at_start_returns_none_test() {
  let locations = locate_sentences(two_page_layout())

  assert next_sentence(locations, 0, set.new(), Backward) == None
}

// ---------------------------------------------------------------------------
// next_paragraph_sentence — forward (j)
// ---------------------------------------------------------------------------

pub fn next_paragraph_sentence_forward_jumps_to_next_paragraph_test() {
  // From sentence 0 (paragraph 0), `j` must land on the first
  // sentence of paragraph 1 — i.e. sentence 2, not sentence 1
  // (still in paragraph 0).
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 0, set.new(), Forward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 1,
      sentence_global_index: 2,
    ))
}

pub fn next_paragraph_sentence_forward_crosses_page_boundary_test() {
  // From paragraph 1 (last on page 0), `j` must land on the first
  // sentence of paragraph 2, which lives on page 1.
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 1, set.new(), Forward)
    == Some(SentenceLocation(
      page_index: 1,
      paragraph_global_index: 2,
      sentence_global_index: 3,
    ))
}

pub fn next_paragraph_sentence_forward_skips_fully_erased_paragraphs_test() {
  // Paragraph 1 (sentence 2) is erased; `j` from paragraph 0 must
  // not land on the erased sentence — it must skip past paragraph 1
  // and land on the first sentence of paragraph 2 instead. Pinning
  // this guards against a regression where the cursor freezes on a
  // partially-readable paragraph because the algorithm "found"
  // paragraph 1 with no visible sentences.
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 0, set.from_list([2]), Forward)
    == Some(SentenceLocation(
      page_index: 1,
      paragraph_global_index: 2,
      sentence_global_index: 3,
    ))
}

pub fn next_paragraph_sentence_forward_lands_on_first_non_erased_test() {
  // First sentence of paragraph 3 (sentence 4) is erased; `j` must
  // land on sentence 5 — the next non-erased sentence within
  // paragraph 3, not skip to a paragraph 4 that doesn't exist.
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 2, set.from_list([4]), Forward)
    == Some(SentenceLocation(
      page_index: 1,
      paragraph_global_index: 3,
      sentence_global_index: 5,
    ))
}

pub fn next_paragraph_sentence_forward_at_end_returns_none_test() {
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 3, set.new(), Forward) == None
}

// ---------------------------------------------------------------------------
// next_paragraph_sentence — backward (k)
// ---------------------------------------------------------------------------

pub fn next_paragraph_sentence_backward_jumps_to_first_of_previous_test() {
  // From paragraph 1, `k` lands on the *first* sentence of
  // paragraph 0 — sentence 0, not sentence 1. "First sentence of
  // the previous paragraph" is the operating contract; landing on
  // the last sentence would mean the cursor never reaches the top
  // of a paragraph.
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 1, set.new(), Backward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 0,
      sentence_global_index: 0,
    ))
}

pub fn next_paragraph_sentence_backward_crosses_page_boundary_test() {
  // From paragraph 2 (first on page 1), `k` must land on the first
  // sentence of paragraph 1 — which is on page 0.
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 2, set.new(), Backward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 1,
      sentence_global_index: 2,
    ))
}

pub fn next_paragraph_sentence_backward_skips_fully_erased_paragraphs_test() {
  // Paragraph 1 is fully erased; `k` from paragraph 2 must skip it
  // and land on the first sentence of paragraph 0.
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 2, set.from_list([2]), Backward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 0,
      sentence_global_index: 0,
    ))
}

pub fn next_paragraph_sentence_backward_lands_on_first_non_erased_in_target_test() {
  // The target paragraph (0) has its first sentence erased; `k`
  // must land on the next non-erased sentence within that
  // paragraph (sentence 1).
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 1, set.from_list([0]), Backward)
    == Some(SentenceLocation(
      page_index: 0,
      paragraph_global_index: 0,
      sentence_global_index: 1,
    ))
}

pub fn next_paragraph_sentence_backward_at_start_returns_none_test() {
  let locations = locate_sentences(two_page_layout())

  assert next_paragraph_sentence(locations, 0, set.new(), Backward) == None
}

// ---------------------------------------------------------------------------
// locate
// ---------------------------------------------------------------------------

pub fn locate_finds_existing_sentence_test() {
  let locations = locate_sentences(two_page_layout())

  assert locate(locations, 3)
    == Some(SentenceLocation(
      page_index: 1,
      paragraph_global_index: 2,
      sentence_global_index: 3,
    ))
}

pub fn locate_returns_none_for_unknown_sentence_test() {
  let locations = locate_sentences(two_page_layout())

  assert locate(locations, 999) == None
}
