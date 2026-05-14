//// Touch gesture handling plus the shared sentence-erase / undo
//// primitives. `apply_erase` and `apply_undo` are the pure
//// model-mutation helpers behind every reducer arm that erases a
//// sentence or rewinds one — clicks, vim keys, swipes, undo
//// dispatches all converge on these two. `apply_touch_end` reads the
//// stashed `touch_start`, classifies the gesture, and routes the
//// result.

import gleam/list
import gleam/option.{None, Some}
import gleam/set
import lustre/effect.{type Effect}

import client/effects.{save_reading_state}
import client/gestures
import client/msg.{type Msg}
import client/state.{
  type Model, Manual, Model, RealTime, undo_stack_depth,
}
import client/state/helpers.{go_to_page}

/// Pop the most recent erase off `undo_stack` and remove its index
/// from `erased`. Returns the model unchanged when the stack is
/// empty. Shared between the `Undo` reducer arm and the SwipeRight
/// branch of `apply_touch_end` — both consume the head of the stack
/// in identical ways, and a copy-and-paste here would let the two
/// branches drift apart on a future refactor (e.g. one of them
/// growing a "max-undo-count" cap that the other forgot).
pub fn apply_undo(model: Model) -> Model {
  case model.undo_stack {
    [] -> model
    [last, ..rest] ->
      Model(..model, erased: set.delete(model.erased, last), undo_stack: rest)
  }
}

/// Insert `global_index` into `erased` and push it onto the
/// `undo_stack`, capped to `undo_stack_depth` entries. A repeat
/// erase on an already-erased sentence is a no-op so the undo
/// stack never carries duplicate entries — without that guard, an
/// `EraseFocused` press on a sentence the reader had earlier
/// clicked would push a second copy and force two undo presses to
/// restore one sentence. Shared between `EraseSentence` (from
/// click/tap) and `EraseFocused` (from the keyboard cursor).
pub fn apply_erase(model: Model, global_index: Int) -> Model {
  case set.contains(model.erased, global_index) {
    True -> model
    False ->
      Model(
        ..model,
        erased: set.insert(model.erased, global_index),
        undo_stack: [global_index, ..model.undo_stack]
          |> list.take(undo_stack_depth),
      )
  }
}

/// Resolve a `TouchEnd` into the next model state. Clears
/// `touch_start` unconditionally, then classifies the gesture
/// (`Tap` / `SwipeLeft` / `SwipeRight`) and routes the swipe to a
/// page navigation or an undo. A `Tap` in `Manual` mode is a
/// no-op — sentence erasure flows through the synthesised `click`
/// event on the `.sentence` span. A `Tap` in `RealTime` mode is
/// routed through the caller-supplied `on_realtime_tap` callback,
/// which the dispatcher wires up to `apply_space_pressed` so the
/// fade engine's start/pause/resume routing stays in one place.
/// Returns an `Effect` so the RealTime branch can schedule or
/// cancel the FFI word timer.
pub fn apply_touch_end(
  model: Model,
  x: Float,
  y: Float,
  on_realtime_tap: fn(Model) -> #(Model, Effect(Msg)),
) -> #(Model, Effect(Msg)) {
  let cleared = Model(..model, touch_start: None)
  case model.touch_start {
    None -> #(cleared, effect.none())
    Some(#(start_x, start_y)) ->
      case gestures.classify(start_x, start_y, x, y) {
        gestures.Tap ->
          case cleared.mode {
            Manual -> #(cleared, effect.none())
            RealTime -> on_realtime_tap(cleared)
          }
        gestures.SwipeLeft -> {
          let advanced = go_to_page(cleared, cleared.current_page + 1)
          let save_effect = case advanced.current_page == cleared.current_page {
            // Clamped to the last page — no real navigation, so no
            // state change to persist. Matches the `NextPage` arm's
            // own "no-op when already on the last page" branch.
            True -> effect.none()
            False -> save_reading_state(advanced)
          }
          #(advanced, save_effect)
        }
        gestures.SwipeRight -> {
          let undone = apply_undo(cleared)
          #(undone, save_reading_state(undone))
        }
      }
  }
}
