//// Per-book stats overlay rendered above the reader. Mirrors the
//// scrim + sheet pattern the library stats overlay uses (see
//// `client/view/stats.gleam` for the canonical reference):
////
////   * Fixed-position scrim wraps a bottom-sheet panel.
////   * Scrim tap closes the overlay.
////   * Panel swallows clicks via `stop_click_propagation` so taps
////     inside the panel never reach the scrim's close handler.
////
//// The overlay shows three per-book tiles — total words read, total
//// reading time, and session count — plus the library-wide speed
//// trend sparkline (reused from `client/view/stats_helpers`). Values
//// come from `model.book_stats`; a `None` value renders a "no stats"
//// empty state so the overlay never paints stale tiles. The speed
//// trend reuses the library-wide samples on `model.speed_trend`
//// because the trend is a cross-book signal — the SQL feed is
//// `ORDER BY started_at DESC LIMIT N` over every session, not
//// filtered by book — and the reader's recent-pace context is
//// meaningful regardless of which specific book is open.

import gleam/int
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{type Msg, ToggleReaderStats}
import client/state.{type Model}
import client/view/overlay_helpers.{stop_click_propagation}
import client/view/stats_helpers
import shared/stats.{type BookStats}

/// Render the per-book stats overlay (scrim + sheet). Renders nothing
/// when `model.reader_stats_open` is `False` — the caller in
/// `client/view.gleam` already gates on the flag, but the helper stays
/// total so a direct call site cannot paint without checking.
pub fn view(model: Model) -> Element(Msg) {
  case model.reader_stats_open {
    False -> element.none()
    True ->
      html.div(
        [
          attribute.class("stats-overlay reader-book-stats-overlay"),
          attribute.role("dialog"),
          attribute.aria_modal(True),
          attribute.aria_label("Book stats"),
          event.on_click(ToggleReaderStats),
        ],
        [view_stats_sheet(model)],
      )
  }
}

fn view_stats_sheet(model: Model) -> Element(Msg) {
  html.div([attribute.class("stats-panel"), stop_click_propagation()], [
    html.div(
      [attribute.class("settings-sheet-handle"), attribute.aria_hidden(True)],
      [],
    ),
    view_stats_header(),
    view_stats_body(model.book_stats),
    stats_helpers.view_speed_trend_tile(model.speed_trend),
  ])
}

fn view_stats_header() -> Element(Msg) {
  html.div([attribute.class("stats-panel-header")], [
    html.h2([attribute.class("stats-panel-title")], [
      html.text("Book stats"),
    ]),
    html.button(
      [
        attribute.class("stats-panel-close"),
        attribute.aria_label("Close book stats"),
        attribute.type_("button"),
        event.on_click(ToggleReaderStats),
      ],
      [html.text("✕")],
    ),
  ])
}

/// Render the three per-book tiles. `None` and `Some(s)` with
/// `s.session_count == 0` both collapse to the same empty-state
/// surface — without any session for the active book, every tile
/// would be `0`/`0s`, which reads as a degenerate snapshot instead
/// of an honest "no data yet" surface.
fn view_stats_body(stats: Option(BookStats)) -> Element(Msg) {
  case stats {
    None -> view_empty_state()
    Some(s) ->
      case s.session_count {
        0 -> view_empty_state()
        _ ->
          html.div([attribute.class("stats-grid")], [
            view_stat_tile(
              "Words read",
              stats_helpers.format_words(s.total_words_read),
            ),
            view_stat_tile(
              "Reading time",
              stats_helpers.format_duration(s.total_duration_seconds),
            ),
            view_stat_tile("Sessions", int.to_string(s.session_count)),
          ])
      }
  }
}

/// The "no data yet" surface for the per-book overlay. Pulled out so
/// the two no-stats branches (`None` and `Some(s) with session_count ==
/// 0`) carry the exact same copy — a future revision touching the
/// string only has to change it once, and the two paths cannot
/// diverge silently on a typo.
fn view_empty_state() -> Element(Msg) {
  html.div([attribute.class("stats-empty")], [
    html.text("No reading stats recorded for this book yet."),
  ])
}

fn view_stat_tile(label: String, value: String) -> Element(Msg) {
  html.div([attribute.class("stats-tile")], [
    html.div([attribute.class("stats-tile-value")], [html.text(value)]),
    html.div([attribute.class("stats-tile-label")], [html.text(label)]),
  ])
}
