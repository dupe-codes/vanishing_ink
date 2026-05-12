//// Vanishing Ink Lustre client entry point. Mounts a static "hello"
//// view to `#app` to prove the JavaScript target builds end-to-end and
//// the cross-target `shared` path dependency resolves. Subsequent
//// quests will replace this with the reader UI.

import lustre
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import shared

/// Placeholder book identifier exercised at build time so the path
/// dependency on `shared` is wired into the JavaScript bundle. The view
/// renders it as plain text — there is no real library yet.
const placeholder_book: shared.BookId = "placeholder"

pub fn main() -> Nil {
  let app = lustre.element(view())
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

fn view() -> Element(msg) {
  html.div([attribute.id("vi-shell")], [
    html.h1([], [html.text("Hello from Vanishing Ink")]),
    html.p([], [html.text("Currently reading: " <> placeholder_book)]),
  ])
}
