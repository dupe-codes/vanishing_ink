//// Jump Ahead overlay. Scrim + bottom-sheet wrapping two sections:
////
//// * **Chapters** — `model.chapter_entries`, rendered as tappable
////   rows. Only forward chapters are stored on the cache, so the
////   list never shows the reader a chapter they have already passed.
//// * **Page** — numeric input + Go button so the reader can jump to
////   an arbitrary forward page without going through the chapter
////   list. The input is `min=current_page+2` (1-based) so the
////   smallest valid target is the next page.
////
//// The scrim closes the menu on outside-tap (mirroring the settings
//// panel); the inner sheet swallows clicks via `stop_click_propagation`
//// so taps on a chapter row or the Go button never bubble up to the
//// scrim's close handler.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{type Msg, JumpToChapter, JumpToPage, ToggleJumpMenu}
import client/state.{type ChapterEntry, type Model}

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
/// bubble up to the scrim's close handler. Renders the header,
/// chapter list (when there are forward chapters), and the page
/// input row.
fn view_sheet(model: Model) -> Element(Msg) {
  html.div([attribute.class("jump-menu"), stop_click_propagation()], [
    html.div(
      [attribute.class("settings-sheet-handle"), attribute.aria_hidden(True)],
      [],
    ),
    view_header(),
    view_chapter_section(model),
    view_page_section(model),
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
          list.index_map(entries, view_chapter_row),
        ),
      ])
  }
}

fn view_chapter_row(entry: ChapterEntry, index: Int) -> Element(Msg) {
  html.button(
    [
      attribute.class("jump-chapter-item"),
      attribute.type_("button"),
      attribute.aria_label("Jump to " <> entry.title),
      event.on_click(JumpToChapter(index)),
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
            on_page_input(model),
          ]),
        ]),
      ])
    }
  }
}

/// `Enter`-key handler on the numeric input. Reads the typed value,
/// converts to a 0-based page index, and dispatches `JumpToPage`. The
/// reducer-side guard rejects anything `<= current_page` or
/// `>= total_pages`, so we don't need to validate on the way in
/// beyond parsing.
///
/// Decode failure (empty / non-numeric input, or below the min) maps
/// to `ToggleJumpMenu` as a placeholder Msg that Lustre never
/// dispatches — `decode.failure` always fails, so the event collapses
/// rather than firing a phantom toggle.
fn on_page_input(model: Model) -> attribute.Attribute(Msg) {
  event.on("keydown", page_input_decoder(model))
}

fn page_input_decoder(model: Model) -> decode.Decoder(Msg) {
  use key <- decode.field("key", decode.string)
  case key {
    "Enter" -> {
      use value <- decode.subfield(["target", "value"], decode.string)
      case int.parse(value) {
        Ok(one_based) -> {
          let zero_based = one_based - 1
          case zero_based > model.current_page {
            True -> decode.success(JumpToPage(zero_based))
            False -> decode.failure(ToggleJumpMenu, "page-out-of-range")
          }
        }
        Error(_) -> decode.failure(ToggleJumpMenu, "page-not-numeric")
      }
    }
    _ -> decode.failure(ToggleJumpMenu, "non-enter-key")
  }
}

/// Attach a click listener that stops propagation but never dispatches
/// a message. Mirrors the helpers in `settings.gleam` and
/// `library/add_book.gleam` — duplicated locally rather than imported
/// so the view-layer dependency graph stays a fan-in pattern (each
/// view module is a leaf under `client/view.gleam`).
fn stop_click_propagation() -> attribute.Attribute(Msg) {
  event.on("click", decode.failure(ToggleJumpMenu, "stop-propagation"))
  |> event.stop_propagation
}
