import gleam/http
import gleeunit
import server/router
import wisp/simulate

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn status_route_returns_ok_json_test() {
  let response =
    router.handle_request(simulate.browser_request(http.Get, "/"))

  assert response.status == 200
  assert simulate.read_body(response) == "{\"status\":\"ok\"}"
}

pub fn unknown_route_returns_404_test() {
  let response =
    router.handle_request(simulate.browser_request(http.Get, "/nope"))

  assert response.status == 404
}
