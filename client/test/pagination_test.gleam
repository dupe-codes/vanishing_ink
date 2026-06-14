//// Unit tests for the pure pagination engine. The algorithm is
//// exercised against synthetic paragraph height maps so the
//// assertions don't depend on a browser DOM — the FFI surface that
//// produces real heights is tested implicitly by the renderer at
//// runtime, and not here.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit

import shared/segmenter.{
  type Paragraph, type SegmentedText, Chapter, Paragraph, SegmentedText,
  Sentence, Word,
}

import client/pagination.{Page}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

fn synthetic_paragraph(local_index: Int, text: String) -> Paragraph {
  Paragraph(index: local_index, sentences: [
    Sentence(index: 0, global_index: 0, words: [
      Word(index: 0, global_index: 0, text: text),
    ]),
  ])
}

fn three_paragraph_book() -> SegmentedText {
  SegmentedText(chapters: [
    Chapter(index: 0, title: None, paragraphs: [
      synthetic_paragraph(0, "Alpha"),
      synthetic_paragraph(1, "Beta"),
      synthetic_paragraph(2, "Gamma"),
    ]),
  ])
}

fn two_chapter_book() -> SegmentedText {
  SegmentedText(chapters: [
    Chapter(index: 0, title: Some("Prelude"), paragraphs: [
      synthetic_paragraph(0, "First"),
      synthetic_paragraph(1, "Second"),
    ]),
    Chapter(index: 1, title: None, paragraphs: [
      synthetic_paragraph(0, "Third"),
    ]),
    Chapter(index: 2, title: Some("Finale"), paragraphs: [
      synthetic_paragraph(0, "Fourth"),
      synthetic_paragraph(1, "Fifth"),
    ]),
  ])
}

// ---------------------------------------------------------------------------
// flatten
// ---------------------------------------------------------------------------

pub fn flatten_assigns_book_wide_global_indices_in_reading_order_test() {
  let book = two_chapter_book()

  let flat = pagination.flatten(book)

  let indices = list.map(flat, fn(p) { p.global_index })
  assert indices == [0, 1, 2, 3, 4]
}

pub fn flatten_emits_chapter_index_per_paragraph_test() {
  // Each `PageParagraph` carries the chapter it came from. The view
  // doesn't currently render the chapter index, but future quests
  // (a chapter-navigator, say) will read it off the model, and
  // pagination is the single place that resolves "which chapter
  // does this paragraph belong to".
  let book = two_chapter_book()

  let chapter_indices =
    pagination.flatten(book) |> list.map(fn(p) { p.chapter_index })

  assert chapter_indices == [0, 0, 1, 2, 2]
}

pub fn flatten_attaches_title_only_to_first_paragraph_of_titled_chapter_test() {
  // Titles ride with the first paragraph of their chapter so they
  // can never end up orphaned on the page preceding their chapter's
  // first paragraph. Untitled chapters carry `None` on every
  // paragraph; titled chapters carry `Some(title)` only on
  // paragraph 0.
  let book = two_chapter_book()

  let titles = pagination.flatten(book) |> list.map(fn(p) { p.chapter_title })

  assert titles == [Some("Prelude"), None, None, Some("Finale"), None]
}

pub fn flatten_empty_book_yields_empty_list_test() {
  let empty = SegmentedText(chapters: [])

  let flat = pagination.flatten(empty)

  assert flat == []
}

pub fn flatten_skips_empty_chapters_without_breaking_indexing_test() {
  // A chapter with no paragraphs contributes nothing to the flat
  // list, and the global paragraph indices count only emitted
  // paragraphs. So a [empty, two-paragraph] book yields global
  // indices [0, 1] — not [0, 1, 2] or anything that "skips" the
  // empty chapter's slot.
  let book =
    SegmentedText(chapters: [
      Chapter(index: 0, title: Some("Empty"), paragraphs: []),
      Chapter(index: 1, title: None, paragraphs: [
        synthetic_paragraph(0, "A"),
        synthetic_paragraph(1, "B"),
      ]),
    ])

  let indices = pagination.flatten(book) |> list.map(fn(p) { p.global_index })

  assert indices == [0, 1]
}

