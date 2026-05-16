//// Metadata-edit bottom sheet. Renders an overlay above the library
//// when `model.editing_metadata` is `Some(_)`, hosting a small form
//// for the three editable fields (`title`, `author`, `genre`). The
//// surface mirrors the add-book sheet pattern (scrim + inner panel
//// that stops click propagation) so taps inside the form do not
//// close the modal.
////
//// Save dispatches `SubmitEditMetadata`; the reducer fires the PATCH
//// and the sheet stays open with an in-flight indicator until the
//// response lands. Close dispatches `CloseEditMetadata` and discards
//// the in-progress draft.

import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{
  type Msg, CloseEditMetadata, SetEditMetadataAuthor, SetEditMetadataGenre,
  SetEditMetadataTitle, SubmitEditMetadata,
}
import client/state.{type MetadataEdit, type Model}
import client/view/overlay_helpers.{stop_click_propagation}

/// Top-level entry point. Returns `element.none()` when no edit is in
/// flight so the overlay never sits hidden in the DOM — keeps the
/// rendered tree small and the closed-state tests trivial.
pub fn view(model: Model) -> Element(Msg) {
  case model.editing_metadata {
    None -> element.none()
    Some(draft) ->
      html.div(
        [
          attribute.class("sheet-overlay open"),
          attribute.attribute("role", "dialog"),
          attribute.attribute("aria-modal", "true"),
          attribute.attribute("aria-label", "Edit book metadata"),
          event.on_click(CloseEditMetadata),
        ],
        [view_sheet_inner(draft)],
      )
  }
}

fn view_sheet_inner(draft: MetadataEdit) -> Element(Msg) {
  let submit_disabled = draft.submitting || string.trim(draft.title) == ""

  let error_banner = case draft.error {
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
      html.div([attribute.class("add-sheet-title")], [
        html.text("Edit Book Details"),
      ]),
      html.div([attribute.class("add-sheet-sub")], [
        html.text("Update the title, author, and genre for this book."),
      ]),
      view_text_field(
        label: "Title",
        value: draft.title,
        placeholder: "Book title",
        on_input: SetEditMetadataTitle,
      ),
      view_text_field(
        label: "Author",
        value: draft.author,
        placeholder: "Author (optional)",
        on_input: SetEditMetadataAuthor,
      ),
      view_text_field(
        label: "Genre",
        value: draft.genre,
        placeholder: "Genre (optional)",
        on_input: SetEditMetadataGenre,
      ),
      error_banner,
      view_save_button(draft.submitting, submit_disabled),
    ]),
  ])
}

fn view_text_field(
  label label: String,
  value value: String,
  placeholder placeholder: String,
  on_input on_input: fn(String) -> Msg,
) -> Element(Msg) {
  html.div([attribute.class("edit-metadata-field")], [
    html.label([attribute.class("paste-label")], [html.text(label)]),
    html.input([
      attribute.class("paste-input"),
      attribute.type_("text"),
      attribute.value(value),
      attribute.attribute("placeholder", placeholder),
      attribute.attribute("aria-label", label),
      event.on_input(on_input),
    ]),
  ])
}

fn view_save_button(submitting: Bool, disabled: Bool) -> Element(Msg) {
  let label = case submitting {
    True -> "Saving…"
    False -> "Save Changes"
  }
  html.button(
    [
      attribute.class("btn-add-book"),
      attribute.type_("button"),
      attribute.disabled(disabled),
      attribute.aria_label("Save metadata changes"),
      event.on_click(SubmitEditMetadata),
    ],
    [html.text(label)],
  )
}

