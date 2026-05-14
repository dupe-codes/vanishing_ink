//// Library view: app bar, scrollable body (hero card, grid, empty
//// state, error banner), floating action button, add-book bottom
//// sheet, and delete-confirmation overlay.
////
//// Mirrors the mobile prototype at
//// `local/design-mocks/vanishing-ink/mobile-library-prototype.html` —
//// the warm app bar with the Vanishing Ink wordmark, a "Continue
//// Reading" hero card for the most-recently-read book, a 2-column
//// grid for the remaining titles, and a floating action button that
//// opens the add-book bottom sheet. The empty state and the
//// fetch-error state both surface inside the same `.lib-body`
//// container so the chrome never reshuffles between states.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/set
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/epub
import client/msg.{
  type Msg, CancelDelete, ConfirmDelete, EpubFileSelected, ExecuteDelete,
  OpenBook, SetPasteText, SetPasteTitle, SubmitPaste, ToggleAddBook,
  ToggleSettings,
}
import client/state.{type Model, cover_color_for_title}
import client/types.{type BookMeta}

/// Render the library view: app bar + scrollable body (hero card,
/// grid or empty state, error banner) + FAB + add-book sheet.
pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("view-library")], [
    view_library_appbar(),
    html.div([attribute.class("lib-scroll")], [view_library_body(model)]),
    view_add_book_fab(),
    view_add_book_sheet(model),
    view_delete_confirm_overlay(model),
  ])
}

fn view_library_appbar() -> Element(Msg) {
  html.div([attribute.class("lib-appbar")], [
    html.div([attribute.class("lib-appbar-inner")], [
      html.div([attribute.class("app-wordmark")], [
        html.div(
          [
            attribute.class("wordmark-dot"),
            attribute.attribute("aria-hidden", "true"),
          ],
          [],
        ),
        html.span([], [html.text("Vanishing Ink")]),
      ]),
      // Settings is reachable from the library so global preferences
      // (theme, font, dyslexia mode, default pacing) can be tweaked
      // before any book is open — without this, the gear was only
      // available once the reader entered a book, hiding a useful
      // surface behind a navigation step.
      html.button(
        [
          attribute.class("btn-icon"),
          attribute.aria_label("Open settings"),
          attribute.type_("button"),
          event.on_click(ToggleSettings),
        ],
        [html.text("⚙")],
      ),
    ]),
  ])
}

/// Library body. Surface order — fetch error (if any) → hero card →
/// grid header + grid (or empty state). Keeps the chrome stable so
/// loading / error / populated states all use the same column.
fn view_library_body(model: Model) -> Element(Msg) {
  let error_banner = case model.library_error {
    None -> element.none()
    Some(message) -> view_library_error(message)
  }

  let sorted = sort_books_by_recency(model.books)
  let hero_book = hero_candidate(sorted)
  let grid_books = grid_candidates(sorted, hero_book)

  // The hero and each grid card need to know whether their delete
  // request is in flight so the × badge can render disabled. Threading
  // a closure (rather than the raw set) keeps the lookup out of the
  // view layer's vocabulary — `view_book_card` doesn't have to know
  // a `Set` exists, only that "is this id currently being deleted?"
  // is a one-call query.
  let is_deleting = fn(id: String) -> Bool {
    set.contains(model.deleting_book_ids, id)
  }

  let hero = case hero_book {
    None -> element.none()
    Some(book) -> view_hero_card(book, is_deleting(book.id))
  }

  let body_main = case model.books_loading, model.books {
    True, _ -> view_library_loading()
    False, [] -> view_library_empty()
    False, _ -> view_library_grid(grid_books, is_deleting)
  }

  html.div([attribute.class("lib-body")], [error_banner, hero, body_main])
}

/// Delete confirmation modal. Rendered as a full-screen overlay when
/// `confirm_delete_id` is `Some(_)`. Tapping the scrim cancels;
/// tapping Delete fires `ExecuteDelete`.
fn view_delete_confirm_overlay(model: Model) -> Element(Msg) {
  case model.confirm_delete_id {
    None -> element.none()
    Some(book_id) -> {
      let title = case list.find(model.books, fn(b) { b.id == book_id }) {
        Ok(book) -> book.title
        Error(_) -> "this book"
      }
      html.div(
        [
          attribute.class("sheet-overlay open"),
          attribute.attribute("role", "dialog"),
          attribute.attribute("aria-modal", "true"),
          attribute.aria_label("Confirm delete"),
          event.on_click(CancelDelete),
        ],
        [
          html.div(
            [
              attribute.class("delete-confirm-sheet"),
              stop_click_propagation(),
            ],
            [
              html.div([attribute.class("delete-confirm-title")], [
                html.text("Delete \"" <> title <> "\"?"),
              ]),
              html.div([attribute.class("delete-confirm-sub")], [
                html.text(
                  "This will permanently remove the book and its reading history.",
                ),
              ]),
              html.div([attribute.class("delete-confirm-actions")], [
                html.button(
                  [
                    attribute.class("btn-bar"),
                    attribute.type_("button"),
                    event.on_click(CancelDelete),
                  ],
                  [html.text("Cancel")],
                ),
                html.button(
                  [
                    attribute.class("btn-bar btn-bar-danger"),
                    attribute.type_("button"),
                    event.on_click(ExecuteDelete(book_id)),
                  ],
                  [html.text("Delete")],
                ),
              ]),
            ],
          ),
        ],
      )
    }
  }
}

