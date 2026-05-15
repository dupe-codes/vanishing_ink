//// Book lifecycle helpers — the reducer-side counterparts to every
//// `Msg` arm that opens, creates, navigates between, or returns from
//// a book: `apply_open_book`, `apply_book_loaded`, `apply_text_load`,
//// `apply_go_to_library`, `apply_submit_paste`. Lifted out of
//// `client/reducer` so the main module stays under the 500-line soft
//// limit and so the "book state lifecycle" axis of change lives
//// behind one module boundary.

import gleam/dynamic.{type Dynamic}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
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
import client/reducer/session.{apply_end_session, apply_start_session}
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
  // Defensive end-of-session: a `GoToLibrary` between two book opens
  // would have ended the prior session already, but a future surface
  // that lets the reader switch directly between books (without
  // returning to the library) must not leave a session in flight
  // against the outgoing book. Routing through `apply_end_session`
  // here keeps the invariant intact regardless of how the dispatch
  // site composes navigation.
  let #(ended, end_effect) = apply_end_session(model)
  case ended.created_book_segments {
    Some(#(meta, segments)) ->
      case meta.id == id {
        True -> {
          let #(loaded, eff) = apply_book_loaded(ended, meta, segments)
          #(
            Model(..loaded, created_book_segments: None),
            effect.batch([end_effect, eff]),
          )
        }
        False -> #(
          Model(..ended, view: Reader, library_error: None),
          effect.batch([end_effect, fetch_book(id)]),
        )
      }
    None -> #(
      Model(..ended, view: Reader, library_error: None),
      effect.batch([end_effect, fetch_book(id)]),
    )
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
  // Stamp the active book id on the model *before* opening the
  // reading session — `apply_start_session` guards on
  // `active_book_id` being `Some(_)`, so opening with the field still
  // `None` would collapse the dispatch to a no-op.
  let with_book =
    Model(
      ..loaded,
      view: Reader,
      active_book_id: Some(meta.id),
      library_error: None,
      engine_state: Stopped,
      next_word_index: None,
      book_settings: None,
      // Clear the per-book stats cache up front so a stale value from
      // the previous book does not paint over the reader header during
      // the window before the new book's `fetch_book_stats` lands.
      book_stats: None,
      ghost_opacity: defaults.ghost_opacity,
      wpm: defaults.default_wpm,
      paragraph_delay_ms: defaults.default_paragraph_delay_ms,
      page_delay_ms: defaults.default_page_delay_ms,
    )
  let #(opened, session_effect) = apply_start_session(with_book)
  #(
    opened,
    effect.batch([
      session_effect,
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
/// boxes, active-line index, Jump Ahead menu state and preview
/// snapshot, forward-chapter cache), and the cached totals +
/// chapter title. Callers layer on view / library bookkeeping on
/// top of the returned `Model`.
///
/// The Jump Ahead fields (`jump_menu_open`, `jump_preview`,
/// `chapter_entries`) reset here so a mid-preview navigation away
/// from one book cannot leave a `JumpPreview` whose `source_page`
/// points at the prior book's index, nor leave an open menu
/// painting over the new book's bottom bar.
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
    jump_menu_open: False,
    jump_preview: None,
    chapter_entries: [],
    jump_page_input: "",
    jump_search_query: "",
    jump_search_results: [],
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
  //
  // Returning to the library mid-preview deliberately produces NO
  // save: `should_save_reading_state` blocks any save while
  // `jump_preview: Some(_)` so the previewed page is never persisted
  // as the reader's position. The server retains the pre-preview
  // page from the last committed save, which is the right outcome —
  // closing the reader without locking in is morally equivalent to
  // an implicit `UndoJump`.
  let save_effect = save_reading_state(model)
  // End the reading session BEFORE clearing `active_book_id` — same
  // reason as the save guard above. `apply_end_session` blocks when
  // there is no active book, so building the effect against the
  // post-clear model would silently drop the closing PUT.
  let #(ended, session_end_effect) = apply_end_session(model)
  let defaults = ended.global_defaults
  let cleared =
    Model(
      ..ended,
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
      // Tear down Jump Ahead state alongside the rest of the per-
      // book scratch surface — the menu is per-book and the preview
      // snapshot points at the outgoing book's page index.
      jump_menu_open: False,
      jump_preview: None,
      chapter_entries: [],
      jump_page_input: "",
      jump_search_query: "",
      jump_search_results: [],
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
      session_end_effect,
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
/// orphan the first result), and clears any prior `paste_error` /
/// `paste_warning` so the in-flight surface starts clean — the
/// reader is starting a new import attempt, so a stale banner from
/// the previous file would mislead.
///
/// Also resets the file input's `.value` via a side-effecting FFI
/// call so a subsequent pick of the same file path still fires a
/// `change` event — without the reset, the browser short-circuits
/// because the input's value did not change. The reset lives in an
/// effect rather than the event decoder so the decoder stays a pure
/// projection of the event payload (Lustre's expected contract for
/// decoders).
pub fn apply_epub_file_selected(
  model: Model,
  file: Dynamic,
) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..model,
      paste_submitting: True,
      paste_error: None,
      paste_warning: None,
    ),
    effect.batch([
      effect.from(fn(_dispatch) { epub.reset_picker_inputs() }),
      parse_epub(file),
    ]),
  )
}

