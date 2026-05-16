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

import gleam/float
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
import client/view/overlay_helpers.{stop_click_propagation}
import shared/stats.{type LibraryStats, type SessionSpeed}

/// SVG namespace for the sparkline tile. Pulled out so the `namespaced`
/// calls below don't repeat the literal at every nesting level — a
/// typo in the namespace silently turns the SVG elements into unknown
/// HTML tags and the polyline never renders.
const svg_namespace: String = "http://www.w3.org/2000/svg"

/// Width of the rendered sparkline in viewBox units. Matches the CSS
/// surface (`200px`) so the rendered line tracks the box without an
/// additional scale transform.
const sparkline_width: Float = 200.0

/// Height of the rendered sparkline in viewBox units. Mirrors the
/// 40px CSS surface; tall enough to read a trend, short enough to
/// sit alongside the other stat tiles without dominating the layout.
const sparkline_height: Float = 40.0

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
    view_speed_trend_tile(model.speed_trend),
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

/// Render the sparkline tile that sits below the four stat tiles. Each
/// `SessionSpeed` sample contributes one vertex to the polyline; the
/// vertices are scaled into a 200×40 viewBox between the dataset's min
/// and max WPM. An empty trend collapses to a placeholder line so the
/// surface always carries the tile chrome regardless of whether the
/// reader has any sessions yet.
///
/// The on-model order is reverse-chronological (most-recent first,
/// matching the SQL `ORDER BY started_at DESC`); reverse it here so
/// the rendered line reads left-to-right in chronological order.
///
/// Exposed so the per-book stats overlay rendered from the reader
/// can reuse the same sparkline chrome — the speed trend is a
/// library-wide signal (most-recent N sessions across every book),
/// so the same data set is meaningful in both surfaces.
pub fn view_speed_trend_tile(samples: List(SessionSpeed)) -> Element(Msg) {
  case samples {
    [] -> view_speed_trend_empty()
    _ -> {
      let chronological = list.reverse(samples)
      let wpm_values = list.map(chronological, fn(s) { s.wpm })
      let average = average_wpm(wpm_values)
      html.div([attribute.class("stats-speed-trend")], [
        html.div([attribute.class("stats-speed-trend-header")], [
          html.div([attribute.class("stats-speed-trend-label")], [
            html.text("Recent reading speed"),
          ]),
          html.div([attribute.class("stats-speed-trend-average")], [
            html.text(int.to_string(average) <> " wpm avg"),
          ]),
        ]),
        view_speed_trend_svg(wpm_values),
      ])
    }
  }
}

/// Empty-state shim for the sparkline tile. Renders the chrome label
/// alongside a muted "no sessions yet" placeholder so the overlay does
/// not collapse around the absence of data — keeps the tile height
/// stable on first open versus subsequent opens.
fn view_speed_trend_empty() -> Element(Msg) {
  html.div([attribute.class("stats-speed-trend")], [
    html.div([attribute.class("stats-speed-trend-header")], [
      html.div([attribute.class("stats-speed-trend-label")], [
        html.text("Recent reading speed"),
      ]),
    ]),
    html.div([attribute.class("stats-speed-trend-empty")], [
      html.text("No sessions recorded yet."),
    ]),
  ])
}

/// Render the polyline plus a semi-transparent fill underneath it. The
/// SVG uses a fixed viewBox so the rendered output scales with whatever
/// CSS width / height the surrounding tile applies — the helper here
/// works in viewBox units throughout.
///
/// Y-axis scaling: each WPM value maps into `[0, sparkline_height]`
/// against the dataset's min/max. A flat trend (all values equal)
/// would otherwise divide by zero in `scale_y`, so the helper offsets
/// the line to the vertical centre in that case.
fn view_speed_trend_svg(wpm_values: List(Int)) -> Element(Msg) {
  let count = list.length(wpm_values)
  let max_wpm = list.fold(wpm_values, 0, fn(acc, v) { int.max(acc, v) })
  let min_wpm = case wpm_values {
    [] -> 0
    [first, ..rest] -> list.fold(rest, first, fn(acc, v) { int.min(acc, v) })
  }
  let points = build_points(wpm_values, count, min_wpm, max_wpm)
  let points_attr = format_points(points)
  let fill_attr = format_fill_points(points)
  element.namespaced(
    svg_namespace,
    "svg",
    [
      attribute.class("stats-speed-trend-svg"),
      attribute.attribute(
        "viewBox",
        "0 0 "
          <> float.to_string(sparkline_width)
          <> " "
          <> float.to_string(sparkline_height),
      ),
      attribute.attribute("role", "img"),
      attribute.aria_label("Reading speed trend"),
    ],
    [
      element.namespaced(
        svg_namespace,
        "polygon",
        [
          attribute.class("stats-speed-trend-fill"),
          attribute.attribute("points", fill_attr),
        ],
        [],
      ),
      element.namespaced(
        svg_namespace,
        "polyline",
        [
          attribute.class("stats-speed-trend-line"),
          attribute.attribute("points", points_attr),
        ],
        [],
      ),
    ],
  )
}

