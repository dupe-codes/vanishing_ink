//// Forward-only text search for the Jump Ahead menu. Walks the
//// paginated `pages` list from `current_page + 1` onward, joins each
//// page's word texts into a flat searchable string, and produces one
//// `SearchResult` per matching page with a ~50-character snippet
//// centred on the first hit.
////
//// Pure Gleam, no DOM, no effects — the reducer calls the entry point
//// from `apply_set_jump_search_query` on every keystroke, and the
//// per-call cost is bounded by the cap on results and by the
//// forward-only traversal (the search never walks pages the reader has
//// already passed). The result list is capped at
//// `jump_search_result_limit` so a query like `"the"` on a
//// 500-page book cannot turn the modal into an unbounded list.
////
//// Matching is case-insensitive (both sides lowercased) and partial
//// (substring rather than word-boundary), matching the brief: a reader
//// hunting for a remembered phrase fragment should not have to type
//// the full word, and capitalisation at the start of a sentence is
//// noise on the search surface.
////
//// **Boundary contracts** — the entry point is total over its inputs:
////
//// * Empty / whitespace-only `query` returns `[]` without scanning
////   any page. The view treats `[]` as "show nothing" rather than
////   "no matches found", so an empty query produces an empty results
////   section rather than a misleading "no matches" message.
//// * `current_page` past the last page returns `[]` — there are no
////   forward pages to search.
////
//// The `SearchResult` type and the `jump_search_result_limit` cap
//// live here rather than in `client/state` so the data shape lives
//// alongside the algorithm that produces it. `client/state` only
//// imports the type for the `Model.jump_search_results` field — it
//// does not need the constructor or the cap constant.

import gleam/list
import gleam/string

import client/numeric.{clamp_int}
import client/pagination.{type Page}

/// Half-window for snippet extraction, in characters. The final
/// snippet is bounded at `2 * snippet_half_window` characters of
/// context plus the trimmed match itself; the actual length varies
/// because the helper snaps to whitespace boundaries to avoid cutting
/// words mid-grapheme.
const snippet_half_window: Int = 25

/// Maximum number of results returned by the Jump Ahead search. The
/// modal is a small surface — a longer list overwhelms the reader and
/// silently degrades scroll performance, so the search cuts off at a
/// fixed cap rather than rendering every hit on a long book. Twenty is
/// large enough that a typical query surfaces its useful range
/// (chapter headings, character names, recurring phrases) without
/// turning the menu into a results page.
pub const jump_search_result_limit: Int = 20

/// One hit produced by the Jump Ahead search. `page_index` is the
/// zero-based page the match lives on (always strictly greater than
/// `model.current_page` — the search is forward-only, mirroring the
/// chapter list and the page-number input). `snippet` is a ~50-
/// character window of prose around the first match on that page,
/// trimmed to whitespace boundaries and bracketed with `…` ellipses on
/// either side that has been clipped — see `snippet_around`.
pub type SearchResult {
  SearchResult(page_index: Int, snippet: String)
}

/// Forward-only search entry point. Returns at most
/// `jump_search_result_limit` results, in page-ascending order,
/// each carrying the matching page's index and a snippet of prose
/// around the first hit on that page.
///
/// Empty / whitespace-only queries collapse to `[]` so the view layer
/// can render "nothing" rather than "no matches" — a reader who has
/// not yet typed anything has no search intent to surface.
pub fn search_forward(
  pages: List(Page),
  current_page: Int,
  query: String,
) -> List(SearchResult) {
  let normalized = string.trim(query)
  case normalized {
    "" -> []
    _ -> {
      let needle = string.lowercase(normalized)
      pages
      |> list.filter(fn(page) { page.index > current_page })
      |> collect_matches(needle, [], 0)
      |> list.reverse
    }
  }
}

/// Walk forward pages and accumulate matches up to the cap. Tail-
/// recursive on the page list so a long book does not stack
/// unbounded; the cap is enforced by short-circuiting on
/// `count >= jump_search_result_limit` rather than by post-filtering,
/// so the search stops at the first 20 hits even when the book has
/// hundreds.
fn collect_matches(
  pages: List(Page),
  needle: String,
  acc_rev: List(SearchResult),
  count: Int,
) -> List(SearchResult) {
  case count >= jump_search_result_limit, pages {
    True, _ -> acc_rev
    _, [] -> acc_rev
    _, [page, ..rest] -> {
      let haystack = page_text(page)
      case find_match(haystack, needle) {
        Error(_) -> collect_matches(rest, needle, acc_rev, count)
        Ok(match_position) -> {
          let snippet = snippet_around(haystack, match_position, needle)
          let entry = SearchResult(page_index: page.index, snippet: snippet)
          collect_matches(rest, needle, [entry, ..acc_rev], count + 1)
        }
      }
    }
  }
}

