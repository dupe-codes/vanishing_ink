//// Top-level view dispatcher. Branches on `model.view`:
//// `Library` renders the book grid plus the add-book bottom sheet;
//// `Reader` renders the paginated reading surface against
//// `model.text`. The settings panel rides as a sibling overlay
//// rendered conditionally on `model.settings_open` — it is only ever
//// in the DOM when the panel is open, so the surrounding rendering
//// is unaffected by settings state.
////
//// The shell `<div>` carries `class="vi-app"` rather than the older
//// `"reader"` because the surface now hosts both views; the CSS
//// rule it anchors (`#vi-shell` height) is selector-based and
//// unaffected by the class rename.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

import client/msg.{type Msg}
import client/state.{type Model, Library, Reader}
import client/view/library as library_view
import client/view/reader as reader_view
import client/view/reader/jump_menu
import client/view/settings as settings_view

pub fn view(model: Model) -> Element(Msg) {
  let body = case model.view {
    Library -> library_view.view(model)
    Reader -> reader_view.view(model)
  }

  let overlay = case model.settings_open {
    True -> settings_view.view(model)
    False -> element.none()
  }

  // The jump menu overlays the reader only — there is nothing to
  // jump in the library, so the overlay is gated on `view == Reader`
  // even though `jump_menu_open` is a `Bool` independent of `view`.
  // A `GoToLibrary` dispatch flips the view back and the menu
  // disappears without needing to clear `jump_menu_open` explicitly.
  let jump_overlay = case model.view {
    Reader -> jump_menu.view(model)
    Library -> element.none()
  }

  html.div([attribute.id("vi-shell"), attribute.class("vi-app")], [
    body,
    overlay,
    jump_overlay,
  ])
}