/// Average WPM across the trend, rounded to the nearest integer. Used
/// for the "N wpm avg" badge alongside the sparkline. Returns zero for
/// an empty list — the caller short-circuits on the empty case
/// already, so the zero branch is unreachable in production but the
/// helper handles it cleanly so unit tests can exercise the predicate
/// directly.
pub fn average_wpm(wpm_values: List(Int)) -> Int {
  case wpm_values {
    [] -> 0
    _ -> {
      let sum = list.fold(wpm_values, 0, fn(acc, v) { acc + v })
      sum / list.length(wpm_values)
    }
  }
}

/// Project each WPM sample onto an `(x, y)` viewBox coordinate pair.
/// Y maps so the smallest WPM lands at the bottom of the box and the
/// largest at the top (SVG y grows downward, so `top - scaled` is the
/// canonical "flip" against the bottom-anchored axis). A degenerate
/// single-sample / flat-trend dataset centres horizontally so the
/// single point or flat line reads as a neutral baseline rather than
/// pinning to either edge.
fn build_points(
  wpm_values: List(Int),
  count: Int,
  min_wpm: Int,
  max_wpm: Int,
) -> List(#(Float, Float)) {
  let denominator = case count {
    n if n <= 1 -> 1
    n -> n - 1
  }
  list.index_map(wpm_values, fn(value, index) {
    let x = case count {
      1 -> sparkline_width /. 2.0
      _ -> int.to_float(index) *. sparkline_width /. int.to_float(denominator)
    }
    let y = scale_y(value, min_wpm, max_wpm)
    #(x, y)
  })
}

/// Map a WPM value into the SVG y-axis. The 4-unit inset top and
/// bottom keeps the polyline from hugging the viewBox edge so the
/// line never visually escapes the tile boundary on a stroke wider
/// than one pixel.
fn scale_y(value: Int, min_wpm: Int, max_wpm: Int) -> Float {
  let inset = 4.0
  let usable = sparkline_height -. 2.0 *. inset
  case max_wpm - min_wpm {
    0 -> sparkline_height /. 2.0
    span -> {
      let fraction = int.to_float(value - min_wpm) /. int.to_float(span)
      sparkline_height -. inset -. fraction *. usable
    }
  }
}

/// Format a list of `(x, y)` pairs as an SVG `points` attribute. Each
/// pair becomes `"x,y"`; the pairs are joined with spaces, matching
/// the canonical SVG `points` syntax used by `<polyline>` and
/// `<polygon>`.
fn format_points(points: List(#(Float, Float))) -> String {
  points
  |> list.map(fn(p) {
    let #(x, y) = p
    float.to_string(x) <> "," <> float.to_string(y)
  })
  |> string.join(" ")
}

/// Format the polygon outline that fills the area below the polyline.
/// Anchors the path to the bottom-left and bottom-right corners of the
/// viewBox so the fill always closes against the baseline regardless
/// of where the polyline starts and ends vertically.
fn format_fill_points(points: List(#(Float, Float))) -> String {
  case points {
    [] -> ""
    _ -> {
      let first_x = case points {
        [#(x, _), ..] -> x
        [] -> 0.0
      }
      let last_x = case list.last(points) {
        Ok(#(x, _)) -> x
        Error(_) -> sparkline_width
      }
      let bottom = float.to_string(sparkline_height)
      let anchor_left = float.to_string(first_x) <> "," <> bottom
      let anchor_right = float.to_string(last_x) <> "," <> bottom
      anchor_left <> " " <> format_points(points) <> " " <> anchor_right
    }
  }
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
