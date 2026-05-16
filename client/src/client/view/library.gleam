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

import gleam/dict.{type Dict}
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

import client/msg.{
  type Msg, CancelDelete, ConfirmDelete, ExecuteDelete, OpenBook, ToggleSettings,
  ToggleStatsView,
}
import client/state.{type Model, cover_color_for_title}
import client/types.{type BookMeta}
import client/view/library/add_book
import client/view/stats as stats_view
import shared/stats.{type BookStats}

/// Render the library view: app bar + scrollable body (hero card,
/// grid or empty state, error banner) + FAB + add-book sheet.
pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("view-library")], [
    view_library_appbar(),
    html.div([attribute.class("lib-scroll")], [view_library_body(model)]),
    add_book.view_add_book_fab(),
    add_book.view_add_book_sheet(model),
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
      html.div([attribute.class("lib-appbar-actions")], [
        // Reading-stats overlay sits next to the gear: the two surfaces
        // are conceptually adjacent (both are reader-wide, both ride
        // off the same affordance pattern) so co-locating them keeps
        // the appbar a single "scope: reader-wide" cluster.
        html.button(
          [
            attribute.class("btn-icon"),
            attribute.aria_label("Open reading stats"),
            attribute.type_("button"),
            event.on_click(ToggleStatsView),
          ],
          [html.text("📊")],
        ),
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
    Some(book) ->
      view_hero_card(book, is_deleting(book.id), model.library_book_stats)
  }

  let body_main = case model.books_loading, model.books {
    True, _ -> view_library_loading()
    False, [] -> view_library_empty()
    False, _ ->
      view_library_grid(grid_books, is_deleting, model.library_book_stats)
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
fn view_hero_card(
  book: BookMeta,
  is_deleting: Bool,
  library_book_stats: Dict(String, BookStats),
) -> Element(Msg) {
  let color = cover_color_for_title(book.title)
  let author = option.unwrap(book.author, "")
  let stats_summary = book_stats_summary(library_book_stats, book)
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
          stats_summary,
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
  library_book_stats: Dict(String, BookStats),
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
            view_book_card(book, is_deleting(book.id), library_book_stats)
          }),
        ),
      ])
  }
}

fn view_book_card(
  book: BookMeta,
  is_deleting: Bool,
  library_book_stats: Dict(String, BookStats),
) -> Element(Msg) {
  let color = cover_color_for_title(book.title)
  let author = option.unwrap(book.author, "")
  let stats_summary = book_stats_summary(library_book_stats, book)
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
          stats_summary,
        ]),
      ],
    ),
    view_delete_badge(book, is_deleting, []),
  ])
}

/// Render the per-book stats summary line that sits below the title
/// on both the hero card and each grid card. Renders nothing when the
/// book has no sessions yet — the absence of stats is honest, and a
/// `0% • 0s` line would clutter a freshly-imported book's card.
///
/// Progress is reported as a percentage of `words_read + words_skipped`
/// against the book's `word_count`; the time component uses the same
/// formatter as the library-wide stats overlay so the two surfaces
/// speak in one vocabulary.
fn book_stats_summary(
  library_book_stats: Dict(String, BookStats),
  book: BookMeta,
) -> Element(Msg) {
  case dict.get(library_book_stats, book.id) {
    Error(_) -> element.none()
    Ok(stats) ->
      case stats.session_count {
        0 -> element.none()
        _ -> {
          let pct = progress_percentage(stats, book.word_count)
          let time = stats_view.format_duration(stats.total_duration_seconds)
          html.div([attribute.class("book-stats-line")], [
            html.text(int.to_string(pct) <> "% • " <> time),
          ])
        }
      }
  }
}

/// Coarse progress percentage. Clamped into `[0, 100]` so a Lock-In
/// session whose `words_read + words_skipped` exceeds the book's
/// `word_count` (e.g., the same word counted across multiple
/// sessions for a re-read) cannot push the bar past 100%.
fn progress_percentage(stats: BookStats, total_word_count: Int) -> Int {
  case total_word_count {
    0 -> 0
    _ -> {
      let covered = stats.total_words_read + stats.total_words_skipped
      let raw = covered * 100 / total_word_count
      case raw {
        n if n < 0 -> 0
        n if n > 100 -> 100
        n -> n
      }
    }
  }
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

/// Attach a click listener that stops propagation but never dispatches
/// a message. Used by the delete-confirm overlay to keep taps inside
/// the sheet from bubbling up to the scrim's close handler.
///
/// Duplicated in `client/view/settings.gleam` and
/// `client/view/library/add_book.gleam` rather than imported across
/// sibling view modules so the view-layer dependency graph stays a
/// fan-in pattern (each view module is a leaf under
/// `client/view.gleam`).
fn stop_click_propagation() -> attribute.Attribute(Msg) {
  event.on("click", decode.failure(ToggleSettings, "stop-propagation"))
  |> event.stop_propagation
}
