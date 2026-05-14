//// Book lifecycle helpers — the reducer-side counterparts to every
//// `Msg` arm that opens, creates, navigates between, or returns from
//// a book: `apply_open_book`, `apply_book_loaded`, `apply_text_load`,
//// `apply_go_to_library`, `apply_submit_paste`. Lifted out of
//// `client/reducer` so the main module stays under the 500-line soft
//// limit and so the "book state lifecycle" axis of change lives
//// behind one module boundary.

import gleam/dynamic.{type Dynamic}
import gleam/float
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import lustre/effect.{type Effect}

import client/effects.{
  create_book, fetch_book, fetch_book_settings, fetch_reading_state,
  measure_after_paint, parse_epub, save_reading_state,
}
import client/epub.{
  type EpubError, type EpubExtract, DrmEncrypted, EmptyText, EpubExtract,
  ParseFailed, UnsupportedFormat,
}
import client/ffi
import client/msg.{type Msg}
import client/pagination
import client/state.{
  type Model, Library, Model, Reader, Stopped, css_var_ghost_opacity,
}
import client/state/helpers.{total_counts}
import client/types.{type BookMeta}
import shared/segmenter.{type SegmentedText}

/// Open a book by id. The cache-hit path consumes the
/// `created_book_segments` slot stamped by `BookCreated(Ok(_))`,
/// applies the cached payload through the same `apply_book_loaded`
/// pipeline a server response would have, and clears the slot so a
/// second open of the same id falls through to a real fetch. The
/// cache-miss path is the original behaviour: flip to the reader and
/// chain `fetch_book(id)`. A non-matching cache (the user created
/// book A then tapped book B) is also a miss — the cache is keyed by
/// id, not just "is anything cached".
pub fn apply_open_book(model: Model, id: String) -> #(Model, Effect(Msg)) {
  case model.created_book_segments {
    Some(#(meta, segments)) ->
      case meta.id == id {
        True -> {
          let #(loaded, eff) = apply_book_loaded(model, meta, segments)
          #(Model(..loaded, created_book_segments: None), eff)
        }
        False -> #(
          Model(..model, view: Reader, library_error: None),
          fetch_book(id),
        )
      }
    None -> #(Model(..model, view: Reader, library_error: None), fetch_book(id))
  }
}

