//// Vanishing Ink Lustre client entry point. Mounts a static "hello"
//// view to `#app` to prove the JavaScript target builds end-to-end and
//// the cross-target `shared` path dependency resolves. Subsequent
//// quests will replace this with the reader UI.

import gleam/io
import gleam/string
import lustre
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import shared

/// Placeholder book identifier exercised at build time so the path
/// dependency on `shared` is wired into the JavaScript bundle. The view
/// renders it as plain text — there is no real library yet, and this
/// constant must be replaced when the reader UI lands.
const placeholder_book: shared.BookId = "placeholder"

pub fn main() -> Nil {
  let app = lustre.element(view())

  case lustre.start(app, "#app", Nil) {
    Ok(_) -> Nil
    Error(reason) -> {
      // The realistic failures are `ElementNotFound("#app")` (the HTML
      // shell forgot the mount point) and `NotABrowser` (the bundle was
      // loaded outside a browser by mistake). Log the structured reason
      // before panicking so the operator sees what went wrong rather
      // than a bare runtime error.
      io.println("Lustre failed to mount on #app: " <> string.inspect(reason))
      panic as "lustre.start failed; see the logged reason above"
    }
  }
}

fn view() -> Element(msg) {
  html.div([attribute.id("vi-shell")], [
    html.h1([], [html.text("Hello from Vanishing Ink")]),
    html.p([], [html.text("Currently reading: " <> placeholder_book)]),
  ])
}
