//// Vim-style cursor navigation. Pure functions over the paginated
//// page list and the erased-sentence set; no DOM, no effects, no
//// Lustre coupling. The reducer in `client.gleam` calls into this
//// module to compute where the keyboard cursor should land for each
//// `h`/`j`/`k`/`l`/`Space` input and then commits the answer back to
//// the model.
////
//// Navigation only visits non-erased sentences — the cursor cannot
//// land on a sentence the reader has already erased. Pagination
//// boundaries are crossed implicitly: when the next visible sentence
//// in document order lives on a different page, the caller is
//// expected to update `current_page` so the new focused sentence is
//// actually on screen.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}

import client/pagination.{type Page}

/// One sentence's location across pages, the unit of cursor
/// navigation. `page_index` matches `Page.index`,
/// `paragraph_global_index` matches `PageParagraph.global_index`,
/// `sentence_global_index` matches `Sentence.global_index`.
pub type SentenceLocation {
  SentenceLocation(
    page_index: Int,
    paragraph_global_index: Int,
    sentence_global_index: Int,
  )
}

/// Direction of cursor travel. `Forward` advances toward the end of
/// the document; `Backward` toward the start.
pub type Direction {
  Forward
  Backward
}

/// Flatten the paginated page list into a single ordered list of
/// `SentenceLocation`s in document reading order. The list is
/// rebuilt on every navigation message — every operation here is
/// linear in the document size, and the alternative (caching it on
/// the model) means invalidating the cache on every `TextLoaded` /
/// `ParagraphsMeasured` / `EraseSentence` for negligible payoff.
pub fn locate_sentences(pages: List(Page)) -> List(SentenceLocation) {
  pages
  |> list.flat_map(fn(page) {
    page.paragraphs
    |> list.flat_map(fn(page_paragraph) {
      page_paragraph.paragraph.sentences
      |> list.map(fn(sentence) {
        SentenceLocation(
          page_index: page.index,
          paragraph_global_index: page_paragraph.global_index,
          sentence_global_index: sentence.global_index,
        )
      })
    })
  })
}

/// First non-erased sentence on `page_index`, or `None` when every
/// sentence on that page is erased (or the page is empty). Used to
/// initialise the cursor on first vim-key press and to settle the
/// cursor after a forward page navigation.
pub fn first_on_page(
  locations: List(SentenceLocation),
  page_index: Int,
  erased: Set(Int),
) -> Option(SentenceLocation) {
  locations
  |> list.find(fn(loc) {
    loc.page_index == page_index
    && !set.contains(erased, loc.sentence_global_index)
  })
  |> option.from_result
}

/// Next non-erased sentence strictly after `current` in `direction`.
/// `current` is matched on `sentence_global_index`. The current
/// sentence is excluded from the result regardless of its erase
/// status — `next_sentence` walks past it before searching. Returns
/// `None` when no visible sentence exists in the requested
/// direction.
///
/// Backward navigation stops at the page boundary: if the previous
/// sentence lives on an earlier page, `None` is returned instead of
/// crossing to that page. Forward navigation crosses freely.
pub fn next_sentence(
  locations: List(SentenceLocation),
  current: Int,
  erased: Set(Int),
  direction: Direction,
) -> Option(SentenceLocation) {
  case direction {
    Forward ->
      locations
      |> drop_through(current)
      |> list.find(fn(loc) { !set.contains(erased, loc.sentence_global_index) })
      |> option.from_result

    Backward -> {
      let current_page =
        locations
        |> list.find(fn(loc) { loc.sentence_global_index == current })
        |> option.from_result
        |> option.map(fn(loc) { loc.page_index })
      case current_page {
        None -> None
        Some(page) ->
          locations
          |> list.filter(fn(loc) { loc.page_index == page })
          |> list.reverse
          |> drop_through(current)
          |> list.find(fn(loc) {
            !set.contains(erased, loc.sentence_global_index)
          })
          |> option.from_result
      }
    }
  }
}

/// First non-erased sentence of the immediately adjacent paragraph
/// in `direction` that still has a visible sentence. Fully-erased
/// paragraphs are skipped — the cursor never gets wedged on a
/// paragraph with no remaining text. Used for `j` (Forward) and `k`
/// (Backward).
///
/// Forward and backward share the "first non-erased sentence in the
/// target paragraph" landing rule. The target paragraph itself is
/// chosen differently per direction: forward picks the next
/// paragraph in document order with any visible content; backward
/// picks the most recent earlier paragraph with any visible
/// content.
pub fn next_paragraph_sentence(
  locations: List(SentenceLocation),
  current_paragraph: Int,
  erased: Set(Int),
  direction: Direction,
) -> Option(SentenceLocation) {
  case direction {
    Forward ->
      locations
      |> list.find(fn(loc) {
        loc.paragraph_global_index > current_paragraph
        && !set.contains(erased, loc.sentence_global_index)
      })
      |> option.from_result

    Backward -> {
      // Backward paragraph-jump stops at the page boundary: only
      // paragraphs on the same page as current_paragraph are eligible.
      let current_page =
        locations
        |> list.find(fn(loc) { loc.paragraph_global_index == current_paragraph })
        |> option.from_result
        |> option.map(fn(loc) { loc.page_index })
      case current_page {
        None -> None
        Some(page) -> {
          let candidates =
            locations
            |> list.filter(fn(loc) {
              loc.paragraph_global_index < current_paragraph
              && loc.page_index == page
              && !set.contains(erased, loc.sentence_global_index)
            })
          case list.last(candidates) {
            Error(_) -> None
            Ok(last_candidate) -> {
              // `candidates` is in document order, so `list.last` is
              // the highest paragraph_global_index strictly less than
              // current_paragraph on the same page that still has a
              // visible sentence. Re-scan for the first sentence in
              // that paragraph — the top of the previous visible
              // paragraph, where `k` should land.
              let target_paragraph = last_candidate.paragraph_global_index
              candidates
              |> list.find(fn(loc) {
                loc.paragraph_global_index == target_paragraph
              })
              |> option.from_result
            }
          }
        }
      }
    }
  }
}

/// Look up a sentence by its `sentence_global_index`. The reducer
/// uses this to read the focused sentence's paragraph before a
/// paragraph-boundary navigation, since the cursor stores only the
/// sentence index.
pub fn locate(
  locations: List(SentenceLocation),
  sentence_global_index: Int,
) -> Option(SentenceLocation) {
  locations
  |> list.find(fn(loc) { loc.sentence_global_index == sentence_global_index })
  |> option.from_result
}

/// Drop every entry up to and including the one whose
/// `sentence_global_index == target`. When `target` is absent the
/// result is `[]` — the caller's `list.find` then produces `None`
/// rather than silently scanning from the document start.
fn drop_through(
  locations: List(SentenceLocation),
  target: Int,
) -> List(SentenceLocation) {
  case locations {
    [] -> []
    [head, ..rest] ->
      case head.sentence_global_index == target {
        True -> rest
        False -> drop_through(rest, target)
      }
  }
}