/// Stamp a freshly-fetched book onto the reader state. Delegates
/// every per-text field reset to `apply_text_load` and layers on the
/// library-bookkeeping fields the test-only `TextLoaded` entry point
/// has no opinion on: flip the view to `Reader`, record the active
/// book id, clear any stale `library_error`, and force the fade
/// engine back to its rest state so a previous book's
/// `Running`/`Paused` cursor cannot follow into the new book. The
/// follow-up `ParagraphsMeasured` from the `measure_after_paint`
/// effect is what fills `pages` in.
///
/// RACE — `BookSettingsLoaded` arrives asynchronously after the
/// `fetch_book_settings` effect below. This helper flips to the
/// reader on the same frame, so the reader can edit a slider in the
/// window between the helper running and the GET response landing. A
/// slider drag during that window routes through `persist_target` →
/// `PersistBook(id)` (view is `Reader`, `active_book_id` is
/// `Some(id)`), so the user's edit lands on `book_settings` and PUTs
/// to the server. The in-flight GET response then arrives and
/// `apply_book_settings_loaded` overwrites `book_settings` with the
/// pre-PUT server snapshot, clobbering the just-applied user edit
/// until the next slider drag re-PUTs it. The window is materially
/// wider than the parallel init-time race on `apply_settings_loaded`
/// because the reader is actively in the reader view and can
/// interact immediately. Closing this last-write-wins variant would
/// require a request-id (drop a stale `BookSettingsLoaded` response
/// if a PUT has fired since the GET was issued) or a "fetch sequence
/// number" gate; neither is wired up today.
///
/// The cousin race — late `BookSettingsLoaded` landing after the
/// reader has navigated to the library or opened a different book
/// — IS guarded against. The Msg carries the originating `book_id`,
/// and `apply_book_settings_loaded` drops the response when
/// `model.view != Reader` or `model.active_book_id != Some(book_id)`.
/// That covers the "open A → back → A's GET lands" path (the
/// previously documented "library now shows the prior book's
/// pacing" defect) and the "open A → back → open B → A's GET lands"
/// path (which would otherwise stamp A's overrides onto B's
/// session).
pub fn apply_book_loaded(
  model: Model,
  meta: BookMeta,
  text: SegmentedText,
) -> #(Model, Effect(Msg)) {
  let loaded = apply_text_load(model, text)
  // Reset the per-book overrides up front so a previous book's
  // overrides do not bleed into the new session before
  // `BookSettingsLoaded` lands. The effective pacing fields
  // simultaneously revert to the global defaults; the follow-up
  // fetch will re-merge any overrides the new book carries.
  let defaults = loaded.global_defaults
  #(
    Model(
      ..loaded,
      view: Reader,
      active_book_id: Some(meta.id),
      library_error: None,
      engine_state: Stopped,
      next_word_index: None,
      book_settings: None,
      ghost_opacity: defaults.ghost_opacity,
      wpm: defaults.default_wpm,
      paragraph_delay_ms: defaults.default_paragraph_delay_ms,
      page_delay_ms: defaults.default_page_delay_ms,
    ),
    effect.batch([
      measure_after_paint(),
      // Symmetric with `apply_go_to_library`: the reset above moves
      // `ghost_opacity` back to the global default, and the CSS
      // custom property has to follow or the rendered opacity keeps
      // pointing at the prior book's value until
      // `apply_book_settings_loaded` lands (or never updates at all
      // if the new book has no override). Today the only entry path
      // here transits `apply_go_to_library` first, which has already
      // pushed the global value — but the helper must be
      // self-consistent so any future entry path (a deep-link, a
      // programmatic open) cannot flicker the prior book's opacity
      // onto the new one.
      effect.from(fn(_dispatch) {
        ffi.set_css_property(
          css_var_ghost_opacity,
          float.to_string(defaults.ghost_opacity),
        )
      }),
      fetch_book_settings(meta.id),
      // Kick the reading-state fetch alongside the settings fetch.
      // `apply_text_load` reset `erased` / `erased_words` /
      // `current_page` / `mode` to empty defaults; the in-flight GET
      // may arrive before or after `ParagraphsMeasured`. The
      // staleness guard inside `apply_reading_state_loaded` mirrors
      // the one on `apply_book_settings_loaded` (book_id round-trip
      // + view check) so a late response from a previous book never
      // stamps the wrong progress.
      fetch_reading_state(meta.id),
    ]),
  )
}

/// Per-text reset surface shared by `TextLoaded` and
/// `apply_book_loaded`. Every field cleared / refreshed here is part
/// of "the book the reader is currently reading" — the segmented
/// payload, the flat-paragraph cache that view + pagination read,
/// the paginated state (`pages` / `current_page`), every per-book
/// scratch field (`erased` sentence bitset, `erased_words` word
/// bitset, undo stack, touch origin, vim focus, measured line
/// boxes, active-line index), and the cached totals + chapter
/// title. Callers layer on view / library bookkeeping on top of the
/// returned `Model`.
pub fn apply_text_load(model: Model, text: SegmentedText) -> Model {
  let #(sentences, words) = total_counts(text)
  Model(
    ..model,
    text: Some(text),
    flat_paragraphs: pagination.flatten(text),
    pages: [],
    current_page: 0,
    erased: set.new(),
    erased_words: set.new(),
    undo_stack: [],
    touch_start: None,
    focused_sentence: None,
    line_boxes: [],
    active_line: None,
    total_sentence_count: sentences,
    total_word_count: words,
    current_chapter_title: "",
    total_pages: 0,
  )
}

