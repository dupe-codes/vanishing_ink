//// Reader bottom bar — mode-aware, with two side-rails:
////
//// * **Preview banner** — when `model.jump_preview` is `Some(_)` the
////   inner row swaps to `[← Go Back]  Previewing page N  [Lock In ✓]`
////   so the reader resolves the preview rather than turning pages
////   underneath it.
//// * **Jump button** — both mode branches render a small `Jump`
////   affordance via `view_jump_button` so the menu is reachable
////   without leaving the bottom bar.
////
//// The outer `.reader-bottom-bar` carries the safe-area-bottom
//// padding and the warm chrome background. Outside the preview
//// state, the inner row swaps shape with `model.mode`:
////
//// * Manual — `[↩ Undo]   Page N of M   [Jump]   [Turn Page →]`
//// * RealTime — `WPM readout   [▶ / ⏸]   [Jump]`

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{
  type Msg, LockInJump, NextPage, PauseFade, ResumeFade, StartFade,
  ToggleJumpMenu, Undo, UndoJump,
}
import client/state.{type Model, Manual, Paused, RealTime, Running, Stopped}

/// Render the outer bottom bar. While a Jump Ahead preview is in
/// flight the bar swaps to the preview banner — "Go Back" /
/// "Lock In" — instead of the mode-aware inner row, so the reader
/// can resolve the preview without the regular page-turn affordance
/// stealing focus.
///
/// The reducer never lands the reader view without a `model.mode`
/// value, so the case is exhaustive on the two real variants.
pub fn view(model: Model, total: Int) -> Element(Msg) {
  let inner = case model.jump_preview {
    Some(_) -> view_preview_banner(model)
    None ->
      case model.mode {
        Manual -> view_bottom_manual(model, total)
        RealTime -> view_bottom_realtime(model, total)
      }
  }
  html.div([attribute.class("reader-bottom-bar")], [inner])
}

/// Preview banner shown while `model.jump_preview` is `Some(_)`.
/// Layout: `[← Go Back]  Previewing page N  [Lock In ✓]`. Distinct
/// background tone via `.reader-bottom-preview` so the reader can
/// see at a glance that the bar has switched out of regular reading.
fn view_preview_banner(model: Model) -> Element(Msg) {
  let label = "Previewing page " <> int.to_string(model.current_page + 1)
  html.div([attribute.class("reader-bottom-preview")], [
    html.button(
      [
        attribute.class("btn-bar"),
        attribute.type_("button"),
        attribute.aria_label("Undo jump and go back"),
        event.on_click(UndoJump),
      ],
      [html.text("← Go Back")],
    ),
    html.div([attribute.class("reader-preview-label")], [html.text(label)]),
    html.button(
      [
        attribute.class("btn-bar primary"),
        attribute.type_("button"),
        attribute.aria_label("Lock in jump"),
        event.on_click(LockInJump),
      ],
      [html.text("Lock In ✓")],
    ),
  ])
}

/// Render the secondary "Jump" affordance. Disabled when there's
/// nowhere to jump (`current_page` is already on the last page or
/// pagination hasn't yet produced any pages). Shared between the
/// manual and real-time bottom-bar branches so the affordance reads
/// consistently across modes.
fn view_jump_button(model: Model, total: Int) -> Element(Msg) {
  let disabled = total <= 1 || model.current_page >= total - 1
  html.button(
    [
      attribute.class("btn-bar jump"),
      attribute.type_("button"),
      attribute.disabled(disabled),
      attribute.aria_label("Open jump menu"),
      event.on_click(ToggleJumpMenu),
    ],
    [html.text("Jump")],
  )
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
    view_jump_button(model, total),
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
fn view_bottom_realtime(model: Model, total: Int) -> Element(Msg) {
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
    view_jump_button(model, total),
  ])
}
