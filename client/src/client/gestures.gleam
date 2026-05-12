//// Touch-gesture primitives for the reader. Pure Gleam helpers
//// (`classify`, `Gesture`) plus Lustre `Attribute` builders that wire
//// `touchstart` and `touchend` decoders into the update loop.
////
//// The gesture pipeline is split between two clean halves so the
//// algorithm stays testable:
////
//// * `on_touch_start` / `on_touch_end` only emit the raw `(x, y)`
////   coordinates of the touch. They don't decide what the gesture
////   was — `update` reads the touchstart position back off the model
////   on `touchend` and feeds both positions into `classify`.
//// * `classify` is total and pure: given a start point and an end
////   point, it returns one of `Tap`, `SwipeLeft`, or `SwipeRight`.
////   No DOM, no I/O, no `Effect`. The reducer can stay synchronous.
////
//// Discrimination rule: a horizontal delta greater than
//// `swipe_threshold` AND larger than the vertical delta is a swipe.
//// Everything else is a tap. The horizontal-dominates check stops
//// near-diagonal motion from being treated as a horizontal swipe.
////
//// `clientX` / `clientY` are decoded as `Float` so a browser that
//// reports sub-pixel coordinates (modern Safari does) round-trips
//// without coercion errors.

import gleam/dynamic/decode
import lustre/attribute.{type Attribute}
import lustre/event

/// Minimum horizontal movement, in CSS pixels, that promotes a touch
/// from a tap to a swipe. Tuned to comfortably exceed the browser's
/// own click-cancellation threshold (typically ~10–15px) so the
/// 15px–swipe_threshold band stays inert rather than producing
/// accidental erases mid-swipe.
pub const swipe_threshold: Float = 50.0

/// Classified touch outcome. `Tap` covers both intentional taps and
/// the dead-zone between the browser's click threshold and our
/// swipe threshold — both cases should leave reading state alone.
pub type Gesture {
  /// Motion below the swipe threshold (or dominated by the vertical
  /// axis). Caller is free to ignore — sentence erasure flows
  /// through the `click` event, not through `Tap`.
  Tap
  /// Horizontal motion to the left (end_x < start_x). Conventionally
  /// "advance the page" in a left-to-right reading flow.
  SwipeLeft
  /// Horizontal motion to the right (end_x > start_x). Conventionally
  /// "go back" — the reducer maps this to `Undo` if the undo stack is
  /// non-empty, otherwise `PreviousPage`.
  SwipeRight
}

/// Classify a touch by its start and end coordinates. Pure and
/// total — every coordinate pair maps to exactly one `Gesture`.
///
/// A swipe requires both:
///
/// * `|dx| > swipe_threshold`
/// * `|dx| > |dy|` (horizontal dominates)
///
/// Otherwise the motion is a `Tap`. The direction of a swipe is
/// taken from the sign of `dx`, not from `|dx|`.
pub fn classify(
  start_x: Float,
  start_y: Float,
  end_x: Float,
  end_y: Float,
) -> Gesture {
  let dx = end_x -. start_x
  let dy = end_y -. start_y
  let abs_dx = float_abs(dx)
  let abs_dy = float_abs(dy)
  // Compound conditions are split into nested `case` discriminators
  // per the coding conventions ("Split compound conditions into
  // nested if/else").
  case abs_dx >. swipe_threshold {
    False -> Tap
    True ->
      case abs_dx >. abs_dy {
        False -> Tap
        True ->
          case dx <. 0.0 {
            True -> SwipeLeft
            False -> SwipeRight
          }
      }
  }
}

fn float_abs(value: Float) -> Float {
  case value <. 0.0 {
    True -> 0.0 -. value
    False -> value
  }
}

// ---------------------------------------------------------------------------
// Lustre attribute builders
// ---------------------------------------------------------------------------

/// Listen for `touchstart` on the host element. Reads `clientX` and
/// `clientY` of the primary (first) touch and routes them into the
/// caller-provided message constructor. The decoder is silent on
/// failure — multi-touch events with an empty `touches` list (which
/// shouldn't happen on `touchstart`, but the browser is the source
/// of truth, not the spec) are dropped rather than producing a bad
/// message.
pub fn on_touch_start(to_msg: fn(Float, Float) -> msg) -> Attribute(msg) {
  event.on("touchstart", touch_decoder("touches", to_msg))
}

/// Listen for `touchend`. Touchend's primary touch lives in
/// `changedTouches` — `touches` is the *remaining* active touches
/// (empty for a single-finger lift). Decoding from the wrong list
/// would silently drop every single-touch end on real devices.
pub fn on_touch_end(to_msg: fn(Float, Float) -> msg) -> Attribute(msg) {
  event.on("touchend", touch_decoder("changedTouches", to_msg))
}

/// Listen for `touchcancel`. The browser fires this — *without* a
/// matching `touchend` — whenever it steals an in-flight touch
/// (system back gesture, notification pull-down, modal scrim,
/// scroll interruption). If we don't clear `touch_start` here, the
/// stale coordinates from the cancelled gesture corrupt the next
/// `touchend` the document sees: the classifier compares the
/// cancelled-touch start against a fresh end and emits a phantom
/// swipe the reader never made. The decoder is a constant — no
/// coordinates needed, the message just resets state.
pub fn on_touch_cancel(message: msg) -> Attribute(msg) {
  event.on("touchcancel", decode.success(message))
}

fn touch_decoder(
  list_field: String,
  to_msg: fn(Float, Float) -> msg,
) -> decode.Decoder(msg) {
  // `decode.at` requires uniform path-segment types per call, so the
  // string field name and the numeric `[0]` index are decoded with
  // separate nested calls rather than as one mixed path. `clientX`
  // and `clientY` are read as `Float` because Safari (and Chrome
  // with `transform: scale`) reports sub-pixel coordinates.
  use client_x <- decode.field(
    list_field,
    decode.at([0], decode.at(["clientX"], decode.float)),
  )
  use client_y <- decode.field(
    list_field,
    decode.at([0], decode.at(["clientY"], decode.float)),
  )
  decode.success(to_msg(client_x, client_y))
}
