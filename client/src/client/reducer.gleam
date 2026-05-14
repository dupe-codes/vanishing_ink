//// Reducer: the main `update` dispatcher and the three substantial
//// `apply_*` helpers extracted from the dispatcher's larger arms
//// (`apply_paragraphs_measured`, `apply_next_page`,
//// `apply_book_deleted_ok`), plus `apply_space_pressed` which routes
//// the desktop spacebar to either the focus-erase or the fade-engine
//// path. Book-lifecycle helpers (`apply_open_book`,
//// `apply_book_loaded`, `apply_text_load`, `apply_go_to_library`,
//// `apply_submit_paste`) live in `client/reducer/book`. Settings
//// reducers split between `client/reducer/settings` (setters +
//// persist + reset + mode + dyslexia) and `client/reducer/settings_load`
//// (the three GET-response handlers). Vim cursor helpers are in
//// `client/reducer/focus` and touch-gesture + sentence-erase
//// primitives in `client/reducer/touch`. The reducer pattern-matches
//// the `Msg` ADT exhaustively and produces an updated `Model` plus
//// an `Effect(Msg)` for any side-effects (FFI calls, fetch requests,
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

import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import lustre/effect.{type Effect}

import client/effects.{
  delete_book_effect, describe_fetch_error, measure_after_paint,
  measure_lines_after_paint, save_reading_state,
}
import client/engine.{
  apply_advance_word, apply_pause_fade, apply_resume_fade, apply_start_fade,
  resolve_active_line,
}
import client/msg.{
  type Msg, AdvanceWord, BookCreated, BookDeleted, BookLoaded,
  BookSettingsLoaded, BooksLoaded, CancelDelete, ConfirmDelete, EpubFileSelected,
  EpubParsed, EraseFocused, EraseSentence, ExecuteDelete, FocusNext,
  FocusParagraphDown, FocusParagraphUp, FocusPrevious, GoToLibrary,
  JumpToChapter, JumpToPage, LinesMeasured, LockInJump, NextPage, NoOp, OpenBook,
  ParagraphsMeasured, PauseFade, ReadingStateLoaded, ResetBookSettings,
  ResumeFade, SetFontSize, SetGhostOpacity, SetJumpPageInput, SetLineSpacing,
  SetMode, SetPageDelay, SetParagraphDelay, SetPasteText, SetPasteTitle, SetWpm,
  SettingsLoaded, SpacePressed, StartFade, SubmitJumpPage, SubmitPaste,
  TextLoaded, ToggleAddBook, ToggleDarkMode, ToggleDyslexiaFont, ToggleGhostMode,
  ToggleJumpMenu, ToggleSettings, TouchCancel, TouchEnd, TouchStart, Undo,
  UndoJump, ViewportResized,
}
import client/navigation
import client/pagination
import client/reducer/book.{
  apply_book_loaded, apply_epub_file_selected, apply_epub_parsed,
  apply_go_to_library, apply_open_book, apply_submit_paste, apply_text_load,
}
import client/reducer/focus.{
  apply_erase_focused, focus_paragraph_step, focus_sentence_step,
}
import client/reducer/jump.{
  apply_jump_to_chapter, apply_jump_to_page, apply_lock_in_jump,
  apply_set_jump_page_input, apply_submit_jump_page, apply_toggle_jump_menu,
  apply_undo_jump,
}
import client/reducer/settings.{
  apply_reset_book_settings, apply_set_font_size, apply_set_ghost_opacity,
  apply_set_line_spacing, apply_set_mode, apply_set_page_delay,
  apply_set_paragraph_delay, apply_set_wpm, apply_toggle_dark_mode,
  apply_toggle_dyslexia_font, apply_toggle_ghost_mode,
}
import client/reducer/settings_load.{
  apply_book_settings_loaded, apply_reading_state_loaded, apply_settings_loaded,
}
import client/reducer/touch.{apply_erase, apply_touch_end, apply_undo}
import client/state.{
  type Model, Library, Manual, Model, Paused, RealTime, Running, Stopped,
}
import client/state/helpers.{
  compute_chapter_entries, compute_current_chapter_title, go_to_page,
}
import client/types

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

    ParagraphsMeasured(heights, available_height) ->
      apply_paragraphs_measured(model, heights, available_height)

    LinesMeasured(boxes) -> {
      let new_model = Model(..model, line_boxes: boxes)
      #(
        Model(..new_model, active_line: resolve_active_line(new_model)),
        effect.none(),
      )
    }

    NextPage -> apply_next_page(model)

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

    TouchEnd(x, y) -> apply_touch_end(model, x, y, apply_space_pressed)

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
        paste_warning: None,
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
        // The POST attempt supersedes any partial-import banner
        // that was on the sheet — the reader is now seeing a
        // failure message, not a "we got most of the book" note.
        paste_warning: None,
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
          // Opening the sheet clears any prior error and warning so
          // the form starts clean; closing it leaves both banners
          // intact (the reader is dismissing the surface, not
          // acknowledging the message). Warning is paired with
          // error here so a stale partial-import banner does not
          // outlive the sheet that birthed it.
          paste_error: case opening {
            True -> None
            False -> model.paste_error
          },
          paste_warning: case opening {
            True -> None
            False -> model.paste_warning
          },
        ),
        effect.none(),
      )
    }

    SetPasteTitle(value) -> #(
      Model(..model, paste_title: value, paste_error: None, paste_warning: None),
      effect.none(),
    )

    SetPasteText(value) -> #(
      Model(..model, paste_text: value, paste_error: None, paste_warning: None),
      effect.none(),
    )

    SubmitPaste -> apply_submit_paste(model)

    EpubFileSelected(file) -> apply_epub_file_selected(model, file)

    EpubParsed(result) -> apply_epub_parsed(model, result)

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

    BookDeleted(id, Ok(_)) -> apply_book_deleted_ok(model, id)

    BookDeleted(id, Error(error)) -> #(
      Model(
        ..model,
        library_error: Some(describe_fetch_error(error)),
        deleting_book_ids: set.delete(model.deleting_book_ids, id),
      ),
      effect.none(),
    )

    ToggleJumpMenu -> apply_toggle_jump_menu(model)

    JumpToPage(page_index) -> apply_jump_to_page(model, page_index)

    JumpToChapter(chapter_index) -> apply_jump_to_chapter(model, chapter_index)

    LockInJump -> apply_lock_in_jump(model)

    UndoJump -> apply_undo_jump(model)

    SetJumpPageInput(value) -> apply_set_jump_page_input(model, value)

    SubmitJumpPage -> apply_submit_jump_page(model)

    // Sentinel: see `Msg.NoOp` for the rationale. No dispatch site
    // ever fires this; the arm is required so the pattern match
    // stays exhaustive after introducing the variant for the
    // `decode.failure` placeholders in the view layer.
    NoOp -> #(model, effect.none())
  }
}