/// Sort by `last_read_at` descending, with unread books (None)
/// falling to the end. Books with equal timestamps fall back to
/// `uploaded_at` descending so the order is total — equal-keyed
/// inputs would otherwise rely on `list.sort`'s stability for
/// readable output.
fn sort_books_by_recency(books: List(BookMeta)) -> List(BookMeta) {
  list.sort(books, compare_by_recency)
}

fn compare_by_recency(a: BookMeta, b: BookMeta) -> order.Order {
  case a.last_read_at, b.last_read_at {
    Some(a_ts), Some(b_ts) ->
      case string.compare(b_ts, a_ts) {
        order.Eq -> string.compare(b.uploaded_at, a.uploaded_at)
        ord -> ord
      }
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> string.compare(b.uploaded_at, a.uploaded_at)
  }
}

/// The "Continue Reading" hero is the most-recently-read book; it
/// is only surfaced when at least one book has a non-None
/// `last_read_at`. A brand-new account (every book unread) skips
/// the hero entirely so the reader is not encouraged to "continue"
/// reading something they never started.
fn hero_candidate(sorted: List(BookMeta)) -> Option(BookMeta) {
  case sorted {
    [first, ..] ->
      case first.last_read_at {
        Some(_) -> Some(first)
        None -> None
      }
    [] -> None
  }
}

/// Books shown in the grid. The hero book is filtered out of the
/// grid so the same card never appears twice; when there is no
/// hero, every book lands on the grid.
fn grid_candidates(
  sorted: List(BookMeta),
  hero: Option(BookMeta),
) -> List(BookMeta) {
  case hero {
    None -> sorted
    Some(hero_book) -> list.filter(sorted, fn(book) { book.id != hero_book.id })
  }
}

fn view_library_error(message: String) -> Element(Msg) {
  html.div(
    [attribute.class("lib-error"), attribute.attribute("role", "alert")],
    [html.text(message)],
  )
}

fn view_library_loading() -> Element(Msg) {
  html.div([attribute.class("lib-loading")], [
    html.text("Loading your library…"),
  ])
}

/// Empty state copy doubles as the only call-to-action the reader
/// gets on a fresh account — the FAB also opens the same sheet,
/// but the empty state plants the affordance front-and-centre so
/// a first-time user knows where to start.
fn view_library_empty() -> Element(Msg) {
  html.div([attribute.class("lib-empty")], [
    html.div([attribute.class("lib-empty-title")], [
      html.text("Your library is empty."),
    ]),
    html.div([attribute.class("lib-empty-subtitle")], [
      html.text("Tap the + button to add a book by pasting text."),
    ]),
  ])
}

/// The hero card is the most prominent affordance on the library
/// surface — the book the reader is most likely to want to remove
/// (just finished, abandoned, imported by mistake) is precisely the
/// one the × badge has to reach. The badge sits in a sibling layer
/// above the open-book button rather than inside it: nested
/// `<button>` is invalid HTML and would also collapse the click
/// targets in the accessibility tree.
fn view_hero_card(book: BookMeta, is_deleting: Bool) -> Element(Msg) {
  let color = cover_color_for_title(book.title)
  let author = option.unwrap(book.author, "")
  html.div([attribute.class("hero-card-wrapper")], [
    html.div([attribute.class("section-label")], [
      html.text("Continue Reading"),
    ]),
    html.button(
      [
        attribute.class("hero-card"),
        attribute.type_("button"),
        attribute.aria_label("Continue reading " <> book.title),
        event.on_click(OpenBook(book.id)),
      ],
      [
        html.div(
          [
            attribute.class("hero-cover"),
            attribute.style("background", color),
          ],
          [
            html.div(
              [
                attribute.class("hero-cover-gradient"),
                attribute.attribute("aria-hidden", "true"),
              ],
              [],
            ),
            html.div([attribute.class("hero-cover-text")], [
              html.div([attribute.class("hero-title")], [html.text(book.title)]),
              html.div([attribute.class("hero-author")], [html.text(author)]),
            ]),
          ],
        ),
        html.div([attribute.class("hero-meta")], [
          html.div([attribute.class("hero-meta-line")], [
            html.text(format_word_count(book.word_count) <> " words"),
          ]),
          html.div([attribute.class("hero-cta")], [
            html.text("Continue Reading"),
          ]),
        ]),
      ],
    ),
    view_delete_badge(book, is_deleting, ["btn-delete-hero"]),
  ])
}

