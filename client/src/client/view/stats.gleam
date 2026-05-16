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
//// time, books completed, and the current streak in calendar days —
//// plus the speed-trend sparkline. Values come from
//// `model.library_stats`; a `None` value renders a dash so the
//// overlay never paints a stale snapshot. The formatting helpers and
//// the sparkline tile live in `client/view/stats_helpers` so the
//// per-book stats overlay (`view/reader/book_stats.gleam`) can render
//// the same chrome without a cross-sibling import.

import gleam/int
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{type Msg, ToggleStatsView}
import client/state.{type Model}
import client/view/overlay_helpers.{stop_click_propagation}
import client/view/stats_helpers
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
    stats_helpers.view_speed_trend_tile(model.speed_trend),
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
        view_stat_tile(
          "Total words read",
          stats_helpers.format_words(s.total_words_read),
        ),
        view_stat_tile(
          "Total reading time",
          stats_helpers.format_duration(s.total_duration_seconds),
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