// ---------------------------------------------------------------------------
// Extracted update arms
// ---------------------------------------------------------------------------

/// Apply a `ParagraphsMeasured(heights, available_height)` dispatch.
/// Recomputes the page list against the new measurements, clamps
/// `current_page` into the new range, re-anchors `focused_sentence`
/// if pagination shifted it off the visible page, refreshes the
/// cached `current_chapter_title`, and chains a follow-up line
/// measurement so the active-line overlay re-anchors to the
/// post-repagination geometry.
fn apply_paragraphs_measured(
  model: Model,
  heights: List(#(Int, Float)),
  available_height: Float,
) -> #(Model, Effect(Msg)) {
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
  let chapter_title = compute_current_chapter_title(model.text, pages, clamped)
  // Refresh the cached chapter list whenever pagination re-runs.
  // The list filters to chapters strictly ahead of `clamped`, so
  // opening the menu after a re-pagination always sees an accurate
  // "where can I jump to from here" set rather than entries that
  // pagination has since invalidated.
  let chapter_entries = compute_chapter_entries(pages, clamped)
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
      chapter_entries: chapter_entries,
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

/// Advance to the next page on `NextPage`. Clears the cached line
/// geometry on a real page change so the active-line overlay does
/// not glide between rows on the 250ms `top` transition; a no-op
/// page turn (already on the last page) skips the re-measure.
fn apply_next_page(model: Model) -> #(Model, Effect(Msg)) {
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
      // `go_to_page` (via `change_page`) already refreshed the
      // chapter list against the new page; only the overlay caches
      // remain to clear here.
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

/// Apply a `BookDeleted(id, Ok(_))` dispatch. Removes the book from
/// the library list and, if the deleted book is the active one,
/// kicks the reader back to the library through `apply_go_to_library`.
fn apply_book_deleted_ok(model: Model, id: String) -> #(Model, Effect(Msg)) {
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

// ---------------------------------------------------------------------------
// Mode + space-press routing
// ---------------------------------------------------------------------------

/// Route a `SpacePressed` dispatch. In `Manual` mode this erases
/// the focused sentence; in `RealTime` it toggles the fade engine
/// between Start / Pause / Resume.
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
