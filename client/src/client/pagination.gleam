//// Pagination engine for the reader. Pure Gleam — no DOM, no
//// effects — so the algorithm can be exercised in tests without a
//// browser.
////
//// The model is two-phase:
////
//// 1. `flatten` walks a `SegmentedText` into a flat ordered list of
////    `PageParagraph` values, each carrying a document-global
////    paragraph index. The first paragraph of every titled chapter
////    carries the chapter title; subsequent paragraphs in the same
////    chapter carry `None`.
////
//// 2. `calculate_pages` consumes that flat list plus a `(global_index,
////    rendered_height)` measurement map and an `available_height`
////    budget, and returns the page boundaries — a list of `Page`
////    values, each holding the `PageParagraph`s that fit on it.
////
//// Pagination breaks between paragraphs, never inside them, so a
//// single paragraph taller than the budget still occupies its own
//// page rather than splitting across pages.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

import shared/segmenter.{type Paragraph, type SegmentedText}

/// One paginated unit in document order. `global_index` is unique
/// across the whole `SegmentedText` and identifies the paragraph for
/// height-measurement lookups. `chapter_title` is `Some(title)` only
/// for the first paragraph of a titled chapter — the view uses this
/// to render the chapter heading inline with the paragraph that
/// follows it.
pub type PageParagraph {
  PageParagraph(
    global_index: Int,
    chapter_index: Int,
    chapter_title: Option(String),
    paragraph: Paragraph,
  )
}

/// A single page: an ordered list of `PageParagraph`s plus a
/// zero-based page index. `index` is the page's position in the
/// `pages` list and the value `current_page` should hold to display
/// it.
pub type Page {
  Page(index: Int, paragraphs: List(PageParagraph))
}

// ---------------------------------------------------------------------------
// Flattening
// ---------------------------------------------------------------------------

/// Walk a `SegmentedText` into a flat list of `PageParagraph`s.
/// Paragraphs are emitted in document reading order; `global_index`
/// counts from zero across the whole book. The first paragraph of a
/// titled chapter carries that title — every other paragraph carries
/// `None`, even within the same chapter.
pub fn flatten(text: SegmentedText) -> List(PageParagraph) {
  let #(_, paragraphs_rev) =
    list.fold(text.chapters, #(0, []), fn(outer, chapter) {
      list.index_fold(chapter.paragraphs, outer, fn(inner, paragraph, idx) {
        let #(global, acc_rev) = inner
        let title = case idx, chapter.title {
          0, Some(title) -> Some(title)
          _, _ -> None
        }
        let page_paragraph =
          PageParagraph(
            global_index: global,
            chapter_index: chapter.index,
            chapter_title: title,
            paragraph: paragraph,
          )
        #(global + 1, [page_paragraph, ..acc_rev])
      })
    })
  list.reverse(paragraphs_rev)
}

// ---------------------------------------------------------------------------
// Page-boundary calculation
// ---------------------------------------------------------------------------

/// Group a flat list of `PageParagraph`s into pages whose total
/// rendered height does not exceed `available_height`.
///
/// `heights` maps each paragraph's `global_index` to its measured
/// pixel height. Paragraphs whose `global_index` is absent from the
/// map are treated as zero-height — pagination should not fail when
/// a measurement is missing, even though the layout will be wrong.
///
/// A paragraph that on its own exceeds `available_height` still
/// occupies its own page: pages always contain at least one
/// paragraph, and pagination never splits mid-paragraph.
///
/// **CSS contract:** the `heights` values must come from elements
/// that establish a block formatting context — in practice the
/// `.page-paragraph` wrappers in `client.gleam`, which use
/// `display: flow-root` (see `styles.css`). `flow-root` contains the
/// inner `.paragraph` bottom margin inside the wrapper, so
/// `getBoundingClientRect().height` equals the full vertical space
/// the paragraph occupies on-page, including the trailing gap. Heights
/// measured without `flow-root` would silently exclude that margin and
/// overflow content off page bottoms.
///
/// Returns `[]` when the input is empty.
pub fn calculate_pages(
  paragraphs: List(PageParagraph),
  heights: Dict(Int, Float),
  available_height: Float,
) -> List(Page) {
  let folded =
    list.fold(paragraphs, #(0.0, [], []), fn(acc, paragraph) {
      let #(current_height, current_rev, pages_rev) = acc
      let height =
        heights |> dict.get(paragraph.global_index) |> result.unwrap(0.0)
      let exceeds = current_height +. height >. available_height
      let has_existing_content = current_rev != []
      case exceeds && has_existing_content {
        True -> #(height, [paragraph], [list.reverse(current_rev), ..pages_rev])
        False -> #(
          current_height +. height,
          [paragraph, ..current_rev],
          pages_rev,
        )
      }
    })

  let #(_, last_page_rev, pages_rev) = folded
  let all_pages_rev = case last_page_rev {
    [] -> pages_rev
    _ -> [list.reverse(last_page_rev), ..pages_rev]
  }

  all_pages_rev
  |> list.reverse
  |> list.index_map(fn(page_paragraphs, index) {
    Page(index: index, paragraphs: page_paragraphs)
  })
}

/// Build the `heights` dict the pagination algorithm consumes from
/// the `(global_index, height)` pairs returned by the FFI.
pub fn heights_from_pairs(pairs: List(#(Int, Float))) -> Dict(Int, Float) {
  dict.from_list(pairs)
}

// ---------------------------------------------------------------------------
// Navigation helpers
// ---------------------------------------------------------------------------

/// Clamp a candidate page index into the half-open range
/// `[0, total_pages)`. Returns `0` when `total_pages <= 0` (no pages
/// to navigate yet).
pub fn clamp_page_index(candidate: Int, total_pages: Int) -> Int {
  case total_pages <= 0 {
    True -> 0
    False -> candidate |> int.max(0) |> int.min(total_pages - 1)
  }
}

/// Look up a page by index. Returns `None` when the index is out of
/// bounds — used by the view to render a placeholder rather than
/// panic when called before pagination has run.
pub fn nth(pages: List(Page), index: Int) -> Option(Page) {
  case index < 0 {
    True -> None
    False ->
      case pages |> list.drop(index) {
        [page, ..] -> Some(page)
        [] -> None
      }
  }
}