/// Tear down the reader and return to the library. Stops any
/// in-flight fade engine (clear the FFI timer, drop the engine to
/// `Stopped`) and resets every per-book scratch field so reopening
/// the same — or a different — book starts from a clean slate.
/// `mode` is preserved because it is a user preference, not a
/// per-book setting; `books` / `books_loading` are untouched so
/// the library renders immediately on the swap.
pub fn apply_go_to_library(model: Model) -> #(Model, Effect(Msg)) {
  // Capture the save effect BEFORE clearing `active_book_id` — the
  // save guard short-circuits on `None`, so building the effect after
  // the clear would silently drop the final reading-state PUT. This is
  // the final save for the session; subsequent state mutations happen
  // in the library and have no `book_id` to attach to.
  let save_effect = save_reading_state(model)
  let defaults = model.global_defaults
  let cleared =
    Model(
      ..model,
      view: Library,
      text: None,
      flat_paragraphs: [],
      pages: [],
      current_page: 0,
      erased: set.new(),
      erased_words: set.new(),
      undo_stack: [],
      touch_start: None,
      focused_sentence: None,
      line_boxes: [],
      active_line: None,
      total_sentence_count: 0,
      total_word_count: 0,
      current_chapter_title: "",
      active_book_id: None,
      engine_state: Stopped,
      next_word_index: None,
      settings_open: False,
      // Returning to the library re-pins the four overridable fields
      // to the global defaults so the settings panel — which can be
      // opened from the library appbar — shows the user-wide
      // preferences rather than the previous book's effective values.
      book_settings: None,
      ghost_opacity: defaults.ghost_opacity,
      wpm: defaults.default_wpm,
      paragraph_delay_ms: defaults.default_paragraph_delay_ms,
      page_delay_ms: defaults.default_page_delay_ms,
    )
  #(
    cleared,
    effect.batch([
      save_effect,
      effect.from(fn(_dispatch) { ffi.clear_word_timer() }),
      // Push the restored `ghost_opacity` into the CSS cascade so the
      // settings panel slider and any visible ghosted prose pick up
      // the global value rather than the last per-book override.
      effect.from(fn(_dispatch) {
        ffi.set_css_property(
          css_var_ghost_opacity,
          float.to_string(defaults.ghost_opacity),
        )
      }),
    ]),
  )
}

/// Dispatch the ePub parse effect for a freshly-picked file. Marks
/// `paste_submitting: True` so the file picker disables itself while
/// the parse is in flight (a second pick during the parse would
/// orphan the first result), and clears any prior `paste_error` so
/// the in-flight surface starts clean.
pub fn apply_epub_file_selected(
  model: Model,
  file: Dynamic,
) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, paste_submitting: True, paste_error: None),
    parse_epub(file),
  )
}

/// Stamp the parsed ePub onto the paste form so the reader sees the
/// extracted title and segmenter-shaped body text pre-filled. The
/// success path is "load into the form, don't auto-submit" so the
/// reader can sanity-check the extraction (missing title, extra
/// front-matter) before sending the POST. Failures surface as a
/// human-readable `paste_error`.
pub fn apply_epub_parsed(
  model: Model,
  result: Result(EpubExtract, EpubError),
) -> #(Model, Effect(Msg)) {
  case result {
    Ok(EpubExtract(title, _author, text)) -> #(
      Model(
        ..model,
        paste_title: paste_title_after_import(model.paste_title, title),
        paste_text: text,
        paste_submitting: False,
        paste_error: None,
      ),
      effect.none(),
    )
    Error(error) -> #(
      Model(
        ..model,
        paste_submitting: False,
        paste_error: Some(describe_epub_error(error)),
      ),
      effect.none(),
    )
  }
}

/// Decide which title to leave on the form after a successful ePub
/// import. A non-empty existing title wins (the reader typed
/// something before picking the file — clobbering it would discard
/// their intent), otherwise the extracted title fills the slot.
fn paste_title_after_import(existing: String, extracted: String) -> String {
  case string.trim(existing) {
    "" -> extracted
    _ -> existing
  }
}

/// Project an `EpubError` to a user-facing sentence for the
/// add-book sheet's error banner. The mapping is intentionally
/// terse — the sheet has limited vertical room and a long technical
/// detail string would push the submit button off-screen.
pub fn describe_epub_error(error: EpubError) -> String {
  case error {
    UnsupportedFormat -> "This file does not look like a valid ePub."
    DrmEncrypted -> "This ePub is DRM-protected and cannot be imported."
    EmptyText -> "No readable text was found in this ePub."
    ParseFailed(detail) ->
      case string.trim(detail) {
        "" -> "Could not parse this ePub."
        trimmed -> "Could not parse this ePub: " <> trimmed
      }
  }
}

/// Validate the paste form and fire `create_book`. Empty title or
/// empty body short-circuits with a `paste_error`; the server's
/// own validation would catch the same case, but checking client-
/// side saves a round trip and surfaces the message instantly.
pub fn apply_submit_paste(model: Model) -> #(Model, Effect(Msg)) {
  let title = string.trim(model.paste_title)
  let text = string.trim(model.paste_text)
  case title, text {
    "", _ -> #(
      Model(..model, paste_error: Some("Please add a title.")),
      effect.none(),
    )
    _, "" -> #(
      Model(..model, paste_error: Some("Please paste some text.")),
      effect.none(),
    )
    _, _ -> #(
      Model(..model, paste_submitting: True, paste_error: None),
      create_book(title, text),
    )
  }
}
