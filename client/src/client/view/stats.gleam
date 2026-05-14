//// Library-wide stats overlay. Mirrors the scrim + sheet pattern
//// the settings overlay uses (see `client/view/settings.gleam` for the
//// canonical reference):
////
////   * Fixed-position scrim wraps a bottom-sheet panel.
////   * Scrim tap closes the overlay.
////   * Panel swallows clicks via `stop_click_propagation` so taps
////     inside the panel never reach the scrim's close handler.
////
//// The overlay shows four tiles — total words read, total reading
//// time, books completed, and the current streak in calendar days.
//// Values come from `model.library_stats`; a `None` value renders a
//// dash so the overlay never paints a stale snapshot.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{type Msg, ToggleStatsView}
import client/state.{type Model}
import shared/stats.{type LibraryStats}

/// Render the library stats overlay (scrim + sheet).
pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class("stats-overlay"),
      attribute.role("dialog"),
      attribute.aria_modal(True),
      attribute.aria_label("Reading stats"),
      event.on_click(ToggleStatsView),
    ],
    [view_stats_sheet(model)],
  )
}

fn view_stats_sheet(model: Model) -> Element(Msg) {
  html.div([attribute.class("stats-panel"), stop_click_propagation()], [
    html.div(
      [attribute.class("settings-sheet-handle"), attribute.aria_hidden(True)],
      [],
    ),
    view_stats_header(),
    view_stats_body(model.library_stats),
  ])
}

fn view_stats_header() -> Element(Msg) {
  html.div([attribute.class("stats-panel-header")], [
    html.h2([attribute.class("stats-panel-title")], [
      html.text("Reading stats"),
    ]),
    html.button(
      [
        attribute.class("stats-panel-close"),
        attribute.aria_label("Close stats"),
        attribute.type_("button"),
        event.on_click(ToggleStatsView),
      ],
      [html.text("✕")],
    ),
  ])
}

fn view_stats_body(stats: Option(LibraryStats)) -> Element(Msg) {
  case stats {
    None ->
      html.div([attribute.class("stats-empty")], [
        html.text("No reading stats recorded yet."),
      ])
    Some(s) ->
      html.div([attribute.class("stats-grid")], [
        view_stat_tile("Total words read", format_words(s.total_words_read)),
        view_stat_tile(
          "Total reading time",
          format_duration(s.total_duration_seconds),
        ),
        view_stat_tile("Books completed", int.to_string(s.books_completed)),
        view_stat_tile("Current streak", format_streak(s.current_streak_days)),
      ])
  }
}

fn view_stat_tile(label: String, value: String) -> Element(Msg) {
  html.div([attribute.class("stats-tile")], [
    html.div([attribute.class("stats-tile-value")], [html.text(value)]),
    html.div([attribute.class("stats-tile-label")], [html.text(label)]),
  ])
}

/// Format an integer word count with thousands separators. Mirrors the
/// pattern used in `view/library.gleam` so cards and the stats overlay
/// emit the same wire shape.
pub fn format_words(count: Int) -> String {
  insert_thousands_separators(int.to_string(count))
}

/// Format a whole-second duration as `Xh Ym`, `Ym`, or `Xs` — whichever
/// is the most compact representation that still reads as time. The
/// stats surface deliberately rounds to whole minutes past 60 seconds
/// because the underlying counter is wall-clock and a sub-minute
/// resolution carries more noise than signal.
pub fn format_duration(total_seconds: Int) -> String {
  case total_seconds < 60 {
    True -> int.to_string(total_seconds) <> "s"
    False -> {
      let minutes = total_seconds / 60
      case minutes < 60 {
        True -> int.to_string(minutes) <> "m"
        False -> {
          let hours = minutes / 60
          let remainder_minutes = minutes - hours * 60
          case remainder_minutes {
            0 -> int.to_string(hours) <> "h"
            _ ->
              int.to_string(hours)
              <> "h "
              <> int.to_string(remainder_minutes)
              <> "m"
          }
        }
      }
    }
  }
}

/// Render the streak as `"N days"` (or `"1 day"` for one). A streak of
/// zero collapses to `"None"` so the tile reads as honest rather than
/// as a misleading "0 days".
pub fn format_streak(days: Int) -> String {
  case days {
    0 -> "None"
    1 -> "1 day"
    _ -> int.to_string(days) <> " days"
  }
}

fn insert_thousands_separators(digits: String) -> String {
  // Walk the digit string from the right in groups of three. Mirrors
  // the algorithm in `client/view/library.gleam` — kept local rather
  // than imported across sibling view modules so the view-layer
  // dependency graph stays a fan-in pattern (each view module is a
  // leaf under `client/view.gleam`).
  digits
  |> string.to_graphemes
  |> list.reverse
  |> chunk_every_three([])
  |> list.map(fn(chunk) {
    chunk
    |> list.reverse
    |> string.concat
  })
  |> list.reverse
  |> string.join(",")
}

fn chunk_every_three(
  digits: List(String),
  acc: List(List(String)),
) -> List(List(String)) {
  case digits {
    [] -> list.reverse(acc)
    _ -> {
      let #(chunk, rest) = take_split(digits, 3, [])
      chunk_every_three(rest, [chunk, ..acc])
    }
  }
}

fn take_split(
  source: List(String),
  remaining: Int,
  acc: List(String),
) -> #(List(String), List(String)) {
  case remaining, source {
    0, _ -> #(list.reverse(acc), source)
    _, [] -> #(list.reverse(acc), [])
    _, [head, ..tail] -> take_split(tail, remaining - 1, [head, ..acc])
  }
}

/// Attach a click listener that stops propagation but never dispatches
/// a message. Pulled inline here so the stats overlay's panel can
/// swallow taps without bubbling up to the scrim's close handler —
/// mirrors the same helper in `client/view/settings.gleam` and
/// `client/view/library.gleam`.
fn stop_click_propagation() -> attribute.Attribute(Msg) {
  event.on("click", decode.failure(ToggleStatsView, "stop-propagation"))
  |> event.stop_propagation
}
