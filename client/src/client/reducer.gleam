//// Reducer: the main `update` dispatcher plus every `apply_*` helper
//// that is not part of the fade engine. The reducer pattern-matches
//// the `Msg` ADT exhaustively and produces an updated `Model` plus an
//// `Effect(Msg)` for any side-effects (FFI calls, fetch requests,
//// timer scheduling, post-paint measurement).
////
//// **Touch gesture pipeline** (`TouchStart` → `TouchEnd` → classify → route):
////
//// 1. `TouchStart` stores the touch origin on `model.touch_start`.
//// 2. `TouchEnd` reads that origin back, calls `gestures.classify/4`,
////    and routes the result:
////    - `Tap` — no-op; sentence erasure flows through the synthesised
////      `click` event on the `.sentence` span.
////    - `SwipeLeft` — `NextPage`.
////    - `SwipeRight` — `Undo` the most recent erase. A no-op when
////      the undo stack is empty (no backward page navigation).
//// 3. `TouchCancel` clears `touch_start` without routing anything,
////    preventing the stale start coordinates from corrupting the next
////    `touchend` classification.

import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import lustre/effect.{type Effect}

import client/effects.{
  create_book, decode_base64_to_indices, delete_book_effect, describe_fetch_error,
  fetch_book, fetch_book_settings, fetch_reading_state, measure_after_paint,
  measure_lines_after_paint, repaginate_after_paint, save_book_settings,
  save_global_settings, save_reading_state,
}
import client/engine.{
  apply_advance_word, apply_pause_fade, apply_resume_fade, apply_start_fade,
  resolve_active_line,
}
import client/ffi
import client/gestures
import client/msg.{
  type Msg, AdvanceWord, BookCreated, BookDeleted, BookLoaded,
  BookSettingsLoaded, BooksLoaded, CancelDelete, ConfirmDelete, EraseFocused,
  EraseSentence, ExecuteDelete, FocusNext, FocusParagraphDown, FocusParagraphUp,
  FocusPrevious, GoToLibrary, LinesMeasured, NextPage, OpenBook,
  ParagraphsMeasured, PauseFade, ReadingStateLoaded, ResetBookSettings,
  ResumeFade, SetFontSize, SetGhostOpacity, SetLineSpacing, SetMode,
  SetPageDelay, SetParagraphDelay, SetPasteText, SetPasteTitle, SetWpm,
  SettingsLoaded, SpacePressed, StartFade, SubmitPaste, TextLoaded,
  ToggleAddBook, ToggleDarkMode, ToggleDyslexiaFont, ToggleGhostMode,
  ToggleSettings, TouchCancel, TouchEnd, TouchStart, Undo, ViewportResized,
}
import client/navigation
import client/pagination
import client/state.{
  type Model, type Mode, Library, Manual, Model, Paused, Reader, RealTime,
  Running, Stopped, body_class_dyslexia_font, body_class_ghost_mode,
  body_class_light_mode, change_page, clamp_float, clamp_int,
  compute_current_chapter_title, css_var_font_size, css_var_ghost_opacity,
  css_var_line_height, empty_book_settings, go_to_page, max_font_size,
  max_ghost_opacity, max_line_spacing, max_page_delay_ms,
  max_paragraph_delay_ms, max_wpm, min_font_size, min_ghost_opacity,
  min_line_spacing, min_page_delay_ms, min_paragraph_delay_ms, min_wpm,
  total_counts, undo_stack_depth,
}
import client/types.{
  type BookMeta, type BookSettings, type ReadingState, type UserSettings,
  BookSettings, UserSettings,
}
import shared/segmenter.{type SegmentedText}