/// Flatten one page into its searchable prose. Joins every word's text
/// with spaces; punctuation stays attached because the segmenter keeps
/// it that way. The result is the same string the reader sees, modulo
/// inter-word spacing (no chapter / paragraph markers — search is
/// over the words themselves).
fn page_text(page: Page) -> String {
  page.paragraphs
  |> list.flat_map(fn(page_paragraph) { page_paragraph.paragraph.sentences })
  |> list.flat_map(fn(sentence) { sentence.words })
  |> list.map(fn(word) { word.text })
  |> string.join(" ")
}

/// Locate the first case-insensitive occurrence of `needle` in
/// `haystack` and return its starting grapheme position. The lookup
/// is done by walking the lowercased haystack one grapheme at a time
/// so the returned index aligns with the original-case haystack's
/// grapheme indices — `string.slice` on the result preserves the
/// reader's view of the prose (capitalisation, accents, etc.).
fn find_match(haystack: String, needle: String) -> Result(Int, Nil) {
  let lowered = string.lowercase(haystack)
  scan_for_needle(lowered, needle, 0)
}

fn scan_for_needle(
  haystack: String,
  needle: String,
  position: Int,
) -> Result(Int, Nil) {
  case string.starts_with(haystack, needle) {
    True -> Ok(position)
    False ->
      case string.pop_grapheme(haystack) {
        Error(_) -> Error(Nil)
        Ok(#(_, rest)) -> scan_for_needle(rest, needle, position + 1)
      }
  }
}

/// Carve a ~50-character window of context around the match position
/// and bracket it with `…` ellipses on whichever side was clipped.
/// The window is snapped to whitespace boundaries on both ends so
/// the snippet never starts or ends mid-word — a reader scanning the
/// results should see whole tokens.
fn snippet_around(haystack: String, position: Int, needle: String) -> String {
  let total = string.length(haystack)
  let needle_length = string.length(needle)
  let raw_start = clamp_int(position - snippet_half_window, 0, total)
  let raw_end =
    clamp_int(position + needle_length + snippet_half_window, 0, total)
  let start = snap_left_to_boundary(haystack, raw_start)
  let end = snap_right_to_boundary(haystack, raw_end, total)
  let body = string.slice(haystack, start, end - start)
  let prefix = case start > 0 {
    True -> "…"
    False -> ""
  }
  let suffix = case end < total {
    True -> "…"
    False -> ""
  }
  prefix <> body <> suffix
}

/// Walk forward from `cursor` while the current grapheme is non-
/// whitespace. Used to push the snippet's left edge rightward off
/// any partial word it would otherwise start mid-token.
///
/// Bails out at the next whitespace grapheme or at end-of-string —
/// either way the returned index is a safe word boundary.
fn snap_left_to_boundary(haystack: String, cursor: Int) -> Int {
  case cursor <= 0 {
    True -> 0
    False ->
      case grapheme_at(haystack, cursor - 1) {
        Error(_) -> cursor
        Ok(prev) ->
          case is_whitespace(prev) {
            True -> cursor
            False -> snap_forward_to_whitespace(haystack, cursor)
          }
      }
  }
}

fn snap_forward_to_whitespace(haystack: String, cursor: Int) -> Int {
  case grapheme_at(haystack, cursor) {
    Error(_) -> cursor
    Ok(g) ->
      case is_whitespace(g) {
        True -> cursor + 1
        False -> snap_forward_to_whitespace(haystack, cursor + 1)
      }
  }
}

/// Walk backward from `cursor` while the previous grapheme is non-
/// whitespace. Mirror of `snap_left_to_boundary` — pulls the snippet's
/// right edge leftward off any partial word it would otherwise end on.
fn snap_right_to_boundary(haystack: String, cursor: Int, total: Int) -> Int {
  case cursor >= total {
    True -> total
    False ->
      case grapheme_at(haystack, cursor) {
        Error(_) -> cursor
        Ok(next) ->
          case is_whitespace(next) {
            True -> cursor
            False -> snap_backward_to_whitespace(haystack, cursor)
          }
      }
  }
}

fn snap_backward_to_whitespace(haystack: String, cursor: Int) -> Int {
  case cursor <= 0 {
    True -> 0
    False ->
      case grapheme_at(haystack, cursor - 1) {
        Error(_) -> cursor
        Ok(g) ->
          case is_whitespace(g) {
            True -> cursor - 1
            False -> snap_backward_to_whitespace(haystack, cursor - 1)
          }
      }
  }
}

fn grapheme_at(haystack: String, index: Int) -> Result(String, Nil) {
  case string.slice(haystack, index, 1) {
    "" -> Error(Nil)
    g -> Ok(g)
  }
}

fn is_whitespace(grapheme: String) -> Bool {
  grapheme == " " || grapheme == "\t" || grapheme == "\n" || grapheme == "\r"
}