/// Render the 2-column book grid. The wrapping container carries
/// the section label so the empty-grid case (a library with only
/// a hero book) collapses cleanly without leaving a dangling
/// header.
fn view_library_grid(
  books: List(BookMeta),
  is_deleting: fn(String) -> Bool,
) -> Element(Msg) {
  case books {
    [] -> element.none()
    _ ->
      html.div([attribute.class("lib-grid-section")], [
        html.div([attribute.class("section-label")], [
          html.text("Your Library"),
        ]),
        html.div(
          [attribute.class("book-grid")],
          list.map(books, fn(book) {
            view_book_card(book, is_deleting(book.id))
          }),
        ),
      ])
  }
}

fn view_book_card(book: BookMeta, is_deleting: Bool) -> Element(Msg) {
  let color = cover_color_for_title(book.title)
  let author = option.unwrap(book.author, "")
  html.div([attribute.class("book-card-wrapper")], [
    html.button(
      [
        attribute.class("book-card"),
        attribute.type_("button"),
        attribute.aria_label("Open " <> book.title),
        event.on_click(OpenBook(book.id)),
      ],
      [
        html.div(
          [attribute.class("book-cover"), attribute.style("background", color)],
          [
            html.div([attribute.class("book-cover-title")], [
              html.text(book.title),
            ]),
          ],
        ),
        html.div([attribute.class("book-info")], [
          html.div([attribute.class("book-title")], [html.text(book.title)]),
          html.div([attribute.class("book-author")], [html.text(author)]),
          html.div([attribute.class("book-meta")], [
            html.text(format_word_count(book.word_count) <> " words"),
          ]),
        ]),
      ],
    ),
    view_delete_badge(book, is_deleting, []),
  ])
}

/// Shared × badge used by both the hero card and each grid card.
/// `is_deleting` mirrors `model.deleting_book_ids` for this id —
/// while a DELETE is in flight, the button renders disabled (and
/// no `on_click` is attached) so a second tap cannot fire a duplicate
/// request that would race the first's response. `extra_classes`
/// lets the hero card opt into its larger badge variant without
/// duplicating the base styles.
fn view_delete_badge(
  book: BookMeta,
  is_deleting: Bool,
  extra_classes: List(String),
) -> Element(Msg) {
  let base_classes = ["btn-delete-book", ..extra_classes]
  let class_attr = case is_deleting {
    True -> attribute.class(string.join(["is-deleting", ..base_classes], " "))
    False -> attribute.class(string.join(base_classes, " "))
  }
  let common = [
    class_attr,
    attribute.type_("button"),
    attribute.aria_label("Delete " <> book.title),
  ]
  let attrs = case is_deleting {
    True -> [
      attribute.disabled(True),
      attribute.attribute("aria-disabled", "true"),
      ..common
    ]
    False -> [event.on_click(ConfirmDelete(book.id)), ..common]
  }
  html.button(attrs, [html.text("×")])
}

/// Format a word count with thousands separators. The prototype's
/// `(122189).toLocaleString()` is what we're mirroring here —
/// `gleam_stdlib` has no localised number formatter, so we
/// hand-roll the comma every three digits.
fn format_word_count(count: Int) -> String {
  count
  |> int.to_string
  |> insert_thousands_separators
}

fn insert_thousands_separators(digits: String) -> String {
  digits
  |> string.to_graphemes
  |> list.reverse
  |> chunk_every_three([])
  |> list.map(fn(chunk) {
    chunk
    |> list.reverse
    |> string.concat
  })
  |> list.reverse
  |> string.join(",")
}

fn chunk_every_three(
  digits: List(String),
  acc: List(List(String)),
) -> List(List(String)) {
  case digits {
    [] -> list.reverse(acc)
    _ -> {
      let #(chunk, rest) = take_split(digits, 3, [])
      chunk_every_three(rest, [chunk, ..acc])
    }
  }
}

fn take_split(
  source: List(String),
  remaining: Int,
  acc: List(String),
) -> #(List(String), List(String)) {
  case remaining, source {
    0, _ -> #(list.reverse(acc), source)
    _, [] -> #(list.reverse(acc), [])
    _, [head, ..tail] -> take_split(tail, remaining - 1, [head, ..acc])
  }
}

fn view_add_book_fab() -> Element(Msg) {
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
fn view_add_book_sheet(model: Model) -> Element(Msg) {
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
/// Duplicated in `client/view/settings.gleam` rather than imported
/// across sibling view modules so the view-layer dependency graph
/// stays a fan-in pattern (each view module is a leaf under
/// `client/view.gleam`).
fn stop_click_propagation() -> attribute.Attribute(Msg) {
  event.on("click", decode.failure(ToggleSettings, "stop-propagation"))
  |> event.stop_propagation
}
