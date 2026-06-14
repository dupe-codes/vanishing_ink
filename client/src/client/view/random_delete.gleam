//// Random destructive deletion settings controls. Extracted from
//// `client/view/settings` so that module stays under the 500-line file
//// budget: the cluster is a self-contained extraction seam — a single
//// section of the settings sheet (the page-per-page toggle, the
//// granularity / intensity segmented pickers, and the once-per-book
//// full-sweep button) that no other settings row depends on. The two
//// segmented-button helpers (`segment_class`, `bool_to_aria`) move with
//// it because the granularity and intensity selectors are their only
//// callers.
////
//// The section renders only in the reader view with an active book: the
//// page-per-page seed and the full-sweep scope both need a loaded book,
//// and the settings are persisted per book. It bundles two deliberately
//// different affordances — a persistent toggle and a fire-once button —
//// with the shared pickers.

import gleam/option.{Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{
  type Msg, ApplyFullSweep, SetDeletionGranularity, SetDeletionIntensity,
  TogglePageDelete,
}
import client/state.{
  type DeletionGranularity, type DeletionIntensity, type Model, DeletePhrase,
  DeleteSentence, DeleteWord, High, Low, Medium, Reader,
}

/// Render the random-deletion settings section. Like the per-book
/// override section, these controls render only in the reader view with
/// an active book — see the module header for the rationale.
pub fn view_section(model: Model) -> Element(Msg) {
  case model.view, model.active_book_id {
    Reader, Some(_) -> view_random_delete_panel(model)
    _, _ -> element.none()
  }
}

fn view_random_delete_panel(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-random-delete")], [
    html.hr([attribute.class("settings-divider")]),
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Random deletion")]),
    ]),
    html.div([attribute.class("settings-row-hint")], [
      html.text("Vanish a portion of the text before you reach it."),
    ]),
    view_page_delete_toggle(model),
    view_granularity_selector(model),
    view_intensity_selector(model),
    view_full_sweep_button(model),
  ])
}

fn view_page_delete_toggle(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Delete as I turn pages"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(model.random_page_delete_on),
        // The toggle carries no payload — `TogglePageDelete` flips the
        // model flag itself, so the checkbox's reported state is ignored.
        event.on_check(fn(_is_on) { TogglePageDelete }),
      ]),
    ]),
  ])
}

fn view_granularity_selector(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Granularity")]),
    ]),
    html.div(
      [
        attribute.class("settings-segmented"),
        attribute.attribute("role", "group"),
        attribute.aria_label("Deletion granularity"),
      ],
      [
        granularity_button(model, DeleteWord, "Word"),
        granularity_button(model, DeletePhrase, "Phrase"),
        granularity_button(model, DeleteSentence, "Sentence"),
      ],
    ),
  ])
}

fn granularity_button(
  model: Model,
  option: DeletionGranularity,
  label: String,
) -> Element(Msg) {
  let selected = model.deletion_granularity == option
  html.button(
    [
      segment_class(selected),
      attribute.type_("button"),
      attribute.attribute("aria-pressed", bool_to_aria(selected)),
      event.on_click(SetDeletionGranularity(option)),
    ],
    [html.text(label)],
  )
}

fn view_intensity_selector(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Intensity")]),
    ]),
    html.div(
      [
        attribute.class("settings-segmented"),
        attribute.attribute("role", "group"),
        attribute.aria_label("Deletion intensity"),
      ],
      [
        intensity_button(model, Low, "Low"),
        intensity_button(model, Medium, "Medium"),
        intensity_button(model, High, "High"),
      ],
    ),
  ])
}

fn intensity_button(
  model: Model,
  option: DeletionIntensity,
  label: String,
) -> Element(Msg) {
  let selected = model.deletion_intensity == option
  html.button(
    [
      segment_class(selected),
      attribute.type_("button"),
      attribute.attribute("aria-pressed", bool_to_aria(selected)),
      event.on_click(SetDeletionIntensity(option)),
    ],
    [html.text(label)],
  )
}

/// The "Sweep this book" button. Disabled once `full_sweep_applied` is
/// `True` — the action is once-per-book, ever, and irreversible. The
/// label flips to past-tense when spent so the disabled state reads as
/// "already done" rather than "temporarily unavailable".
fn view_full_sweep_button(model: Model) -> Element(Msg) {
  let spent = model.full_sweep_applied
  let label = case spent {
    True -> "Book swept"
    False -> "Sweep this book"
  }
  html.div([attribute.class("settings-row")], [
    html.button(
      [
        attribute.class("btn-bar btn-bar-danger"),
        attribute.type_("button"),
        attribute.disabled(spent),
        attribute.aria_label(
          "Sweep this book — delete a portion of the whole book at once",
        ),
        event.on_click(ApplyFullSweep),
      ],
      [html.text(label)],
    ),
  ])
}

fn segment_class(selected: Bool) -> attribute.Attribute(Msg) {
  case selected {
    True -> attribute.class("settings-segment is-active")
    False -> attribute.class("settings-segment")
  }
}

fn bool_to_aria(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
