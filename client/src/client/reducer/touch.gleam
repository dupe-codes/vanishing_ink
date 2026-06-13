//// Touch gesture handling plus the shared sentence-erase primitive.
//// `apply_erase` is the pure model-mutation helper behind every
//// reducer arm that erases a sentence — clicks, vim keys, taps all
//// converge on it. `apply_touch_end` reads the stashed `touch_start`,
//// classifies the gesture, and routes the result.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import lustre/effect.{type Effect}

import client/effects.{save_reading_state}
import client/gestures
import client/msg.{type Msg}
import client/state.{type Model, Manual, Model, RealTime}
import client/state/helpers.{go_to_page}

/// Insert `global_index` into `erased`. A repeat erase on an
/// already-erased sentence is a no-op. Erasure is permanent — there
/// is no recovery path. Shared between `EraseSentence` (from
/// click/tap) and `EraseFocused` (from the keyboard cursor).
///
/// Project the erased sentence onto its constituent words via
/// `sentence_word_indices` and fold them into `erased_words`. The
/// session lifecycle counts `set.size(erased_words)` to compute
/// `words_read` for the closing PUT, so without this projection a
/// Manual-mode session that erased entire sentences would report zero
/// words read. Missing entries (a sentence index with no matching
/// dict key) collapse to no word-level changes — a defensive fallback
/// for a future code path that erases via a synthetic global index
/// outside the loaded document.
pub fn apply_erase(model: Model, global_index: Int) -> Model {
  case set.contains(model.erased, global_index) {
    True -> model
    False -> {
      let word_indices = case
        dict.get(model.sentence_word_indices, global_index)
      {
        Ok(indices) -> indices
        Error(_) -> []
      }
      let updated_erased_words =
        list.fold(word_indices, model.erased_words, fn(acc, idx) {
          set.insert(acc, idx)
        })
      Model(
        ..model,
        erased: set.insert(model.erased, global_index),
        erased_words: updated_erased_words,
      )
    }
  }
}

/// Resolve a `TouchEnd` into the next model state. Clears
/// `touch_start` unconditionally, then classifies the gesture
/// (`Tap` / `SwipeLeft` / `SwipeRight`) and routes a `SwipeLeft` to a
/// page navigation. `SwipeRight` is a no-op — it used to trigger
/// erase-undo, which has been removed; erasure is now permanent. A
/// `Tap` in `Manual` mode is a
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
        // `SwipeRight` once triggered erase-undo. Erasure is now
        // permanent, so a right swipe carries no meaning — it leaves
        // the model untouched rather than dispatching a removed
        // action. Backward page navigation is intentionally not wired.
        gestures.SwipeRight -> #(cleared, effect.none())
      }
  }
}