/// Stamp the parsed ePub onto the paste form so the reader sees the
/// extracted title and segmenter-shaped body text pre-filled. The
/// success path is "load into the form, don't auto-submit" so the
/// reader can sanity-check the extraction (missing title, extra
/// front-matter) before sending the POST. Failures surface as a
/// human-readable `paste_error`.
///
/// A partial-success import (one or more spine sections failed to
/// parse) keeps the extracted text and surfaces a soft warning in
/// the separate `paste_warning` channel. The warning channel renders
/// with `role="status"` and a muted visual treatment so screen
/// readers do not announce a successful-but-partial import as an
/// error — the reader can still decide to retry with a different
/// file, but the affordance is informational rather than alarming.
pub fn apply_epub_parsed(
  model: Model,
  result: Result(EpubExtract, EpubError),
) -> #(Model, Effect(Msg)) {
  case result {
    Ok(EpubExtract(title, text, sections_skipped)) -> #(
      Model(
        ..model,
        paste_title: paste_title_after_import(model.paste_title, title),
        paste_text: text,
        paste_submitting: False,
        paste_error: None,
        paste_warning: describe_partial_import(sections_skipped),
      ),
      effect.none(),
    )
    Error(error) -> #(
      Model(
        ..model,
        paste_submitting: False,
        paste_error: Some(describe_epub_error(error)),
        // A parse failure replaces any prior partial-import warning
        // — the reader is now looking at a hard failure, not a
        // "we got most of the book" note.
        paste_warning: None,
      ),
      effect.none(),
    )
  }
}

/// Build the partial-import warning the reducer pins to `paste_error`
/// on a successful-but-incomplete ePub import. Zero skips → `None`
/// so the banner stays hidden (a clean import shows no message). Any
/// non-zero count surfaces a single-line warning naming the count so
/// the reader can decide to accept or retry.
fn describe_partial_import(sections_skipped: Int) -> Option(String) {
  case sections_skipped {
    0 -> None
    1 ->
      Some(
        "Imported, but 1 section of this ePub could not be parsed and was skipped.",
      )
    count ->
      Some(
        "Imported, but "
        <> int.to_string(count)
        <> " sections of this ePub could not be parsed and were skipped.",
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
      // Submitting clears the warning too — the reader has accepted
      // the partial-import body and is now sending it; keeping the
      // banner around alongside the "Adding…" button label would
      // double up the message.
      Model(
        ..model,
        paste_submitting: True,
        paste_error: None,
        paste_warning: None,
      ),
      create_book(title, text),
    )
  }
}
