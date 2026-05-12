import gleeunit
import shared

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn book_id_round_trips_test() {
  let id = shared.book_id("the-iliad")

  assert id == "the-iliad"
}