/// Transition the reader to the next state given a message.
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    TextLoaded(text) ->
      // `pages` is reset to `[]` by `apply_text_load`, so the cached
      // chapter title and `total_pages` are empty/zero until
      // `ParagraphsMeasured` lands the first page list. Resetting
      // them explicitly (rather than leaving the prior values in
      // place) avoids the cache lagging across a fresh book load —
      // the header would otherwise briefly carry the previous book's
      // title and page count.
      #(apply_text_load(model, text), measure_after_paint())

    ParagraphsMeasured(heights, available_height) -> {
      let pages = case model.text {
        None -> []
        Some(_) ->
          pagination.calculate_pages(
            model.flat_paragraphs,
            pagination.heights_from_pairs(heights),
            available_height,
          )
      }
      let total = list.length(pages)
      let clamped = pagination.clamp_page_index(model.current_page, total)
      // Re-anchor `focused_sentence` if pagination shifted it off the
      // visible page. Without this, a viewport change can leave the
      // vim cursor on a sentence whose `page_index` differs from
      // `clamped`; the next vim keypress would then call `change_page`
      // with that off-screen target, bypassing the forward-only guard
      // in `go_to_page` and dragging `current_page` backward — the
      // exact regression this PR exists to close. Re-anchoring to the
      // first non-erased sentence on `clamped` keeps the cursor on
      // the page the reader is actually looking at.
      let focused = case model.focused_sentence {
        None -> None
        Some(sentence_index) -> {
          let locations = navigation.locate_sentences(pages)
          let on_current_page =
            locations
            |> list.any(fn(loc) {
              loc.sentence_global_index == sentence_index
              && loc.page_index == clamped
            })
          case on_current_page {
            True -> Some(sentence_index)
            False ->
              navigation.first_on_page(locations, clamped, model.erased)
              |> option.map(fn(loc) { loc.sentence_global_index })
          }
        }
      }
      // Refresh the cached chapter title against the post-clamp
      // page list — the visible page's chapter may have shifted if
      // pagination repacked paragraphs or the clamp moved the
      // current page.
      let chapter_title =
        compute_current_chapter_title(model.text, pages, clamped)
      #(
        Model(
          ..model,
          pages: pages,
          current_page: clamped,
          focused_sentence: focused,
          // Re-pagination invalidates the cached line geometry: the
          // new `pages` may wrap differently and the previous
          // `line_boxes` no longer describe what the view is about
          // to render. Clear both fields synchronously in the same
          // model update that schedules the re-measure so the view
          // never paints the new page against stale overlay
          // coordinates — without this, the 250ms `top` transition
          // glides the overlay from the old position to the new one
          // once `LinesMeasured` lands, which reads as drift on a
          // settings-slider drag where each tick re-paginates.
          line_boxes: [],
          active_line: None,
          current_chapter_title: chapter_title,
          total_pages: total,
        ),
        // Pagination ran — chain a line measurement so the active-line
        // overlay re-anchors to the post-repagination geometry. The
        // chain is necessary because line tops depend on the rendered
        // page, which only exists after the view re-renders with the
        // new `pages` value; `effect.after_paint` waits for that paint
        // before reading `getBoundingClientRect()`.
        measure_lines_after_paint(),
      )
    }

    LinesMeasured(boxes) -> {
      let new_model = Model(..model, line_boxes: boxes)
      #(
        Model(..new_model, active_line: resolve_active_line(new_model)),
        effect.none(),
      )
    }

    NextPage -> {
      let updated = go_to_page(model, model.current_page + 1)
      case updated.current_page == model.current_page {
        // A no-op page turn (already on the last page) doesn't change
        // the rendered DOM, so re-measuring would only churn the
        // overlay position without effect. Skipping the measurement
        // here also keeps the no-page-change test pin in place.
        True -> #(updated, effect.none())
        // A real page turn invalidates the cached line geometry. Clear
        // `line_boxes` and `active_line` synchronously in the same
        // model update that schedules the re-measure — otherwise the
        // view paints the new page with the old overlay coordinates
        // and the 250ms `top` CSS transition glides the band into
        // place once `LinesMeasured` lands. The cleared state mirrors
        // the engine's own cross-page tick in `advance_to_next_page_loop`.
        False -> {
          let with_cleared_overlay =
            Model(..updated, line_boxes: [], active_line: None)
          #(
            with_cleared_overlay,
            effect.batch([
              measure_lines_after_paint(),
              save_reading_state(with_cleared_overlay),
            ]),
          )
        }
      }
    }

    ViewportResized -> #(model, measure_after_paint())

    EraseSentence(global_index) -> {
      let new_model = apply_erase(model, global_index)
      #(new_model, save_reading_state(new_model))
    }

    Undo -> {
      let new_model = apply_undo(model)
      #(new_model, save_reading_state(new_model))
    }

    FocusPrevious -> #(
      focus_sentence_step(model, navigation.Backward),
      effect.none(),
    )

    FocusNext -> #(
      focus_sentence_step(model, navigation.Forward),
      effect.none(),
    )

    FocusParagraphUp -> #(
      focus_paragraph_step(model, navigation.Backward),
      effect.none(),
    )

    FocusParagraphDown -> #(
      focus_paragraph_step(model, navigation.Forward),
      effect.none(),
    )

    EraseFocused -> {
      let new_model = apply_erase_focused(model)
      #(new_model, save_reading_state(new_model))
    }

    TouchStart(x, y) -> #(
      Model(..model, touch_start: Some(#(x, y))),
      effect.none(),
    )

    TouchCancel -> #(Model(..model, touch_start: None), effect.none())

    TouchEnd(x, y) -> apply_touch_end(model, x, y)

    ToggleSettings -> #(
      Model(..model, settings_open: !model.settings_open),
      effect.none(),
    )

    ToggleDarkMode -> apply_toggle_dark_mode(model)

    SetFontSize(size) -> apply_set_font_size(model, size)

    SetLineSpacing(spacing) -> apply_set_line_spacing(model, spacing)

    ToggleGhostMode -> apply_toggle_ghost_mode(model)

    SetGhostOpacity(opacity) -> apply_set_ghost_opacity(model, opacity)

    ToggleDyslexiaFont -> apply_toggle_dyslexia_font(model)

    SetMode(mode) -> apply_set_mode(model, mode)

    SpacePressed -> apply_space_pressed(model)

    StartFade -> apply_start_fade(model)

    PauseFade -> apply_pause_fade(model)

    ResumeFade -> apply_resume_fade(model)

    AdvanceWord -> apply_advance_word(model)

    SetWpm(value) -> apply_set_wpm(model, value)

    SetParagraphDelay(value) -> apply_set_paragraph_delay(model, value)

    SetPageDelay(value) -> apply_set_page_delay(model, value)

    BooksLoaded(Ok(books)) -> #(
      Model(..model, books: books, books_loading: False, library_error: None),
      effect.none(),
    )

    BooksLoaded(Error(error)) -> #(
      Model(
        ..model,
        books_loading: False,
        library_error: Some(describe_fetch_error(error)),
      ),
      effect.none(),
    )

    BookLoaded(Ok(#(meta, segments))) ->
      apply_book_loaded(model, meta, segments)

    BookLoaded(Error(error)) -> #(
      Model(
        ..model,
        view: Library,
        library_error: Some(describe_fetch_error(error)),
      ),
      effect.none(),
    )

    BookCreated(Ok(#(meta, segments))) -> #(
      Model(
        ..model,
        books: [meta, ..model.books],
        paste_title: "",
        paste_text: "",
        paste_submitting: False,
        paste_error: None,
        add_book_open: False,
        // Stash the segmented payload so an immediate `OpenBook(meta.id)`
        // can apply it directly instead of round-tripping through
        // `GET /api/books/:id`. The POST response already decoded the
        // same segments; dropping them on the floor would force a
        // second network call for data the client already has.
        created_book_segments: Some(#(meta, segments)),
      ),
      effect.none(),
    )

    BookCreated(Error(error)) -> #(
      Model(
        ..model,
        paste_submitting: False,
        paste_error: Some(describe_fetch_error(error)),
      ),
      effect.none(),
    )

    OpenBook(id) -> apply_open_book(model, id)

    GoToLibrary -> apply_go_to_library(model)

    ToggleAddBook -> {
      let opening = !model.add_book_open
      #(
        Model(
          ..model,
          add_book_open: opening,
          // Opening the sheet clears any prior error so the form
          // starts clean; closing it leaves whatever error was last
          // shown intact (the reader is dismissing the surface, not
          // acknowledging the message).
          paste_error: case opening {
            True -> None
            False -> model.paste_error
          },
        ),
        effect.none(),
      )
    }

    SetPasteTitle(value) -> #(
      Model(..model, paste_title: value, paste_error: None),
      effect.none(),
    )

    SetPasteText(value) -> #(
      Model(..model, paste_text: value, paste_error: None),
      effect.none(),
    )

    SubmitPaste -> apply_submit_paste(model)

    SettingsLoaded(Ok(body)) ->
      case json.parse(body, types.user_settings_decoder()) {
        Ok(settings) -> apply_settings_loaded(model, settings)
        Error(_) -> {
          io.println("Failed to decode /api/settings response")
          #(model, effect.none())
        }
      }

    SettingsLoaded(Error(error)) -> {
      io.println(
        "Failed to load global settings: " <> describe_fetch_error(error),
      )
      #(model, effect.none())
    }

    BookSettingsLoaded(book_id, Ok(body)) ->
      case json.parse(body, types.book_settings_decoder()) {
        Ok(settings) -> apply_book_settings_loaded(model, book_id, settings)
        Error(_) -> {
          io.println("Failed to decode /api/books/:id/settings response")
          #(model, effect.none())
        }
      }

    BookSettingsLoaded(_book_id, Error(error)) -> {
      io.println(
        "Failed to load book settings: " <> describe_fetch_error(error),
      )
      #(model, effect.none())
    }

    ReadingStateLoaded(book_id, Ok(body)) ->
      case json.parse(body, types.reading_state_decoder()) {
        Ok(state) -> apply_reading_state_loaded(model, book_id, state)
        Error(_) -> {
          io.println("Failed to decode /api/books/:id/state response")
          #(model, effect.none())
        }
      }

    ReadingStateLoaded(_book_id, Error(error)) -> {
      io.println(
        "Failed to load reading state: " <> describe_fetch_error(error),
      )
      #(model, effect.none())
    }

    ResetBookSettings -> apply_reset_book_settings(model)

    // A second tap on an already-in-flight card is a no-op: opening
    // the confirmation overlay again would let the reader fire a
    // second DELETE on an id that is about to be 404'd by the first
    // delete's success, surfacing a confusing FetchError on what was
    // actually a successful deletion.
    ConfirmDelete(id) ->
      case set.contains(model.deleting_book_ids, id) {
        True -> #(model, effect.none())
        False -> #(Model(..model, confirm_delete_id: Some(id)), effect.none())
      }

    CancelDelete -> #(Model(..model, confirm_delete_id: None), effect.none())

    // Mark the id as in-flight so the × badge for that card renders
    // disabled (see `view_book_card` / `view_hero_card`) and a
    // re-entrant `ConfirmDelete(id)` is short-circuited above. The
    // id is removed from the set in both `BookDeleted` arms so a
    // failed delete also unblocks subsequent retries.
    ExecuteDelete(id) -> #(
      Model(
        ..model,
        confirm_delete_id: None,
        deleting_book_ids: set.insert(model.deleting_book_ids, id),
      ),
      delete_book_effect(id),
    )

    BookDeleted(id, Ok(_)) -> {
      let books = list.filter(model.books, fn(b) { b.id != id })
      let deleting_book_ids = set.delete(model.deleting_book_ids, id)
      case model.active_book_id == Some(id) {
        True -> {
          let #(nav_model, nav_effect) = apply_go_to_library(model)
          #(
            Model(
              ..nav_model,
              books: books,
              library_error: None,
              deleting_book_ids: deleting_book_ids,
            ),
            nav_effect,
          )
        }
        False -> #(
          Model(
            ..model,
            books: books,
            library_error: None,
            deleting_book_ids: deleting_book_ids,
          ),
          effect.none(),
        )
      }
    }

    BookDeleted(id, Error(error)) -> #(
      Model(
        ..model,
        library_error: Some(describe_fetch_error(error)),
        deleting_book_ids: set.delete(model.deleting_book_ids, id),
      ),
      effect.none(),
    )
  }
}

