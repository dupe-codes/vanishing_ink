//// Jump Ahead overlay. Scrim + bottom-sheet wrapping three sections:
////
//// * **Chapters** — `model.chapter_entries`, rendered as tappable
////   rows. Only forward chapters are stored on the cache, so the
////   list never shows the reader a chapter they have already passed.
//// * **Page** — numeric input + Go button so the reader can jump to
////   an arbitrary forward page without going through the chapter
////   list. The input is `min=current_page+2` (1-based) so the
////   smallest valid target is the next page. The button is the
////   primary affordance on mobile, where soft numeric keyboards do
////   not always surface a return / go key; pressing Enter inside
////   the field also dispatches the same Msg path.
//// * **Search** — free-text input that surfaces matching pages
////   strictly ahead of the current one. Results show the page number
////   and a ~50-character snippet of prose around the first match on
////   that page; tapping a result feeds into the same preview / lock-
////   in / undo flow as the other two affordances. An empty query
////   shows nothing; a non-empty query with no matches shows a muted
////   "No matches found" line so the reader knows the search ran.
////
//// The scrim closes the menu on outside-tap (mirroring the settings
//// panel); the inner sheet swallows clicks via `stop_click_propagation`
//// so taps on a chapter row, the Go button, or a search result never
//// bubble up to the scrim's close handler.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{
  type Msg, JumpToChapter, NoOp, SelectSearchResult, SetJumpPageInput,
  SetJumpSearchQuery, SubmitJumpPage, ToggleJumpMenu,
}
import client/state.{type ChapterEntry, type Model, type SearchResult}

/// Render the Jump Ahead overlay when `model.jump_menu_open` is true.
/// Returns `element.none()` otherwise — the markup is entirely absent
/// from the DOM rather than display-hidden so the closed-state tests
/// can pin "no scrim, no panel" without crawling CSS state.
pub fn view(model: Model) -> Element(Msg) {
  case model.jump_menu_open {
    False -> element.none()
    True ->
      html.div(
        [
          attribute.class("jump-overlay"),
          attribute.role("dialog"),
          attribute.aria_modal(True),
          attribute.aria_label("Jump ahead"),
          event.on_click(ToggleJumpMenu),
        ],
        [view_sheet(model)],
      )
  }
}

/// Inner sheet. Swallows click events so taps inside the panel don't
/// bubble up to the scrim's close handler. Renders the header, the
/// chapter list (when there are forward chapters), the page input
/// row, and the text-search section.
fn view_sheet(model: Model) -> Element(Msg) {
  html.div([attribute.class("jump-menu"), stop_click_propagation()], [
    html.div(
      [attribute.class("settings-sheet-handle"), attribute.aria_hidden(True)],
      [],
    ),
    view_header(),
    view_chapter_section(model),
    view_page_section(model),
    view_search_section(model),
  ])
}

fn view_header() -> Element(Msg) {
  html.div([attribute.class("settings-panel-header")], [
    html.h2([attribute.class("settings-panel-title")], [
      html.text("Jump ahead"),
    ]),
    html.button(
      [
        attribute.class("settings-panel-close"),
        attribute.aria_label("Close jump menu"),
        attribute.type_("button"),
        event.on_click(ToggleJumpMenu),
      ],
      [html.text("✕")],
    ),
  ])
}

/// Chapter list section. Renders nothing when the cache is empty —
/// every chapter is behind the reader, or the book has no titled
/// chapters at all. The page input below still works in that case so
/// the reader can jump by raw page number.
fn view_chapter_section(model: Model) -> Element(Msg) {
  case model.chapter_entries {
    [] -> element.none()
    entries ->
      html.div([attribute.class("jump-section")], [
        html.div([attribute.class("jump-section-label")], [
          html.text("Chapters"),
        ]),
        html.div(
          [attribute.class("jump-chapter-list")],
          list.map(entries, view_chapter_row),
        ),
      ])
  }
}

/// Render one chapter row. Dispatches `JumpToChapter(chapter_index)`
/// using the segmenter-stable chapter index — not the row's position
/// in `chapter_entries` — so a tap on what the reader saw as
/// "Chapter Two" still resolves to chapter 2 even if pagination or
/// the engine reshuffled the cache between paint and tap.
fn view_chapter_row(entry: ChapterEntry) -> Element(Msg) {
  html.button(
    [
      attribute.class("jump-chapter-item"),
      attribute.type_("button"),
      attribute.aria_label("Jump to " <> entry.title),
      event.on_click(JumpToChapter(entry.chapter_index)),
    ],
    [
      html.span([attribute.class("jump-chapter-title")], [
        html.text(entry.title),
      ]),
      html.span([attribute.class("jump-chapter-page")], [
        html.text("p. " <> int.to_string(entry.page_index + 1)),
      ]),
    ],
  )
}

