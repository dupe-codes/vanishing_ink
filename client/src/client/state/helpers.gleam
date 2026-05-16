//// Pure model-mutation helpers and small numeric utilities. Lifted
//// out of `client/state` so the type-and-constants module stays
//// under the 800-line file budget. Every function here operates on
//// the `Model` (or its scalar components) without producing any
//// side-effects — the reducer, the engine, and the view layer all
//// route through this module for the page-navigation and progress-
//// computation primitives.

import gleam/float
import gleam/int
import gleam/list
import gleam/option

import client/navigation
import client/pagination.{type Page}
import client/state.{type ChapterEntry, type Model, ChapterEntry, Model}
import shared/segmenter.{type SegmentedText}

/// Resolve the opacity string applied to erased sentences. Returns
/// `"0"` when ghost mode is off so the bundled rendered-HTML tests
/// (which pin `opacity:0;`) stay stable; otherwise the configured
/// ghost-opacity float. The string is threaded through every
/// rendering function rather than read from a CSS custom property
/// because the rendered HTML — not the cascade — drives the
/// transition's start/end values; the cascade alone wouldn't change
/// the inline style, and the fade wouldn't fire.
///
/// Exposed so the ghost-mode tests can assert both branches without
/// reaching through the view layer — the `False` branch is implicitly
/// covered by every existing rendering test, but the `True` branch
/// has no view-level pin yet.
pub fn erased_opacity_value(model: Model) -> String {
  case model.ghost_mode {
    False -> "0"
    True -> float.to_string(model.ghost_opacity)
  }
}

/// Walk the segmented text once and return `#(sentences, words)`.
/// Called from the `TextLoaded` reducer so the result can be cached
/// on the model — the totals do not change between loads, so the
/// view layer reads them from constant fields instead of re-walking
/// the whole book on every render.
///
/// One fold is used rather than the previous twin `list.flat_map`
/// chains: at the design phase a 100k-word book would have driven
/// the view-time cost into the hundreds of thousands of list
/// traversals per second under fade-engine pacing. Caching removes
/// that cost; the single fold here also halves the one-time cost
/// at load.
pub fn total_counts(text: SegmentedText) -> #(Int, Int) {
  list.fold(text.chapters, #(0, 0), fn(chapter_acc, chapter) {
    list.fold(chapter.paragraphs, chapter_acc, fn(paragraph_acc, paragraph) {
      list.fold(paragraph.sentences, paragraph_acc, fn(sentence_acc, sentence) {
        let #(sentences, words) = sentence_acc
        #(sentences + 1, words + list.length(sentence.words))
      })
    })
  })
}

/// Reading progress as a page-based percentage, rounded to one
/// decimal place. Computed as
/// `(current_page + 1) / total_pages * 100` so a reader on the first
/// of ten pages reads as 10%, and the last page reads as 100% — the
/// `+1` reflects that `current_page` is a zero-based index, and the
/// reader has reached the *end* of that page rather than the start.
///
/// **Helper-purity, not system-purity.** The helper itself is
/// viewport-pure: given `current_page` and `total_pages`, the same
/// inputs always produce the same percentage. But both inputs are
/// derived from the *current* viewport's pagination pass, so the
/// *persisted* `reading_state.percent_progress` is
/// viewport-of-last-save — whatever the saving viewport happened to
/// compute. A reader who saves at 50% on a phone and re-opens on a
/// desktop will see the library card display the phone's saved
/// percentage until the next save overwrites it with the desktop
/// viewport's live computation. The system property the page-based
/// model improves on is *fade-mechanic independence* (the percentage
/// no longer drifts when the reader pages ahead without erasing
/// every sentence), not viewport-of-last-save independence.
///
/// Reads from cached `current_page` / `total_pages` fields on the
/// model. The previous revision (the erased-words and -sentences
/// model) was tightly coupled to the fade / erase mechanic and
/// drifted away from the reader's actual reading position whenever
/// they paged ahead without erasing every sentence — the new
/// computation tracks the page turns the reader is actually making.
///
/// Returns `0.0` when `total_pages` is `0` — the cache is reset to
/// `0` between `TextLoaded` and the first `ParagraphsMeasured`, so
/// guarding against the divide-by-zero keeps the helper total
/// during the pagination-pending window.
///
/// `float.to_precision(_, 1)` snaps the result to a single decimal
/// digit so the serialised `width:<n>%` style is a clean prefix
/// (`33.3`, `40.0`) rather than the float's full-precision
/// expansion (`33.333333333333%`). The CSS transition reads the
/// truncated value just as faithfully, and the rendered HTML tests
/// can pin the full value instead of a prefix substring.
pub fn progress_percentage(model: Model) -> Float {
  // Postcondition invariant: a non-zero `total_pages` yields a
  // percentage in `(0.0, 100.0]` because `current_page` is clamped
  // into `[0, total_pages - 1]` by `change_page`, so the numerator
  // `(current_page + 1)` is in `[1, total_pages]`. The zero-pages
  // branch returns the literal `0.0`.
  case model.total_pages {
    0 -> 0.0
    total ->
      int.to_float(model.current_page + 1) /. int.to_float(total) *. 100.0
      |> float.to_precision(1)
  }
}