// ---------------------------------------------------------------------------
// Library / book navigation helpers
// ---------------------------------------------------------------------------

/// Open a book by id. The cache-hit path consumes the
/// `created_book_segments` slot stamped by `BookCreated(Ok(_))`,
/// applies the cached payload through the same `apply_book_loaded`
/// pipeline a server response would have, and clears the slot so a
/// second open of the same id falls through to a real fetch. The
/// cache-miss path is the original behaviour: flip to the reader and
/// chain `fetch_book(id)`. A non-matching cache (the user created
/// book A then tapped book B) is also a miss — the cache is keyed by
/// id, not just "is anything cached".
fn apply_open_book(model: Model, id: String) -> #(Model, Effect(Msg)) {
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
fn apply_book_loaded(
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
fn apply_text_load(model: Model, text: SegmentedText) -> Model {
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
fn apply_go_to_library(model: Model) -> #(Model, Effect(Msg)) {
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

/// Validate the paste form and fire `create_book`. Empty title or
/// empty body short-circuits with a `paste_error`; the server's
/// own validation would catch the same case, but checking client-
/// side saves a round trip and surfaces the message instantly.
fn apply_submit_paste(model: Model) -> #(Model, Effect(Msg)) {
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

// ---------------------------------------------------------------------------
// Settings-loaded reducers
// ---------------------------------------------------------------------------

/// Apply the persisted global preferences to the running model. Each
/// of the eight fields is mirrored onto the effective field on the
/// model and pushed into the CSS cascade through the same FFI calls
/// the individual setters use, so the rendered theme matches the
/// loaded record on the same frame. `global_defaults` is also stamped
/// so a later per-book merge has the latest baseline.
///
/// RACE — the GET that produces this dispatch fires from `init`; if
/// the reader toggles a global setting (`ToggleDarkMode`,
/// `SetFontSize`, `SetLineSpacing`, `ToggleGhostMode`) in the
/// ~100–500 ms window before the response lands, the PUT it triggers
/// races the in-flight GET. If the GET response arrives second, this
/// helper stamps `dark_mode`, `font_size`, `line_spacing`,
/// `ghost_mode` from the pre-edit server snapshot — the PUT succeeded
/// server-side, but the in-memory model briefly reverts and the user
/// watches their toggle un-toggle until the next save round-trip
/// lands. The four overridable fields below are already re-merged
/// through `book_settings`, so they survive the race; the four
/// non-overridable globals have no such guard. Closing the race
/// requires a request-id or "seen-once" flag on `SettingsLoaded`;
/// neither is wired up today.
fn apply_settings_loaded(
  model: Model,
  settings: UserSettings,
) -> #(Model, Effect(Msg)) {
  let new_model =
    Model(
      ..model,
      global_defaults: settings,
      font_size: settings.font_size,
      line_spacing: settings.line_spacing,
      dark_mode: settings.dark_mode,
      ghost_mode: settings.ghost_mode,
      // The per-book overrides — if any — already won the merge in
      // `apply_book_settings_loaded`; when loading the globals on top
      // of an already-merged reader state we must not regress those
      // overrides. The four fields below therefore re-merge against
      // any active `book_settings` rather than blindly taking the new
      // global value.
      ghost_opacity: effective_ghost_opacity(model.book_settings, settings),
      wpm: effective_wpm(model.book_settings, settings),
      paragraph_delay_ms: effective_paragraph_delay(
        model.book_settings,
        settings,
      ),
      page_delay_ms: effective_page_delay(model.book_settings, settings),
    )
  let css_effects =
    effect.from(fn(_dispatch) {
      ffi.set_css_property(
        css_var_font_size,
        int.to_string(new_model.font_size) <> "px",
      )
      ffi.set_css_property(
        css_var_line_height,
        float.to_string(new_model.line_spacing),
      )
      ffi.set_css_property(
        css_var_ghost_opacity,
        float.to_string(new_model.ghost_opacity),
      )
      ffi.set_body_class(body_class_light_mode, !new_model.dark_mode)
      ffi.set_body_class(body_class_ghost_mode, new_model.ghost_mode)
    })
  // Font size and line spacing changes alter paragraph wrap heights,
  // so kick the measurement loop. `repaginate_after_paint` is a no-op
  // when no text is loaded yet (the resulting `ViewportResized`
  // dispatch fires the measurement effect, which is harmless before
  // the reader has paginated anything).
  #(new_model, effect.batch([css_effects, repaginate_after_paint()]))
}

/// Merge per-book overrides with the current `global_defaults` and
/// apply the four resulting effective values to the model. The
/// `BookSettings` record is also stored so a later edit of one
/// override (or a `ResetBookSettings`) has the prior overrides to
/// diff against.
///
/// `book_id` is the id the originating `fetch_book_settings` call was
/// issued for. The guard at the top drops the response when:
///
///   * the reader has navigated back to the library
///     (`model.view != Reader` / `model.active_book_id == None`), or
///   * the active book has changed under the in-flight request
///     (open A → back → open B → A's GET lands).
///
/// Without the guard, a late response would either re-populate
/// `book_settings: Some(_)` while `view == Library` (an internally
/// inconsistent state — `book_settings.is_some()` should imply
/// `active_book_id.is_some()`) or stamp the previous book's overrides
/// onto the new active book's effective fields. Both are reachable
/// through ordinary navigation within the GET's ~100-300 ms window.
fn apply_book_settings_loaded(
  model: Model,
  book_id: String,
  settings: BookSettings,
) -> #(Model, Effect(Msg)) {
  case model.view, model.active_book_id {
    Reader, Some(active_id) if active_id == book_id -> {
      let new_model =
        Model(
          ..model,
          book_settings: Some(settings),
          ghost_opacity: effective_ghost_opacity(
            Some(settings),
            model.global_defaults,
          ),
          wpm: effective_wpm(Some(settings), model.global_defaults),
          paragraph_delay_ms: effective_paragraph_delay(
            Some(settings),
            model.global_defaults,
          ),
          page_delay_ms: effective_page_delay(
            Some(settings),
            model.global_defaults,
          ),
        )
      let css_effects =
        effect.from(fn(_dispatch) {
          ffi.set_css_property(
            css_var_ghost_opacity,
            float.to_string(new_model.ghost_opacity),
          )
        })
      #(new_model, css_effects)
    }
    _, _ -> #(model, effect.none())
  }
}