/// Page-number input row. The min/max attributes are 1-based to match
/// the reader's visible page label; the reducer reads 0-based indices
/// so the dispatch subtracts one before dispatching `JumpToPage`.
///
/// Renders no input row when there are zero or one pages — there is
/// no valid forward target to type in.
fn view_page_section(model: Model) -> Element(Msg) {
  let next_page_one_based = model.current_page + 2
  case model.total_pages < next_page_one_based {
    True -> element.none()
    False -> {
      let max_value = int.to_string(model.total_pages)
      let min_value = int.to_string(next_page_one_based)
      html.div([attribute.class("jump-section")], [
        html.div([attribute.class("jump-section-label")], [
          html.text("Page"),
        ]),
        html.div([attribute.class("jump-page-row")], [
          html.input([
            attribute.class("jump-page-input"),
            attribute.type_("number"),
            attribute.attribute("min", min_value),
            attribute.attribute("max", max_value),
            attribute.attribute("inputmode", "numeric"),
            attribute.attribute(
              "placeholder",
              "Page " <> min_value <> "-" <> max_value,
            ),
            attribute.aria_label("Page number"),
            attribute.value(model.jump_page_input),
            event.on_input(SetJumpPageInput),
            on_enter_submit(),
          ]),
          html.button(
            [
              attribute.class("jump-page-go"),
              attribute.type_("button"),
              attribute.aria_label("Go to typed page"),
              event.on_click(SubmitJumpPage),
            ],
            [html.text("Go")],
          ),
        ]),
      ])
    }
  }
}

/// Search section. Renders the controlled input unconditionally
/// (so a reader who has not yet typed still sees the affordance) and
/// the results region underneath. The results region is one of three
/// shapes:
///
/// * Empty query — nothing rendered, so the panel does not jump in
///   height the moment focus lands on the input.
/// * Non-empty query, no matches — a muted "No matches found" line so
///   the reader knows the search executed.
/// * Non-empty query, matches — a vertical list of result rows, each
///   carrying the page number and a snippet of prose around the first
///   match on that page.
fn view_search_section(model: Model) -> Element(Msg) {
  html.div([attribute.class("jump-section")], [
    html.div([attribute.class("jump-section-label")], [html.text("Search")]),
    html.input([
      attribute.class("jump-search-input"),
      attribute.type_("search"),
      attribute.attribute("inputmode", "search"),
      attribute.attribute("placeholder", "Search ahead..."),
      attribute.attribute("autocomplete", "off"),
      attribute.attribute("spellcheck", "false"),
      attribute.aria_label("Search ahead"),
      attribute.value(model.jump_search_query),
      event.on_input(SetJumpSearchQuery),
    ]),
    view_search_results(model),
  ])
}

/// Render the search-results region. An empty trimmed query returns
/// `element.none()`; a non-empty query with no matches renders the
/// muted empty-state line; matches render as a list of tappable rows.
fn view_search_results(model: Model) -> Element(Msg) {
  case string.trim(model.jump_search_query), model.jump_search_results {
    "", _ -> element.none()
    _, [] ->
      html.div([attribute.class("jump-search-empty")], [
        html.text("No matches found"),
      ])
    _, results ->
      html.div(
        [attribute.class("jump-search-results")],
        list.map(results, view_search_result_row),
      )
  }
}

/// Render one search result. Dispatches `SelectSearchResult(page_index)`
/// — the same code path the page-number input feeds into via
/// `SubmitJumpPage`, just routed through a different controller. The
/// 1-based page label is shown to the reader (matching the bottom-bar
/// page indicator's convention); the dispatch payload remains the
/// 0-based reducer index.
fn view_search_result_row(result: SearchResult) -> Element(Msg) {
  html.button(
    [
      attribute.class("jump-search-result-item"),
      attribute.type_("button"),
      attribute.aria_label(
        "Jump to page " <> int.to_string(result.page_index + 1),
      ),
      event.on_click(SelectSearchResult(result.page_index)),
    ],
    [
      html.span([attribute.class("jump-search-result-page")], [
        html.text("p. " <> int.to_string(result.page_index + 1)),
      ]),
      html.span([attribute.class("jump-search-snippet")], [
        html.text(result.snippet),
      ]),
    ],
  )
}

/// `Enter`-key handler on the numeric input. Dispatches the same
/// `SubmitJumpPage` Msg the Go button does — the reducer reads
/// `model.jump_page_input` (kept in sync through `SetJumpPageInput`)
/// and runs the parse + dispatch path. Non-Enter keys collapse to
/// `NoOp` via `decode.failure` so the event never reaches the
/// reducer.
fn on_enter_submit() -> attribute.Attribute(Msg) {
  event.on("keydown", enter_key_decoder())
}

fn enter_key_decoder() -> decode.Decoder(Msg) {
  use key <- decode.field("key", decode.string)
  case key {
    "Enter" -> decode.success(SubmitJumpPage)
    _ -> decode.failure(NoOp, "non-enter-key")
  }
}

/// Attach a click listener that stops propagation but never dispatches
/// a message. Mirrors the helpers in `settings.gleam` and
/// `library/add_book.gleam` — duplicated locally rather than imported
/// so the view-layer dependency graph stays a fan-in pattern (each
/// view module is a leaf under `client/view.gleam`).
fn stop_click_propagation() -> attribute.Attribute(Msg) {
  event.on("click", decode.failure(NoOp, "stop-propagation"))
  |> event.stop_propagation
}