/// Look up the title of the chapter the current page sits in.
/// Returns the chapter's title when one is present, an empty
/// string otherwise. Called from the three reducer arms that
/// mutate any of `text` / `pages` / `current_page` to refresh
/// the cached `Model.current_chapter_title` field; the view
/// reads the cached field rather than calling this helper on
/// every render.
///
/// The lookup walks the page → first paragraph → `chapter_index`
/// chain so the slot tracks the reader as they cross chapter
/// boundaries: a page that opens inside chapter 1 shows chapter 1's
/// title even when the previous page belonged to chapter 0.
///
/// Falls through to `""` rather than crashing when:
/// * `text` is `None` (pre-`TextLoaded` — header is not rendered
///   today, but the helper stays total),
/// * `pages` is empty (the pagination-pending window after
///   `TextLoaded` and before the first `ParagraphsMeasured`),
/// * the resolved chapter carries `title: None`.
pub fn compute_current_chapter_title(
  text: option.Option(SegmentedText),
  pages: List(Page),
  current_page: Int,
) -> String {
  case text {
    option.None -> ""
    option.Some(t) ->
      case pagination.nth(pages, current_page) {
        option.None -> ""
        option.Some(page) ->
          case page.paragraphs {
            [] -> ""
            [first, ..] -> chapter_title_at(t, first.chapter_index)
          }
      }
  }
}

pub fn chapter_title_at(text: SegmentedText, chapter_index: Int) -> String {
  case list.find(text.chapters, fn(c) { c.index == chapter_index }) {
    Ok(chapter) -> option.unwrap(chapter.title, "")
    Error(_) -> ""
  }
}

/// Lower-level page change: clamps `candidate` into the valid
/// page range and clears the undo stack only when the page
/// actually changes. Shared between `go_to_page` (the
/// touch/arrow-key path) and `move_focus` (the vim path) — both
/// need the same "no page change, no undo-stack clear" invariant
/// and pulling the logic into one helper stops the two callers
/// from drifting apart.
///
/// Refreshes both `current_chapter_title` (the page may have
/// crossed a chapter boundary) and `chapter_entries` (the Jump
/// Ahead menu's forward-only chapter list, which now needs to
/// drop any chapter the reader has just paged past). Centralising
/// both refreshes here means every caller — the touch/arrow path
/// through `go_to_page`, the vim path through `move_focus`, the
/// engine's `advance_to_next_page_loop`, and the Jump Ahead path
/// through `apply_jump_to_page` — gets the cached fields kept in
/// lock-step for free.
pub fn change_page(model: Model, candidate: Int) -> Model {
  // Read the cached `total_pages` — same rationale as
  // `advance_to_next_page`: the invariant
  // `total_pages == list.length(pages)` makes the cache the
  // canonical source, and using it everywhere prevents future
  // readers from wondering which call site is authoritative.
  let clamped = pagination.clamp_page_index(candidate, model.total_pages)
  case clamped == model.current_page {
    True -> model
    False -> {
      // Refresh the cached chapter title against the new page —
      // crossing chapter boundaries on `NextPage` (or the
      // navigation paths) is the routine cache-invalidation
      // trigger.
      let chapter_title =
        compute_current_chapter_title(model.text, model.pages, clamped)
      let chapter_entries = compute_chapter_entries(model.pages, clamped)
      Model(
        ..model,
        current_page: clamped,
        undo_stack: [],
        current_chapter_title: chapter_title,
        chapter_entries: chapter_entries,
      )
    }
  }
}