/// Apply a freshly-loaded `ReadingState` to the running model.
/// Guarded against stale responses the same way
/// `apply_book_settings_loaded` is: the originating `book_id` must
/// match `model.active_book_id` and the view must still be `Reader`,
/// otherwise the response is dropped.
///
/// Decoded fields are applied as follows:
///   * `sentence_bitset` / `word_bitset` — base64 → `Set(Int)`, stamped
///     onto `model.erased` / `model.erased_words` directly.
///   * `current_page` — written raw. The clamp against `total_pages`
///     happens inside `ParagraphsMeasured`; if that has already run
///     for this book, we clamp here too so a saved value past the
///     current page count doesn't park the reader off-screen.
///   * `mode` — the closed vocabulary on the wire is `"manual"` /
///     `"ghost"`. Unknown values fall back to `Manual` so a future
///     server vocabulary expansion can't strand the client on an
///     undecodable mode.
///
/// The fade engine is kept at rest (`Stopped`, `next_word_index: None`)
/// regardless of the loaded mode — the reader has to press
/// Space/tap to start the engine, matching the
/// `apply_book_loaded`-initial state. Restoring the engine to
/// `Running` on load would surprise a reader who tabbed away from a
/// running engine.
fn apply_reading_state_loaded(
  model: Model,
  book_id: String,
  state: ReadingState,
) -> #(Model, Effect(Msg)) {
  case model.view, model.active_book_id {
    Reader, Some(active_id) if active_id == book_id -> {
      let mode = case state.mode {
        "ghost" -> RealTime
        _ -> Manual
      }
      let target_page = case model.total_pages > 0 {
        True ->
          pagination.clamp_page_index(state.current_page, model.total_pages)
        False -> state.current_page
      }
      #(
        Model(
          ..model,
          mode: mode,
          erased: decode_base64_to_indices(state.sentence_bitset),
          erased_words: decode_base64_to_indices(state.word_bitset),
          current_page: target_page,
        ),
        effect.none(),
      )
    }
    _, _ -> #(model, effect.none())
  }
}

