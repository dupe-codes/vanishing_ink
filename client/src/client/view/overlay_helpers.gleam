//// Shared view-layer helpers for the overlay / bottom-sheet pattern.
//// Lives one level above the sibling overlay modules
//// (`settings`, `stats`, `library`, `library/add_book`,
//// `library/edit_metadata`, `reader/book_stats`, `reader/jump_menu`)
//// so every panel can pull the same canonical implementation in
//// without forcing a cross-sibling import.
////
//// The view-layer dependency graph was historically organised as a
//// fan-in pattern (each leaf view module routed back through
//// `client/view.gleam`); the helpers here are deliberately scoped to
//// pure attribute / element shims that have no model dependency, so
//// adding this shared leaf does not introduce a cycle — every caller
//// only ever depends on `overlay_helpers`, never the reverse.

import gleam/dynamic/decode
import lustre/attribute
import lustre/event

import client/msg.{type Msg, NoOp}

/// Attach a click listener that stops propagation but never dispatches
/// a message. The canonical implementation for the overlay / sheet
/// pattern: panels swallow clicks so taps inside them never reach the
/// scrim's close handler.
///
/// Implementation note: Lustre's `event.stop_propagation` is an
/// attribute modifier that operates on an event attribute, not a
/// standalone attribute — so the propagation guard needs a paired
/// event handler to attach to. `event.on` takes a `Decoder(Msg)`;
/// `decode.failure(...)` always fails the decode, which means the
/// runtime silently drops the event (`stopPropagation` runs
/// unconditionally on the always-attached attribute, but the model
/// dispatch only fires on a successful decode). The placeholder Msg
/// is the dedicated `NoOp` sentinel; even if a future refactor wires
/// it to a real event, the reducer's `NoOp` arm is a unit-noop that
/// returns the model unchanged.
pub fn stop_click_propagation() -> attribute.Attribute(Msg) {
  event.on("click", decode.failure(NoOp, "stop-propagation"))
  |> event.stop_propagation
}