/// Move the reader to `candidate` after clamping to the current
/// `pages` range. Rejects any `candidate` less than `current_page`
/// — backward page navigation is disabled; only forward movement is
/// permitted. Clears `undo_stack` only when `clamped` differs from
/// `current_page` — a real page change commits every erase that has
/// not yet been undone, but a clamp-to-self (ArrowRight on the last
/// page) must leave the undo stack intact so a reader's stray reflex
/// tap does not silently destroy undoable erases.
///
/// Used by `NextPage`/swipes — input modes where the reader pages
/// forward through the book. When `focused_sentence` is `Some(_)`
/// (i.e. the reader is in vim mode) and the page actually changes,
/// the cursor resets to the first non-erased sentence on the new
/// page. Vim-key navigation bypasses this helper through
/// `change_page`/`move_focus` because the navigation module decides
/// exactly where the cursor should land.
pub fn go_to_page(model: Model, candidate: Int) -> Model {
  case candidate < model.current_page {
    True -> model
    False -> {
      let after = change_page(model, candidate)
      let focused = case after.current_page == model.current_page {
        True -> model.focused_sentence
        False ->
          case model.focused_sentence {
            option.None -> option.None
            option.Some(_) ->
              navigation.first_on_page(
                navigation.locate_sentences(after.pages),
                after.current_page,
                after.erased,
              )
              |> option.map(fn(loc) { loc.sentence_global_index })
          }
      }
      Model(..after, focused_sentence: focused)
    }
  }
}

/// Walk a paginated page list once and return one `ChapterEntry`
/// per titled chapter whose first page sits strictly after
/// `current_page`. The returned entries are in page-ascending order
/// — the same order the Jump Ahead menu renders them in.
///
/// Only titled chapters appear: untitled chapters carry
/// `chapter_title: None` on their first `PageParagraph` and have no
/// label to show in the menu. A reader who wants to skip into an
/// untitled chapter uses the page-number input below the chapter
/// list instead.
///
/// "First occurrence" is enforced by `seen_chapters`: a chapter
/// whose first paragraph straddles two pages (rare — only when the
/// page break lands inside a single paragraph) only emits the
/// page where the title rides. Subsequent pages of the same
/// chapter never carry `chapter_title: Some(_)`, so the guard is
/// belt-and-braces for the pagination invariant.
pub fn compute_chapter_entries(
  pages: List(Page),
  current_page: Int,
) -> List(ChapterEntry) {
  pages
  |> list.fold(#([], []), fn(acc, page) {
    let #(entries_rev, seen_chapters) = acc
    case page.index > current_page {
      False -> #(entries_rev, seen_chapters)
      True ->
        case first_titled_chapter(page.paragraphs, seen_chapters) {
          option.None -> #(entries_rev, seen_chapters)
          option.Some(#(title, chapter_index)) -> {
            let entry =
              ChapterEntry(
                title: title,
                page_index: page.index,
                chapter_index: chapter_index,
              )
            #([entry, ..entries_rev], [chapter_index, ..seen_chapters])
          }
        }
    }
  })
  |> pair_first
  |> list.reverse
}

/// Read the first titled paragraph on a page whose chapter is not
/// already in `seen_chapters`. Returns `Some(#(title, chapter_index))`
/// when one is found and `None` otherwise. Pulled into its own helper
/// so `compute_chapter_entries`'s fold body stays short.
fn first_titled_chapter(
  paragraphs: List(pagination.PageParagraph),
  seen_chapters: List(Int),
) -> option.Option(#(String, Int)) {
  case paragraphs {
    [] -> option.None
    [first, ..rest] ->
      case first.chapter_title {
        option.Some(title) ->
          case list.contains(seen_chapters, first.chapter_index) {
            True -> first_titled_chapter(rest, seen_chapters)
            False -> option.Some(#(title, first.chapter_index))
          }
        option.None -> first_titled_chapter(rest, seen_chapters)
      }
  }
}

/// Return the first element of a `#(a, b)` tuple. Local because
/// `gleam/pair` is not yet imported here and threading a one-line
/// helper through the import surface costs more than the helper.
fn pair_first(pair: #(a, b)) -> a {
  let #(a, _) = pair
  a
}