/// Clear every per-book override for the current book. Writes an
/// all-null record to the server (which deletes the override row's
/// values), restores the four effective fields to the global
/// defaults, and updates `model.book_settings` to match. A no-op
/// when no book is loaded — the reader cannot dispatch this Msg
/// from the library view in practice (the UI only renders the
/// Reset button when reading), but the guard keeps the helper
/// total.
fn apply_reset_book_settings(model: Model) -> #(Model, Effect(Msg)) {
  case model.active_book_id {
    None -> #(model, effect.none())
    Some(id) -> {
      let cleared = empty_book_settings()
      let defaults = model.global_defaults
      let new_model =
        Model(
          ..model,
          book_settings: Some(cleared),
          ghost_opacity: defaults.ghost_opacity,
          wpm: defaults.default_wpm,
          paragraph_delay_ms: defaults.default_paragraph_delay_ms,
          page_delay_ms: defaults.default_page_delay_ms,
        )
      let css_effects =
        effect.from(fn(_dispatch) {
          ffi.set_css_property(
            css_var_ghost_opacity,
            float.to_string(new_model.ghost_opacity),
          )
        })
      #(new_model, effect.batch([css_effects, save_book_settings(id, cleared)]))
    }
  }
}

// ---------------------------------------------------------------------------
// Effective-value merging
// ---------------------------------------------------------------------------

/// Where to persist a change to one of the four overridable fields
/// (`ghost_opacity`, `wpm`, `paragraph_delay_ms`, `page_delay_ms`).
///
/// `PersistBook(id)` — the reader is on the reader view with an active
/// book id, so the change should be stored as a per-book override and
/// PUT to `/api/books/:id/settings`.
///
/// `PersistGlobal` — the reader is on the library view (no book
/// loaded, no per-book scope to attach the change to), so the change
/// is stored as a global default and PUT to `/api/settings`. This is
/// the path the library-appbar gear button feeds, and a future
/// route-state design that lets the reader edit globals while a book
/// is open can flow through the same arm.
type PersistTarget {
  PersistBook(id: String)
  PersistGlobal
}

/// Decide whether the next overridable-field change should land on
/// the active book or on the global defaults. The reader view with an
/// active book id is the only path that produces a per-book write —
/// every other configuration (library view, library view with stale
/// `active_book_id` from a half-cancelled load) falls through to the
/// global path so a slider drag in the library never silently writes
/// to a hidden book row.
fn persist_target(model: Model) -> PersistTarget {
  case model.view, model.active_book_id {
    Reader, Some(id) -> PersistBook(id)
    _, _ -> PersistGlobal
  }
}

fn effective_wpm(
  overrides: option.Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(wpm: Some(v), ..)) -> v
    _ -> defaults.default_wpm
  }
}

fn effective_paragraph_delay(
  overrides: option.Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(paragraph_delay_ms: Some(v), ..)) -> v
    _ -> defaults.default_paragraph_delay_ms
  }
}

