//// Reducer arms for the metadata-edit surface. Houses the six Msg
//// arms that drive the edit sheet:
////
////   - `OpenEditMetadata(id)`     — seed the draft from a library row.
////   - `CloseEditMetadata`        — discard the draft, close the sheet.
////   - `SetEditMetadataTitle`     — controlled title input.
////   - `SetEditMetadataAuthor`    — controlled author input.
////   - `SetEditMetadataGenre`     — controlled genre input.
////   - `SubmitEditMetadata`       — validate + PATCH `/api/books/:id`.
////   - `BookMetadataUpdated`      — resolve the PATCH response.
////
//// Extracted from `client/reducer.gleam` so the top-level dispatcher
//// stays under the 800-line hard limit; the same shape every other
//// per-feature reducer module follows (settings, jump, focus, touch,
//// book).

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect.{type Effect}

import client/effects.{describe_fetch_error, update_book_metadata}
import client/ffi.{type FetchError}
import client/msg.{type Msg}
import client/state.{type MetadataEdit, type Model, MetadataEdit, Model}
import client/types.{type BookMeta}

/// Open the metadata edit sheet for the book with this id. Seeds the
/// draft with the values currently on the row so the form starts
/// pre-filled. A stale id (no matching book) leaves the model
/// untouched — a `BookDeleted` race between the tap and dispatch
/// drops the cards before the open arm runs.
pub fn apply_open_edit_metadata(
  model: Model,
  id: String,
) -> #(Model, Effect(Msg)) {
  case list.find(model.books, fn(book) { book.id == id }) {
    Error(_) -> #(model, effect.none())
    Ok(book) -> #(
      Model(..model, editing_metadata: Some(draft_from_meta(book))),
      effect.none(),
    )
  }
}

/// Build the initial draft from a `BookMeta`. The wire fields ride as
/// `Option(String)` because the columns are nullable; the form binds
/// to plain `String` so the inputs can render an empty value as an
/// empty string rather than the literal "null".
fn draft_from_meta(book: BookMeta) -> MetadataEdit {
  MetadataEdit(
    book_id: book.id,
    title: book.title,
    author: option.unwrap(book.author, ""),
    genre: option.unwrap(book.genre, ""),
    submitting: False,
    error: None,
  )
}

/// Discard the in-progress draft and close the sheet. Symmetric with
/// `apply_open_edit_metadata` — no PATCH fires on close, the row
/// stays at its persisted state.
pub fn apply_close_edit_metadata(model: Model) -> #(Model, Effect(Msg)) {
  #(Model(..model, editing_metadata: None), effect.none())
}

/// Stamp a controlled title input change on the draft. A no-op when
/// the sheet is closed (`editing_metadata: None`) — the Msg cannot
/// arrive from a hidden input, but the guard makes the arm total
/// over the model shape.
pub fn apply_set_edit_metadata_title(
  model: Model,
  value: String,
) -> #(Model, Effect(Msg)) {
  apply_set_edit_field(model, fn(draft) {
    MetadataEdit(..draft, title: value, error: None)
  })
}

/// Stamp a controlled author input change on the draft. Empty input
/// is preserved verbatim — the trim-to-`None` happens at PATCH time,
/// not on every keystroke, so the input stays a 1:1 controlled
/// projection of the typed value.
pub fn apply_set_edit_metadata_author(
  model: Model,
  value: String,
) -> #(Model, Effect(Msg)) {
  apply_set_edit_field(model, fn(draft) {
    MetadataEdit(..draft, author: value, error: None)
  })
}

/// Stamp a controlled genre input change on the draft. Same shape as
/// the author arm.
pub fn apply_set_edit_metadata_genre(
  model: Model,
  value: String,
) -> #(Model, Effect(Msg)) {
  apply_set_edit_field(model, fn(draft) {
    MetadataEdit(..draft, genre: value, error: None)
  })
}

fn apply_set_edit_field(
  model: Model,
  update_draft: fn(MetadataEdit) -> MetadataEdit,
) -> #(Model, Effect(Msg)) {
  case model.editing_metadata {
    None -> #(model, effect.none())
    Some(draft) -> #(
      Model(..model, editing_metadata: Some(update_draft(draft))),
      effect.none(),
    )
  }
}

/// Validate the draft and fire `update_book_metadata`. Empty title
/// surfaces a validation message inside the sheet; an in-flight save
/// (`submitting: True`) short-circuits so a double-tap cannot fire
/// two PATCHes.
pub fn apply_submit_edit_metadata(model: Model) -> #(Model, Effect(Msg)) {
  case model.editing_metadata {
    None -> #(model, effect.none())
    Some(draft) ->
      case draft.submitting {
        True -> #(model, effect.none())
        False -> submit_draft(model, draft)
      }
  }
}

fn submit_draft(model: Model, draft: MetadataEdit) -> #(Model, Effect(Msg)) {
  let title = string.trim(draft.title)
  case title {
    "" -> #(
      Model(
        ..model,
        editing_metadata: Some(
          MetadataEdit(..draft, error: Some("Please add a title.")),
        ),
      ),
      effect.none(),
    )
    _ -> #(
      Model(
        ..model,
        editing_metadata: Some(
          MetadataEdit(..draft, submitting: True, error: None),
        ),
      ),
      update_book_metadata(
        id: draft.book_id,
        title: title,
        author: trim_to_option(draft.author),
        genre: trim_to_option(draft.genre),
      ),
    )
  }
}

/// Reduce a trimmed input string into the wire-format `Option(String)`:
/// empty string becomes `None`, a non-empty trimmed value becomes
/// `Some(trimmed)`. Matches the server's "Cleared vs Set" axis so a
/// reader who blanks the author field nulls the column rather than
/// persisting an empty literal.
fn trim_to_option(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    trimmed -> Some(trimmed)
  }
}

/// Resolve the PATCH response. On `Ok(meta)`, replace the matching
/// row in `model.books` with the server's authoritative copy and
/// close the sheet. On `Error(_)`, leave the sheet open with a
/// human-readable error message so the reader can retry.
pub fn apply_book_metadata_updated(
  model: Model,
  id: String,
  result: Result(BookMeta, FetchError),
) -> #(Model, Effect(Msg)) {
  case result {
    Ok(updated) -> apply_metadata_updated_ok(model, id, updated)
    Error(error) -> apply_metadata_updated_error(model, error)
  }
}

fn apply_metadata_updated_ok(
  model: Model,
  id: String,
  updated: BookMeta,
) -> #(Model, Effect(Msg)) {
  let books =
    list.map(model.books, fn(book) {
      case book.id == id {
        True -> updated
        False -> book
      }
    })
  #(
    Model(..model, books: books, editing_metadata: None, library_error: None),
    effect.none(),
  )
}

fn apply_metadata_updated_error(
  model: Model,
  error: FetchError,
) -> #(Model, Effect(Msg)) {
  case model.editing_metadata {
    None -> #(model, effect.none())
    Some(draft) -> #(
      Model(
        ..model,
        editing_metadata: Some(
          MetadataEdit(
            ..draft,
            submitting: False,
            error: Some(describe_fetch_error(error)),
          ),
        ),
      ),
      effect.none(),
    )
  }
}