// ---------------------------------------------------------------------------
// calculate_pages
// ---------------------------------------------------------------------------

pub fn calculate_pages_returns_empty_for_empty_paragraph_list_test() {
  let pages = pagination.calculate_pages([], dict.new(), 500.0)

  assert pages == []
}

pub fn calculate_pages_packs_paragraphs_greedily_until_budget_exceeded_test() {
  // Three 100px paragraphs into a 250px budget: pack the first two
  // (200px ≤ 250px), then the third (100px) starts a new page
  // because 200 + 100 = 300 > 250. Two pages of [2, 1] paragraphs.
  let flat = pagination.flatten(three_paragraph_book())
  let heights =
    pagination.heights_from_pairs([#(0, 100.0), #(1, 100.0), #(2, 100.0)])

  let pages = pagination.calculate_pages(flat, heights, 250.0)

  assert list.length(pages) == 2
  let assert [first, second] = pages
  assert list.length(first.paragraphs) == 2
  assert list.length(second.paragraphs) == 1
  assert first.index == 0
  assert second.index == 1
}

pub fn calculate_pages_gives_oversized_paragraph_its_own_page_test() {
  // A paragraph taller than the budget would, naively, never fit
  // and could either get dropped or wedge an empty-page-forever
  // loop. The algorithm puts it on its own page instead — pages
  // always contain ≥ 1 paragraph, and oversized paragraphs visually
  // overflow rather than silently disappearing.
  let flat = pagination.flatten(three_paragraph_book())
  let heights =
    pagination.heights_from_pairs([
      #(0, 50.0),
      #(1, 9999.0),
      #(2, 50.0),
    ])

  let pages = pagination.calculate_pages(flat, heights, 100.0)

  // 50px fits on page 0; 9999px on its own page 1; 50px on page 2.
  assert list.length(pages) == 3
  let assert [page_0, page_1, page_2] = pages
  assert list.length(page_0.paragraphs) == 1
  assert list.length(page_1.paragraphs) == 1
  assert list.length(page_2.paragraphs) == 1
}

pub fn calculate_pages_treats_missing_heights_as_zero_test() {
  // Defensive: if a paragraph's height is missing from the
  // measurement map (the FFI may, in theory, skip a node it can't
  // parse), it gets a zero height rather than throwing. Pagination
  // produces output and the layout is wrong; that's a better
  // failure mode than wedging the whole reader.
  let flat = pagination.flatten(three_paragraph_book())
  // Heights only for paragraphs 0 and 2; paragraph 1 is missing.
  let heights = pagination.heights_from_pairs([#(0, 60.0), #(2, 60.0)])

  let pages = pagination.calculate_pages(flat, heights, 100.0)

  // 60 + 0 = 60 ≤ 100 → paragraphs 0 and 1 fit together; 60 again
  // exceeds → paragraph 2 starts a new page.
  assert list.length(pages) == 2
  let assert [first, second] = pages
  assert list.length(first.paragraphs) == 2
  assert list.length(second.paragraphs) == 1
}

pub fn calculate_pages_one_paragraph_per_page_when_budget_is_tight_test() {
  let flat = pagination.flatten(three_paragraph_book())
  let heights =
    pagination.heights_from_pairs([#(0, 80.0), #(1, 80.0), #(2, 80.0)])

  let pages = pagination.calculate_pages(flat, heights, 50.0)

  assert list.length(pages) == 3
}

pub fn calculate_pages_all_paragraphs_on_one_page_when_budget_is_generous_test() {
  let flat = pagination.flatten(three_paragraph_book())
  let heights =
    pagination.heights_from_pairs([#(0, 50.0), #(1, 50.0), #(2, 50.0)])

  let pages = pagination.calculate_pages(flat, heights, 10_000.0)

  assert list.length(pages) == 1
  let assert [only] = pages
  assert list.length(only.paragraphs) == 3
}

pub fn calculate_pages_indexes_pages_from_zero_in_order_test() {
  // Page indices must match each page's position in the returned
  // list so `current_page` can be used as a direct index. A
  // regression here would silently misroute next/previous
  // navigation.
  let flat = pagination.flatten(three_paragraph_book())
  let heights =
    pagination.heights_from_pairs([#(0, 100.0), #(1, 100.0), #(2, 100.0)])

  let pages = pagination.calculate_pages(flat, heights, 50.0)

  let indices = list.map(pages, fn(p) { p.index })
  assert indices == [0, 1, 2]
}

// ---------------------------------------------------------------------------
// clamp_page_index
// ---------------------------------------------------------------------------

pub fn clamp_page_index_keeps_in_bounds_unchanged_test() {
  assert pagination.clamp_page_index(2, 5) == 2
}

pub fn clamp_page_index_floors_negative_at_zero_test() {
  assert pagination.clamp_page_index(-3, 5) == 0
}

pub fn clamp_page_index_caps_at_last_page_test() {
  assert pagination.clamp_page_index(7, 5) == 4
}

pub fn clamp_page_index_returns_zero_when_no_pages_test() {
  // No pages → the only sensible index is 0 (a sentinel that the
  // view recognises as "nothing to render here"); never -1 or a
  // value that would crash an index lookup.
  assert pagination.clamp_page_index(0, 0) == 0
  assert pagination.clamp_page_index(7, 0) == 0
  assert pagination.clamp_page_index(-3, 0) == 0
}

// ---------------------------------------------------------------------------
// nth
// ---------------------------------------------------------------------------

pub fn nth_returns_the_indexed_page_when_in_bounds_test() {
  let pages = [
    Page(index: 0, paragraphs: []),
    Page(index: 1, paragraphs: []),
    Page(index: 2, paragraphs: []),
  ]

  assert case pagination.nth(pages, 1) {
    Some(page) -> page.index == 1
    None -> False
  }
}

pub fn nth_returns_none_when_index_out_of_bounds_test() {
  let pages = [Page(index: 0, paragraphs: [])]

  assert pagination.nth(pages, 5) == None
  assert pagination.nth(pages, -1) == None
}

// ---------------------------------------------------------------------------
// sentence-anchor resolution
// ---------------------------------------------------------------------------
//
// These tests pin the cross-device reading-position machinery: the
// reading position is persisted as a sentence `global_index` anchor
// rather than a raw page index because pagination is viewport-dependent.
// The fixture below carries one sentence per paragraph with DISTINCT
// sentence `global_index` values (0..3) — `synthetic_paragraph` above
// hardcodes `global_index: 0` on every sentence, which cannot
// distinguish anchors, so anchor tests need their own fixture.

/// Four paragraphs, one sentence each, sentence `global_index` 0..3.
/// `flatten` leaves sentence indices untouched, so the hardcoded values
/// flow through to the paginated pages.
fn four_sentence_book() -> SegmentedText {
  let para = fn(idx: Int, text: String) -> Paragraph {
    Paragraph(index: idx, sentences: [
      Sentence(index: 0, global_index: idx, words: [
        Word(index: 0, global_index: idx, text: text),
      ]),
    ])
  }
  SegmentedText(chapters: [
    Chapter(index: 0, title: None, paragraphs: [
      para(0, "Alpha"),
      para(1, "Beta"),
      para(2, "Gamma"),
      para(3, "Delta"),
    ]),
  ])
}

pub fn page_for_sentence_index_resolves_known_index_to_its_page_test() {
  // Two paragraphs per page → sentence global_index 2 sits on page 1.
  let flat = pagination.flatten(four_sentence_book())
  let heights =
    pagination.heights_from_pairs([
      #(0, 100.0),
      #(1, 100.0),
      #(2, 100.0),
      #(3, 100.0),
    ])
  let pages = pagination.calculate_pages(flat, heights, 250.0)

  assert pagination.page_for_sentence_index(pages, 0) == 0
  assert pagination.page_for_sentence_index(pages, 1) == 0
  assert pagination.page_for_sentence_index(pages, 2) == 1
  assert pagination.page_for_sentence_index(pages, 3) == 1
}

pub fn page_for_sentence_index_defaults_to_zero_when_pages_empty_test() {
  // Pagination has not run yet (the GET/pagination race). The caller
  // additionally parks the anchor for re-resolution, but the primitive
  // itself must not crash — page 0 is the document-start default.
  assert pagination.page_for_sentence_index([], 7) == 0
}

pub fn page_for_sentence_index_defaults_to_zero_for_unknown_index_test() {
  // A stale anchor that belongs to a different book (survived a book
  // swap) resolves to no page; the primitive returns the safe
  // document-start default rather than a negative or out-of-range index.
  let flat = pagination.flatten(four_sentence_book())
  let heights =
    pagination.heights_from_pairs([
      #(0, 100.0),
      #(1, 100.0),
      #(2, 100.0),
      #(3, 100.0),
    ])
  let pages = pagination.calculate_pages(flat, heights, 250.0)

  assert pagination.page_for_sentence_index(pages, 999) == 0
}

pub fn first_sentence_index_on_page_reads_the_top_sentence_test() {
  // Two paragraphs per page: page 0 opens on sentence 0, page 1 opens
  // on sentence 2. This is the anchor the client persists for the
  // reader's current page.
  let flat = pagination.flatten(four_sentence_book())
  let heights =
    pagination.heights_from_pairs([
      #(0, 100.0),
      #(1, 100.0),
      #(2, 100.0),
      #(3, 100.0),
    ])
  let pages = pagination.calculate_pages(flat, heights, 250.0)

  assert pagination.first_sentence_index_on_page(pages, 0) == Some(0)
  assert pagination.first_sentence_index_on_page(pages, 1) == Some(2)
}

pub fn first_sentence_index_on_page_is_none_when_page_out_of_range_test() {
  // Pagination pending (empty pages) or an index past the last page
  // yields `None`, which the caller maps onto the `-1` "no anchor"
  // wire sentinel.
  assert pagination.first_sentence_index_on_page([], 0) == None

  let flat = pagination.flatten(four_sentence_book())
  let heights =
    pagination.heights_from_pairs([
      #(0, 100.0),
      #(1, 100.0),
      #(2, 100.0),
      #(3, 100.0),
    ])
  let pages = pagination.calculate_pages(flat, heights, 250.0)
  assert pagination.first_sentence_index_on_page(pages, 99) == None
}

pub fn same_anchor_resolves_across_different_paginations_test() {
  // THE CORE REGRESSION. The same sentence anchor (global_index 2),
  // restored under two DIFFERENT paginations of the same text, must
  // land on the page that actually CONTAINS that sentence — NOT on a
  // fixed raw page index. This is the exact cross-device divergence the
  // anchor exists to close: page N on one viewport is not page N on
  // another.
  let flat = pagination.flatten(four_sentence_book())
  let heights =
    pagination.heights_from_pairs([
      #(0, 100.0),
      #(1, 100.0),
      #(2, 100.0),
      #(3, 100.0),
    ])

  // "Desktop" viewport: a tall budget packs two paragraphs per page.
  // Sentence 2 lands on page 1.
  let desktop_pages = pagination.calculate_pages(flat, heights, 250.0)
  // "Phone" viewport: a short budget forces one paragraph per page.
  // The same sentence 2 now lands on page 2.
  let phone_pages = pagination.calculate_pages(flat, heights, 50.0)

  let desktop_page = pagination.page_for_sentence_index(desktop_pages, 2)
  let phone_page = pagination.page_for_sentence_index(phone_pages, 2)

  // Different raw page indices — proving the resolution is
  // pagination-aware, not a stored constant.
  assert desktop_page == 1
  assert phone_page == 2
  assert desktop_page != phone_page

  // And each resolved page genuinely contains the anchor sentence:
  // its first sentence round-trips back to the anchor.
  assert pagination.first_sentence_index_on_page(desktop_pages, desktop_page)
    == Some(2)
  assert pagination.first_sentence_index_on_page(phone_pages, phone_page)
    == Some(2)
}
