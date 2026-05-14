//// Reader bottom bar — mode-aware. Extracted from
//// `client/view/reader.gleam` so that file stays under the 800-line
//// hard budget while the Jump Ahead modal and preview banner can
//// land their own markup against this same outer frame.
////
//// The outer `.reader-bottom-bar` carries the safe-area-bottom
//// padding and the warm chrome background. The inner row swaps
//// shape with `model.mode`:
////
//// * Manual — `[↩ Undo]   Page N of M   [Turn Page →]`
//// * RealTime — `WPM readout   [▶ / ⏸]   (spacer)`

import gleam/int
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{type Msg, NextPage, PauseFade, ResumeFade, StartFade, Undo}
import client/state.{type Model, Manual, Paused, RealTime, Running, Stopped}

/// Render the outer bottom bar. The reducer never lands the reader
/// view without a `model.mode` value, so the case is exhaustive on
/// the two real variants.
pub fn view(model: Model, total: Int) -> Element(Msg) {
  let inner = case model.mode {
    Manual -> view_bottom_manual(model, total)
    RealTime -> view_bottom_realtime(model)
  }
  html.div([attribute.class("reader-bottom-bar")], [inner])
}

/// Manual-mode bottom bar inner row.
///
/// Layout: `[↩ Undo]   Page N of M   [Turn Page →]`.
///
/// * Undo button — disabled when the undo stack is empty. Dispatches
///   `Undo`.
/// * Page label — `Page N of M` text; renders an empty string when no
///   pages are available yet, so the bar's frame stays the same height
///   before pagination has produced its first result.
/// * Turn-page button — primary (inverted) styling so the eye is
///   drawn to it. Reads "✓ Finished" on the last page and is disabled
///   there. Dispatches `NextPage`.
fn view_bottom_manual(model: Model, total: Int) -> Element(Msg) {
  let on_last_page = total > 0 && model.current_page >= total - 1
  let next_label = case on_last_page {
    True -> "✓ Finished"
    False -> "Turn Page →"
  }
  let next_disabled = total == 0 || on_last_page
  let page_text = case total {
    0 -> ""
    _ ->
      "Page "
      <> int.to_string(model.current_page + 1)
      <> " of "
      <> int.to_string(total)
  }
  let undo_disabled = list.is_empty(model.undo_stack)

  html.div([attribute.class("reader-bottom-manual")], [
    html.button(
      [
        attribute.class("btn-bar"),
        attribute.type_("button"),
        attribute.disabled(undo_disabled),
        attribute.aria_label("Undo last erase"),
        event.on_click(Undo),
      ],
      [html.text("↩ Undo")],
    ),
    html.div([attribute.class("reader-page-label")], [html.text(page_text)]),
    html.button(
      [
        attribute.class("btn-bar primary"),
        attribute.type_("button"),
        attribute.disabled(next_disabled),
        attribute.aria_label("Turn page"),
        event.on_click(NextPage),
      ],
      [html.text(next_label)],
    ),
  ])
}

/// Real-time mode bottom bar inner row.
///
/// Layout: `WPM readout   [▶ / ⏸]   (spacer)`.
///
/// The play button cycles through the engine's three states:
///
/// * `Stopped` — render `▶` with the `.ready` accent background;
///   click dispatches `StartFade`.
/// * `Paused`  — render `▶` with the `.ready` accent background;
///   click dispatches `ResumeFade`.
/// * `Running` — render `⏸` with the default inverted background;
///   click dispatches `PauseFade`.
///
/// `Stopped` and `Paused` share the `.ready` modifier (rather than a
/// `.paused` class that mislabels the Stopped case as "paused")
/// because both states paint the same "press me to resume / start"
/// affordance.
///
/// No `event.stop_propagation` is required: the page-level touch
/// handlers (`gestures.on_touch_*`) sit on `#vi-reading-area` /
/// `.reader-page`, while this button lives inside
/// `.reader-bottom-bar`. The two are *siblings* under
/// `.reader-text`, not ancestor and descendant — DOM events bubble
/// up through ancestors only, so a tap on the play button never
/// reaches the reading-area touch handler.
fn view_bottom_realtime(model: Model) -> Element(Msg) {
  let #(button_label, button_class, play_msg, aria_label) = case
    model.engine_state
  {
    Running -> #("⏸", "btn-play", PauseFade, "Pause reading")
    Paused -> #("▶", "btn-play ready", ResumeFade, "Resume reading")
    Stopped -> #("▶", "btn-play ready", StartFade, "Start reading")
  }

  html.div([attribute.class("reader-bottom-realtime")], [
    html.div(
      [
        attribute.class("wpm-readout"),
        // `role="text"` collapses the element into a single text node
        // in the accessibility tree and exposes the aria-label as the
        // accessible name. Without a role, a roleless `<div>` is a
        // generic that JAWS and VoiceOver may skip in announcement
        // passes — dropping the verbose phrase silently. `role="status"`
        // would announce on every slider tick during a drag; we want
        // a static label, not a live region.
        attribute.role("text"),
        attribute.aria_label(
          "Reading speed: " <> int.to_string(model.wpm) <> " words per minute",
        ),
      ],
      [html.text(int.to_string(model.wpm) <> " wpm")],
    ),
    html.button(
      [
        attribute.class(button_class),
        attribute.type_("button"),
        attribute.aria_label(aria_label),
        event.on_click(play_msg),
      ],
      [html.text(button_label)],
    ),
    html.div(
      [
        attribute.class("btn-play-spacer"),
        attribute.aria_hidden(True),
      ],
      [],
    ),
  ])
}