fn effective_page_delay(
  overrides: option.Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(page_delay_ms: Some(v), ..)) -> v
    _ -> defaults.default_page_delay_ms
  }
}

fn effective_ghost_opacity(
  overrides: option.Option(BookSettings),
  defaults: UserSettings,
) -> Float {
  case overrides {
    Some(BookSettings(ghost_opacity: Some(v), ..)) -> v
    _ -> defaults.ghost_opacity
  }
}

// ---------------------------------------------------------------------------
// Settings setters
// ---------------------------------------------------------------------------

fn apply_toggle_dark_mode(model: Model) -> #(Model, Effect(Msg)) {
  let new_dark = !model.dark_mode
  let new_defaults = UserSettings(..model.global_defaults, dark_mode: new_dark)
  #(
    Model(..model, dark_mode: new_dark, global_defaults: new_defaults),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_body_class(body_class_light_mode, !new_dark)
      }),
      save_global_settings(new_defaults),
    ]),
  )
}

fn apply_set_font_size(model: Model, size: Int) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(size, min_font_size, max_font_size)
  let new_defaults = UserSettings(..model.global_defaults, font_size: clamped)
  #(
    Model(..model, font_size: clamped, global_defaults: new_defaults),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_css_property(css_var_font_size, int.to_string(clamped) <> "px")
      }),
      // Paragraph wrap heights depend on font size — kick the measurement
      // loop so pagination recalculates at the new metrics.
      // `ViewportResized` is the existing entry point; dispatching it
      // keeps the resize path and the settings-change path identical from
      // `measure_after_paint` onward.
      repaginate_after_paint(),
      save_global_settings(new_defaults),
    ]),
  )
}

fn apply_set_line_spacing(
  model: Model,
  spacing: Float,
) -> #(Model, Effect(Msg)) {
  let clamped = clamp_float(spacing, min_line_spacing, max_line_spacing)
  let new_defaults =
    UserSettings(..model.global_defaults, line_spacing: clamped)
  #(
    Model(..model, line_spacing: clamped, global_defaults: new_defaults),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_css_property(css_var_line_height, float.to_string(clamped))
      }),
      repaginate_after_paint(),
      save_global_settings(new_defaults),
    ]),
  )
}

fn apply_toggle_ghost_mode(model: Model) -> #(Model, Effect(Msg)) {
  let new_ghost = !model.ghost_mode
  let new_defaults =
    UserSettings(..model.global_defaults, ghost_mode: new_ghost)
  #(
    Model(..model, ghost_mode: new_ghost, global_defaults: new_defaults),
    effect.batch([
      // Only the body class is toggled here. The `--vi-ghost-opacity`
      // custom property is owned by `apply_set_ghost_opacity`, which
      // writes it on every change to `model.ghost_opacity`; pushing it
      // again from this arm would be a dead write — the variable is
      // already up to date when ghost mode flips on or off.
      effect.from(fn(_dispatch) {
        ffi.set_body_class(body_class_ghost_mode, new_ghost)
      }),
      save_global_settings(new_defaults),
    ]),
  )
}

fn apply_set_ghost_opacity(
  model: Model,
  opacity: Float,
) -> #(Model, Effect(Msg)) {
  let clamped = clamp_float(opacity, min_ghost_opacity, max_ghost_opacity)
  let css_effect =
    effect.from(fn(_dispatch) {
      ffi.set_css_property(css_var_ghost_opacity, float.to_string(clamped))
    })
  let updated = Model(..model, ghost_opacity: clamped)
  case persist_target(updated) {
    PersistGlobal -> {
      let new_defaults =
        UserSettings(..updated.global_defaults, ghost_opacity: clamped)
      #(
        Model(..updated, global_defaults: new_defaults),
        effect.batch([css_effect, save_global_settings(new_defaults)]),
      )
    }
    PersistBook(id) -> {
      let overrides = case updated.book_settings {
        None -> empty_book_settings()
        Some(s) -> s
      }
      let new_overrides =
        BookSettings(..overrides, ghost_opacity: Some(clamped))
      #(
        Model(..updated, book_settings: Some(new_overrides)),
        effect.batch([css_effect, save_book_settings(id, new_overrides)]),
      )
    }
  }
}

fn apply_set_wpm(model: Model, value: Int) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(value, min_wpm, max_wpm)
  let updated = Model(..model, wpm: clamped)
  case persist_target(updated) {
    PersistGlobal -> {
      let new_defaults =
        UserSettings(..updated.global_defaults, default_wpm: clamped)
      #(
        Model(..updated, global_defaults: new_defaults),
        save_global_settings(new_defaults),
      )
    }
    PersistBook(id) -> {
      let overrides = case updated.book_settings {
        None -> empty_book_settings()
        Some(s) -> s
      }
      let new_overrides = BookSettings(..overrides, wpm: Some(clamped))
      #(
        Model(..updated, book_settings: Some(new_overrides)),
        save_book_settings(id, new_overrides),
      )
    }
  }
}

fn apply_set_paragraph_delay(
  model: Model,
  value: Int,
) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(value, min_paragraph_delay_ms, max_paragraph_delay_ms)
  let updated = Model(..model, paragraph_delay_ms: clamped)
  case persist_target(updated) {
    PersistGlobal -> {
      let new_defaults =
        UserSettings(
          ..updated.global_defaults,
          default_paragraph_delay_ms: clamped,
        )
      #(
        Model(..updated, global_defaults: new_defaults),
        save_global_settings(new_defaults),
      )
    }
    PersistBook(id) -> {
      let overrides = case updated.book_settings {
        None -> empty_book_settings()
        Some(s) -> s
      }
      let new_overrides =
        BookSettings(..overrides, paragraph_delay_ms: Some(clamped))
      #(
        Model(..updated, book_settings: Some(new_overrides)),
        save_book_settings(id, new_overrides),
      )
    }
  }
}

