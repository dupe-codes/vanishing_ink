import gleeunit
import shared

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn shared_book_id_constructor_test() {
  let id = shared.book_id("the-iliad")

  assert id == "the-iliad"
}
