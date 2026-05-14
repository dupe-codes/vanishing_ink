//// Add-book affordances for the library surface: the floating action
//// button, the bottom sheet that opens on tap, and the ePub import
//// row at the top of the sheet body. Extracted from
//// `client/view/library.gleam` to keep that module under the 500-line
//// soft budget — the add-book sheet is one cohesive concern (a single
//// modal surface with its own header, file picker, and paste form)
//// and a natural seam for extraction.
////
//// Imports from `client/view/library.gleam` to here, never the
//// reverse, so the view-layer dependency graph stays a fan-in pattern
//// (sibling library modules → `library.gleam` → `view.gleam`).

import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/epub
import client/msg.{
  type Msg, EpubFileSelected, SetPasteText, SetPasteTitle, SubmitPaste,
  ToggleAddBook, ToggleSettings,
}
import client/state.{type Model}

/// Floating action button anchored to the bottom-right of the library
/// surface. Taps toggle the add-book sheet.
pub fn view_add_book_fab() -> Element(Msg) {
  html.button(
    [
      attribute.class("fab"),
      attribute.type_("button"),
      attribute.aria_label("Add book"),
      event.on_click(ToggleAddBook),
    ],
    [html.text("+")],
  )
}

/// Add-book bottom sheet. Rendered as an overlay that catches taps
/// outside the sheet to close it (mirroring the settings panel's
/// scrim semantics). When `add_book_open` is `False`, the overlay
/// is absent from the DOM rather than hidden via CSS — keeps the
/// rendered tree small and the closed-state tests trivial.
pub fn view_add_book_sheet(model: Model) -> Element(Msg) {
  case model.add_book_open {
    False -> element.none()
    True ->
      html.div(
        [
          attribute.class("sheet-overlay open"),
          attribute.attribute("role", "dialog"),
          attribute.attribute("aria-modal", "true"),
          attribute.attribute("aria-label", "Add a book"),
          event.on_click(ToggleAddBook),
        ],
        [view_add_book_sheet_inner(model)],
      )
  }
}

fn view_add_book_sheet_inner(model: Model) -> Element(Msg) {
  let submit_disabled =
    model.paste_submitting
    || string.trim(model.paste_title) == ""
    || string.trim(model.paste_text) == ""

  let error_banner = case model.paste_error {
    None -> element.none()
    Some(message) ->
      html.div(
        [attribute.class("paste-error"), attribute.attribute("role", "alert")],
        [html.text(message)],
      )
  }

  html.div([attribute.class("bottom-sheet"), stop_click_propagation()], [
    html.div(
      [
        attribute.class("sheet-handle"),
        attribute.attribute("aria-hidden", "true"),
      ],
      [],
    ),
    html.div([attribute.class("add-sheet-body")], [
      html.div([attribute.class("add-sheet-title")], [html.text("Add a Book")]),
      html.div([attribute.class("add-sheet-sub")], [
        html.text("Paste text or import an ePub to start reading."),
      ]),
      view_epub_import_row(model),
      html.label([attribute.class("paste-label")], [html.text("Title")]),
      html.input([
        attribute.class("paste-input"),
        attribute.type_("text"),
        attribute.value(model.paste_title),
        attribute.attribute("placeholder", "Book title"),
        attribute.attribute("aria-label", "Book title"),
        event.on_input(SetPasteTitle),
      ]),
      html.label([attribute.class("paste-label")], [
        html.text("Paste your text"),
      ]),
      html.textarea(
        [
          attribute.class("paste-area"),
          attribute.attribute("placeholder", "Paste the text you want to read…"),
          attribute.attribute("aria-label", "Book text"),
          event.on_input(SetPasteText),
        ],
        model.paste_text,
      ),
      error_banner,
      html.button(
        [
          attribute.class("btn-add-book"),
          attribute.type_("button"),
          attribute.disabled(submit_disabled),
          attribute.aria_label("Add to library"),
          event.on_click(SubmitPaste),
        ],
        [
          html.text(case model.paste_submitting {
            True -> "Adding…"
            False -> "Add to Library"
          }),
        ],
      ),
    ]),
  ])
}

/// File picker row at the top of the add-book sheet body. Sits above
/// the paste form so the ePub flow is the most visible affordance —
/// pasting still works for readers who prefer to copy raw text. The
/// label wraps the input so a tap anywhere on the row opens the OS
/// file dialog; the actual `<input>` is hidden via CSS rather than
/// `display: none` so it stays accessible to screen readers.
///
/// Disabled while `paste_submitting` is `True` so a second pick
/// during an in-flight parse cannot orphan the first result —
/// matches the submit-button gating below.
fn view_epub_import_row(model: Model) -> Element(Msg) {
  let label_text = case model.paste_submitting {
    True -> "Importing ePub…"
    False -> "Import an ePub file"
  }
  let label_class = case model.paste_submitting {
    True -> "epub-import-button is-loading"
    False -> "epub-import-button"
  }
  html.label([attribute.class(label_class)], [
    html.input([
      attribute.class("epub-import-input"),
      attribute.type_("file"),
      attribute.attribute("accept", ".epub,application/epub+zip"),
      attribute.attribute("aria-label", "Import an ePub file"),
      attribute.disabled(model.paste_submitting),
      epub.on_file_picked(EpubFileSelected),
    ]),
    html.span([attribute.class("epub-import-label")], [html.text(label_text)]),
  ])
}

/// Attach a click listener that stops propagation but never dispatches
/// a message. Used by the inner sheet markup to keep taps inside the
/// surface from bubbling up to the scrim's close handler.
///
/// Duplicated in `client/view/library.gleam` and
/// `client/view/settings.gleam` rather than imported across sibling
/// view modules so the view-layer dependency graph stays a fan-in
/// pattern (each view module is a leaf under `client/view.gleam`).
fn stop_click_propagation() -> attribute.Attribute(Msg) {
  event.on("click", decode.failure(ToggleSettings, "stop-propagation"))
  |> event.stop_propagation
}
