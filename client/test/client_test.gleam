//// JavaScript-target tests for the cross-target `shared` JSON contract.
//// The interesting invariant is that the encoder and decoder agree
//// under `JSON.stringify` / `JSON.parse` semantics on the V8 side — the
//// BEAM side gets the same assertions over in `shared/test/`. If either
//// target's `gleam_json` implementation drifts, one of these two test
//// pairs will fail in CI before any client code starts depending on
//// `BookId` payloads from the server.

import gleam/json
import gleeunit
import shared

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn book_id_round_trips_on_js_target_test() {
  let id = shared.book_id("the-iliad")

  let encoded = shared.book_id_to_json(id) |> json.to_string
  let decoded = json.parse(encoded, shared.book_id_decoder())

  assert encoded == "\"the-iliad\""
  assert decoded == Ok("the-iliad")
}

pub fn book_id_decoder_rejects_non_string_on_js_target_test() {
  let decoded = json.parse("42", shared.book_id_decoder())

  assert case decoded {
    Ok(_) -> False
    Error(_) -> True
  }
}