fn apply_set_page_delay(model: Model, value: Int) -> #(Model, Effect(Msg)) {
  let clamped = clamp_int(value, min_page_delay_ms, max_page_delay_ms)
  let updated = Model(..model, page_delay_ms: clamped)
  case persist_target(updated) {
    PersistGlobal -> {
      let new_defaults =
        UserSettings(..updated.global_defaults, default_page_delay_ms: clamped)
      #(
        Model(..updated, global_defaults: new_defaults),
        save_global_settings(new_defaults),
      )
    }
    PersistBook(id) -> {
      let overrides = case updated.book_settings {
        None -> empty_book_settings()
        Some(s) -> s
      }
      let new_overrides =
        BookSettings(..overrides, page_delay_ms: Some(clamped))
      #(
        Model(..updated, book_settings: Some(new_overrides)),
        save_book_settings(id, new_overrides),
      )
    }
  }
}

/// Toggle the OpenDyslexic body class. Unlike every other control on
/// the settings panel (`ToggleDarkMode`, `SetFontSize`,
/// `SetLineSpacing`, `ToggleGhostMode`, `SetGhostOpacity`, the four
/// pacing fields), `dyslexia_font` is **deliberately not persisted**:
/// it is not part of the wire-form `UserSettings` record and there is
/// no `user_settings.dyslexia_font` column on the server. The toggle
/// only modifies the in-memory `Model.dyslexia_font` and pushes the
/// body class through FFI; a page reload reverts to the compiled-in
/// default (`False`).
///
/// This divergence is intentional for the settings-persistence quest
/// (the original done-when did not enumerate dyslexia), but surfacing
/// it here so that a future operative does not copy this handler as a
/// precedent for a new persistable setting. Adding persistence later
/// requires extending `UserSettings` (server + client mirrors), the
/// `user_settings` schema (with an ALTER TABLE migration), the
/// JSON encoders / decoders, and routing this handler through
/// `save_global_settings` after the toggle — same shape as any other
/// `apply_set_*` arm in this file.
fn apply_toggle_dyslexia_font(model: Model) -> #(Model, Effect(Msg)) {
  let new_font = !model.dyslexia_font
  #(
    Model(..model, dyslexia_font: new_font),
    effect.batch([
      effect.from(fn(_dispatch) {
        ffi.set_body_class(body_class_dyslexia_font, new_font)
      }),
      // OpenDyslexic has wider glyph metrics than the system stack, so
      // paragraph wrap heights shift on the toggle. Re-measure for the
      // same reason `apply_set_font_size` does.
      repaginate_after_paint(),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Mode + space-press routing
// ---------------------------------------------------------------------------

fn apply_set_mode(model: Model, mode: Mode) -> #(Model, Effect(Msg)) {
  case mode {
    Manual -> {
      // Leaving RealTime: kill any in-flight timer and reset the
      // engine to a fully-dormant state. The bitsets persist —
      // fade-engine erasures remain visible-as-gone in Manual mode.
      // `active_line` clears alongside the engine: the overlay is a
      // RealTime-only affordance and would otherwise linger as a
      // ghost rectangle on the page after the toggle flipped.
      let cleared =
        Model(
          ..model,
          mode: Manual,
          engine_state: Stopped,
          next_word_index: None,
          active_line: None,
        )
      #(
        cleared,
        effect.batch([
          effect.from(fn(_dispatch) { ffi.clear_word_timer() }),
          save_reading_state(cleared),
        ]),
      )
    }
    RealTime -> {
      let switched = Model(..model, mode: RealTime)
      #(switched, save_reading_state(switched))
    }
  }
}

fn apply_space_pressed(model: Model) -> #(Model, Effect(Msg)) {
  case model.mode {
    Manual -> {
      let new_model = apply_erase_focused(model)
      #(new_model, save_reading_state(new_model))
    }
    RealTime ->
      case model.engine_state {
        Running -> apply_pause_fade(model)
        Paused -> apply_resume_fade(model)
        Stopped -> apply_start_fade(model)
      }
  }
}

// ---------------------------------------------------------------------------
// Touch / gesture handler
// ---------------------------------------------------------------------------

