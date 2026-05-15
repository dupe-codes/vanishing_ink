//// Numeric primitives shared across the client. Kept as a pure-leaf
//// module — no imports from any other `client/*` module — so any
//// module that needs a clamp can pull it in without dragging in the
//// `Model` ADT or any of its dependencies.
////
//// The settings sliders (`client/reducer/settings`) delegate every
//// clamp call here; the search snippet helper (`client/search`) does
//// the same when bracketing its snippet window into the haystack;
//// and the test surface pins the boundary behaviour at the lo and hi
//// rails directly against this module rather than threading the
//// assertion through a caller.
////
//// Lives at the foundation of the dependency graph so the leaves that
//// import it (`client/state/helpers`, `client/search`,
//// `client/reducer/settings`) do not create a cycle. `client/state`
//// already imports `client/search`; routing `client/search` through
//// `client/state/helpers` for this one helper would re-introduce a
//// `search → state/helpers → state → search` loop. The split here is
//// what keeps the cycle off the import graph while still single-
//// sourcing the utility.

/// Clamp `value` into `[lo, hi]`. Defensive helper for slider /
/// stepper inputs; the inputs themselves carry `min` and `max`
/// attributes, but a future programmatic call (or a malformed event)
/// could bypass them, so the reducer is the authority.
///
/// Exposed for tests that pin the boundary behaviour at the lo and
/// hi rails — the slider arms in the reducer delegate to this helper,
/// so asserting it directly is the smallest unit that proves the
/// out-of-range guard works.
pub fn clamp_int(value: Int, lo: Int, hi: Int) -> Int {
  case value < lo, value > hi {
    True, _ -> lo
    _, True -> hi
    _, _ -> value
  }
}

/// Float counterpart to `clamp_int`. Exposed for the same reason —
/// the line-spacing and ghost-opacity sliders both delegate to this
/// helper.
pub fn clamp_float(value: Float, lo: Float, hi: Float) -> Float {
  case value <. lo, value >. hi {
    True, _ -> lo
    _, True -> hi
    _, _ -> value
  }
}
