//// Target-agnostic round-trip tests for the `shared` package. The
//// genuine invariant under test is that `book_id_to_json` and
//// `book_id_decoder` agree under JSON re-parsing — a property the type
//// system cannot establish on its own. Gleeunit runs these on whichever
//// target the consuming package picks (BEAM here, JavaScript over in
//// `client/test/`), so a regression on either side surfaces immediately.

import gleam/json
import gleeunit
import shared

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn book_id_round_trips_through_json_test() {
  let id = shared.book_id("the-iliad")

  let encoded = shared.book_id_to_json(id) |> json.to_string
  let decoded = json.parse(encoded, shared.book_id_decoder())

  assert encoded == "\"the-iliad\""
  assert decoded == Ok("the-iliad")
}

pub fn book_id_decoder_rejects_non_string_test() {
  // Integers do not satisfy the string decoder; the failure path matters
  // because the wire protocol is what the JS client will deserialise.
  let decoded = json.parse("42", shared.book_id_decoder())

  assert case decoded {
    Ok(_) -> False
    Error(_) -> True
  }
}