/// Resolve a `TouchEnd` into the next model state. Clears
/// `touch_start` unconditionally, then classifies the gesture
/// (`Tap` / `SwipeLeft` / `SwipeRight`) and routes the swipe to a
/// page navigation or an undo. A `Tap` in `Manual` mode is a
/// no-op — sentence erasure flows through the synthesised `click`
/// event on the `.sentence` span. A `Tap` in `RealTime` mode is
/// routed through `apply_space_pressed`, which toggles the fade
/// engine's start/pause/resume state. Returns an `Effect` so the
/// RealTime branch can schedule or cancel the FFI word timer.
fn apply_touch_end(model: Model, x: Float, y: Float) -> #(Model, Effect(Msg)) {
  let cleared = Model(..model, touch_start: None)
  case model.touch_start {
    None -> #(cleared, effect.none())
    Some(#(start_x, start_y)) ->
      case gestures.classify(start_x, start_y, x, y) {
        gestures.Tap ->
          case cleared.mode {
            Manual -> #(cleared, effect.none())
            RealTime -> apply_space_pressed(cleared)
          }
        gestures.SwipeLeft -> {
          let advanced = go_to_page(cleared, cleared.current_page + 1)
          let save_effect = case advanced.current_page == cleared.current_page {
            // Clamped to the last page — no real navigation, so no
            // state change to persist. Matches the `NextPage` arm's
            // own "no-op when already on the last page" branch.
            True -> effect.none()
            False -> save_reading_state(advanced)
          }
          #(advanced, save_effect)
        }
        gestures.SwipeRight -> {
          let undone = apply_undo(cleared)
          #(undone, save_reading_state(undone))
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Erase / undo / focus helpers
// ---------------------------------------------------------------------------

/// Pop the most recent erase off `undo_stack` and remove its index
/// from `erased`. Returns the model unchanged when the stack is
/// empty. Shared between the `Undo` reducer arm and the SwipeRight
/// branch of `apply_touch_end` — both consume the head of the stack
/// in identical ways, and a copy-and-paste here would let the two
/// branches drift apart on a future refactor (e.g. one of them
/// growing a "max-undo-count" cap that the other forgot).
fn apply_undo(model: Model) -> Model {
  case model.undo_stack {
    [] -> model
    [last, ..rest] ->
      Model(..model, erased: set.delete(model.erased, last), undo_stack: rest)
  }
}

/// Insert `global_index` into `erased` and push it onto the
/// `undo_stack`, capped to `undo_stack_depth` entries. A repeat
/// erase on an already-erased sentence is a no-op so the undo
/// stack never carries duplicate entries — without that guard, an
/// `EraseFocused` press on a sentence the reader had earlier
/// clicked would push a second copy and force two undo presses to
/// restore one sentence. Shared between `EraseSentence` (from
/// click/tap) and `EraseFocused` (from the keyboard cursor).
fn apply_erase(model: Model, global_index: Int) -> Model {
  case set.contains(model.erased, global_index) {
    True -> model
    False ->
      Model(
        ..model,
        erased: set.insert(model.erased, global_index),
        undo_stack: [global_index, ..model.undo_stack]
          |> list.take(undo_stack_depth),
      )
  }
}

/// Step the keyboard cursor by one sentence in `direction`,
/// crossing page boundaries when the next visible sentence lives
/// on a different page. When the cursor is dormant
/// (`focused_sentence: None`), the first press initialises focus
/// to the first non-erased sentence on the current page rather
/// than moving — the press wakes the cursor up.
fn focus_sentence_step(model: Model, direction: navigation.Direction) -> Model {
  let locations = navigation.locate_sentences(model.pages)
  case model.focused_sentence {
    None -> initialise_focus(model, locations)
    Some(current) ->
      case
        navigation.next_sentence(locations, current, model.erased, direction)
      {
        None -> model
        Some(target) -> move_focus(model, target)
      }
  }
}

/// Step the keyboard cursor by one paragraph in `direction`. The
/// landing rule is "first non-erased sentence of the
/// previous/next paragraph that still has visible text",
/// implemented in `navigation.next_paragraph_sentence`. Initialises
/// focus on first press, same rule as `focus_sentence_step`.
fn focus_paragraph_step(
  model: Model,
  direction: navigation.Direction,
) -> Model {
  let locations = navigation.locate_sentences(model.pages)
  case model.focused_sentence {
    None -> initialise_focus(model, locations)
    Some(current) ->
      case navigation.locate(locations, current) {
        None -> model
        Some(current_location) ->
          case
            navigation.next_paragraph_sentence(
              locations,
              current_location.paragraph_global_index,
              model.erased,
              direction,
            )
          {
            None -> model
            Some(target) -> move_focus(model, target)
          }
      }
  }
}

/// Erase the focused sentence and advance the cursor to the next
/// non-erased sentence (Forward), crossing page boundaries when the
/// erased sentence was the last visible one on its page. When the
/// erase happened to land on the document's final visible sentence
/// the cursor goes dormant (`focused_sentence: None`); the reader
/// then has to press a vim key again to re-initialise.
fn apply_erase_focused(model: Model) -> Model {
  case model.focused_sentence {
    None -> model
    Some(idx) -> {
      let erased_model = apply_erase(model, idx)
      let locations = navigation.locate_sentences(erased_model.pages)
      case
        navigation.next_sentence(
          locations,
          idx,
          erased_model.erased,
          navigation.Forward,
        )
      {
        None -> Model(..erased_model, focused_sentence: None)
        Some(target) -> move_focus(erased_model, target)
      }
    }
  }
}

/// Set the cursor to `target`, changing the current page first
/// when the target lives on a different page. Used by every vim
/// navigation message — the navigation module returns the target
/// page alongside the target sentence so this helper can commit
/// both in one place.
fn move_focus(model: Model, target: navigation.SentenceLocation) -> Model {
  let with_page = change_page(model, target.page_index)
  Model(..with_page, focused_sentence: Some(target.sentence_global_index))
}

/// Initialise the cursor to the first non-erased sentence on the
/// current page. The result is `None` when every sentence on the
/// current page is erased — a legitimate state during a re-read
/// where the reader has erased an entire page and the next vim key
/// would normally advance them off it.
fn initialise_focus(
  model: Model,
  locations: List(navigation.SentenceLocation),
) -> Model {
  let focused =
    navigation.first_on_page(locations, model.current_page, model.erased)
    |> option.map(fn(loc) { loc.sentence_global_index })
  Model(..model, focused_sentence: focused)
}
