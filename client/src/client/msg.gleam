//// Application messages. The `Msg` ADT is the single source of truth
//// for everything the reducer can react to — every UI event, every
//// FFI callback, and every fetch resolution dispatches through one of
//// these variants. The reducer (`client/reducer.gleam`) pattern-
//// matches the ADT exhaustively.
////
//// The variants are grouped roughly by source:
////   * pagination / measurement,
////   * reader gestures and undo,
////   * vim-key focus,
////   * settings sliders / toggles,
////   * fade engine (RealTime mode),
////   * book lifecycle (library, fetch, create, delete),
////   * server settings + reading-state load.

import gleam/dynamic.{type Dynamic}

import client/epub.{type EpubError, type EpubExtract}
import client/ffi
import client/state.{type LineBox, type Mode}
import client/types.{type BookMeta}
import shared/segmenter.{type SegmentedText}

/// Application messages.
pub type Msg {
  /// A book has been segmented and is ready to render. Production
  /// flows route through `BookLoaded` (server response from
  /// `fetch_book`), which delegates the per-text reset to the same
  /// `apply_text_load` helper this arm uses; `TextLoaded` itself is
  /// retained as a direct entry point for the reducer tests that
  /// pin the per-text reset surface in isolation from the library
  /// bookkeeping `BookLoaded` layers on top.
  TextLoaded(SegmentedText)

  /// Browser paragraph heights have been read via FFI. Carries the
  /// `(global_index, height)` pairs alongside the available
  /// content-area height the pagination algorithm should fit pages
  /// into.
  ParagraphsMeasured(heights: List(#(Int, Float)), available_height: Float)

  /// Visual line geometry for the current page has been read via
  /// FFI. The reducer stores the boxes on the model and recomputes
  /// `active_line` against the in-flight `next_word_index`. Fired
  /// from `measure_lines_after_paint` after every event that can
  /// re-flow the visible page (pagination completion, page turn,
  /// font / spacing changes, fade-engine page advance).
  LinesMeasured(boxes: List(LineBox))

  /// Reader requested the next page (`ArrowRight` or swipe-left
  /// gesture). Clears the undo stack — erases on the page being
  /// left commit.
  NextPage

  /// Debounced `window.resize` fired. The handler re-runs the
  /// measurement effect — paragraph heights change with viewport
  /// width because of line wrapping.
  ViewportResized

  /// Reader tapped or clicked the sentence with this global index.
  /// `update` writes it into `erased` and pushes it onto
  /// `undo_stack`. A repeat erase of an already-erased sentence is
  /// a no-op so the undo stack stays meaningful.
  EraseSentence(global_index: Int)

  /// Reader requested undo (swipe right with non-empty undo stack,
  /// `Cmd+Z`/`Ctrl+Z`, or any other future undo binding). Pops the
  /// most recent erase off `undo_stack` and clears its `erased`
  /// entry. No-op when the stack is empty.
  Undo

  /// `touchstart` fired on the reader page. Carries the primary
  /// touch's viewport coordinates; `update` stores them on the
  /// model so `TouchEnd` can compute the gesture delta.
  TouchStart(x: Float, y: Float)

  /// `touchend` fired on the reader page. `update` reads the
  /// matching `touch_start` off the model, classifies the gesture
  /// via `gestures.classify`, and routes a swipe to either a page
  /// navigation or `Undo`. A `Tap` outcome is a no-op — sentence
  /// erasure flows through the synthesized `click` event.
  TouchEnd(x: Float, y: Float)

  /// `touchcancel` fired on the reader page. The browser delivers
  /// this when an in-flight touch is interrupted (system gesture,
  /// modal, notification) and follows it with *no* matching
  /// `touchend`. `update` clears `touch_start` so the next
  /// legitimate `touchend` doesn't classify against the cancelled
  /// gesture's coordinates and emit a phantom swipe.
  TouchCancel

  /// Reader pressed `h` — move the keyboard cursor to the previous
  /// non-erased sentence on the current page. Stops at the page
  /// boundary: when the cursor is on the first non-erased sentence
  /// of the current page, `FocusPrevious` is a no-op. A no-op when
  /// `focused_sentence` is `None` — the first press wakes the cursor
  /// rather than moving it (initialises to the first non-erased
  /// sentence on the current page).
  FocusPrevious

  /// Reader pressed `l` — move the keyboard cursor to the next
  /// non-erased sentence. Crosses page boundaries forward, mirror
  /// of `FocusPrevious`. A no-op at the end of the document.
  /// Initialises focus on first press.
  FocusNext

  /// Reader pressed `k` — move the keyboard cursor to the first
  /// non-erased sentence of the previous paragraph on the current
  /// page. Fully-erased paragraphs are skipped. Stops at the page
  /// boundary: a no-op when the cursor is already on the first
  /// paragraph of the current page. Initialises focus on first press.
  FocusParagraphUp

  /// Reader pressed `j` — move the keyboard cursor to the first
  /// non-erased sentence of the next paragraph. Mirror of
  /// `FocusParagraphUp`. A no-op at the end of the document.
  /// Initialises focus on first press.
  FocusParagraphDown

  /// Reader pressed `Space` — erase the currently focused sentence
  /// (same effect as a click/tap on that sentence) and advance the
  /// cursor to the next non-erased sentence. Crosses page
  /// boundaries when no non-erased sentence remains after the
  /// erased one on the current page. A no-op when
  /// `focused_sentence` is `None` — there is no cursor target to
  /// act on.
  EraseFocused

  /// Settings panel gear icon (or close button) toggled. Flips
  /// `settings_open`; no DOM side effect.
  ToggleSettings

  /// Reader toggled the dark / light theme switch in the settings
  /// panel. Flips `dark_mode` and pushes `vi-light-mode` onto the
  /// body class list to override the dark palette in CSS.
  ToggleDarkMode

  /// Reader dragged the font-size slider. The reducer clamps the
  /// value into `[min_font_size, max_font_size]`, writes it to the
  /// model, pushes the new value into `--vi-base-font-size`, and
  /// dispatches `ViewportResized` so paragraph heights re-measure
  /// at the new font size before pagination recalculates.
  SetFontSize(Int)

  /// Reader dragged the line-spacing slider. Same flow as
  /// `SetFontSize` but for `--vi-line-height` and the `line_spacing`
  /// model field.
  SetLineSpacing(Float)

  /// Reader toggled ghost mode in the settings panel. Flips
  /// `ghost_mode` and adds/removes `vi-ghost-mode` on the body.
  /// When the toggle goes on, erased sentences fade up to
  /// `ghost_opacity` instead of fully disappearing; when it goes
  /// off, the inline opacity reverts to `0`.
  ToggleGhostMode

  /// Reader dragged the ghost-opacity slider. Clamped into
  /// `[min_ghost_opacity, max_ghost_opacity]`, written to the model,
  /// and pushed into `--vi-ghost-opacity` for completeness — the
  /// view computes the inline opacity directly from the model field,
  /// the custom property is a hook for future CSS rules.
  SetGhostOpacity(Float)

  /// Reader toggled the dyslexia-friendly font switch. Flips
  /// `dyslexia_font` and adds/removes `vi-dyslexia-font` on the
  /// body. The font swap changes paragraph heights, so this also
  /// dispatches `ViewportResized` to trigger re-pagination.
  ToggleDyslexiaFont

  /// Reader selected a reading mode in the settings panel.
  /// Switching to `Manual` stops any running fade engine and
  /// clears its timer; switching to `RealTime` leaves the engine
  /// in `Stopped` state (the reader must press Space/tap to
  /// start). The bitsets are not converted — both modes share
  /// the same `Model` and any prior erasures persist.
  SetMode(Mode)

  /// Reader pressed Space (desktop) or tapped the reader page
  /// (mobile). In `Manual` mode this is forwarded to
  /// `EraseFocused` so vim-keys behaviour is unchanged. In
  /// `RealTime` mode the reducer routes it to start/pause/resume
  /// of the fade engine based on the current `engine_state`.
  SpacePressed

  /// Start the fade engine. Finds the first non-erased word on
  /// the current page, sets `next_word_index` to its global
  /// index, transitions `engine_state` to `Running`, and
  /// schedules the first AdvanceWord tick after one word
  /// interval. No-op when there is no eligible word on the
  /// current page or when the engine is already `Running`.
  StartFade

  /// Pause the fade engine. Clears the in-flight word timer via
  /// FFI and transitions `engine_state` to `Paused`. Keeps
  /// `next_word_index` intact so `ResumeFade` continues from the
  /// same position. No-op when the engine is not `Running`.
  PauseFade

  /// Resume a paused fade engine. Re-schedules the AdvanceWord
  /// timer at the current WPM interval and transitions
  /// `engine_state` to `Running`. No-op when the engine is not
  /// `Paused`.
  ResumeFade

  /// Timer callback fired by the FFI word-timer slot. Marks
  /// `next_word_index` as faded (inserts into `erased_words`),
  /// finds the next eligible word, and either schedules the next
  /// tick or advances the page / stops the engine. Guarded
  /// against stale ticks — when `engine_state != Running` the
  /// arm is a no-op so a callback that survives a `PauseFade`
  /// race (none should, given the synchronous FFI slot, but the
  /// guard is the belt to the FFI's braces) cannot mutate state.
  AdvanceWord

  /// Reader dragged the WPM slider. Clamps the incoming value
  /// into `[min_wpm, max_wpm]` and writes it to the model. Does
  /// not re-schedule the in-flight timer — the next AdvanceWord
  /// already reads the live `model.wpm` when it computes its
  /// follow-up delay, so a WPM change takes effect on the next
  /// tick without needing a restart.
  SetWpm(Int)

  /// Reader dragged the paragraph-delay slider. Clamps into
  /// `[min_paragraph_delay_ms, max_paragraph_delay_ms]`. Same
  /// take-effect-on-next-tick semantics as `SetWpm`.
  SetParagraphDelay(Int)

  /// Reader dragged the page-delay slider. Clamps into
  /// `[min_page_delay_ms, max_page_delay_ms]`. Same
  /// take-effect-on-next-tick semantics as `SetWpm`.
  SetPageDelay(Int)

  /// `GET /api/books` resolved. `Ok(books)` lands the library
  /// contents on the model and unsets `books_loading`; `Error(_)`
  /// surfaces a human-readable message into `library_error` and
  /// also unsets `books_loading` so the view does not stay on the
  /// skeleton state.
  BooksLoaded(Result(List(BookMeta), ffi.FetchError))

  /// `GET /api/books/:id` resolved. The success arm routes through
  /// `apply_book_loaded`, which delegates the per-text reset
  /// (segmented payload, flat-paragraph cache, totals, per-book
  /// scratch bitsets) to the shared `apply_text_load` helper that
  /// `TextLoaded` also calls, then layers on the library
  /// bookkeeping fields (view flip to `Reader`, `active_book_id`,
  /// `library_error: None`, engine reset). The error arm flips the
  /// view back to `Library` and stores the message in
  /// `library_error` so the reader sees what went wrong.
  BookLoaded(Result(#(BookMeta, SegmentedText), ffi.FetchError))

  /// `POST /api/books` resolved. The success arm prepends the new
  /// metadata to `books`, clears the paste form, and closes the
  /// bottom sheet — the reader stays in the library so they can
  /// see their new book on the grid before they decide to open it.
  /// The error arm leaves the form populated and surfaces the
  /// failure in `paste_error`.
  BookCreated(Result(#(BookMeta, SegmentedText), ffi.FetchError))

  /// Library card tapped. Flips `view` to `Reader`, kicks off
  /// `fetch_book(id)`, and resets the reader scratch state so the
  /// previous book's erasures don't bleed into the new session.
  OpenBook(id: String)

  /// Reader back-arrow pressed. Flips `view` to `Library`, stops
  /// any running fade engine, clears the in-flight word timer,
  /// and resets the reader's per-book state (`text`, `pages`,
  /// erasures, focus, line geometry) so re-opening the same book
  /// boots from a clean slate.
  GoToLibrary

  /// FAB tapped (open) or sheet overlay / close button tapped
  /// (close). Flips `add_book_open` and clears `paste_error` when
  /// the sheet opens so a previously surfaced validation message
  /// doesn't greet the next attempt.
  ToggleAddBook

  /// Controlled title input change. Stores the new value and clears
  /// `paste_error` so the error message disappears as soon as the
  /// reader starts typing again.
  SetPasteTitle(value: String)

  /// Controlled paste-textarea change. Same shape as `SetPasteTitle`
  /// — stores the new value and clears any prior error.
  SetPasteText(value: String)

  /// "Add to Library" button pressed. Validates that both fields
  /// are non-empty; on success, marks `paste_submitting: True` and
  /// fires `create_book`. The submit button's `disabled` reflects
  /// `paste_submitting` so a double-tap cannot fire two POSTs.
  SubmitPaste

  /// Reader picked an `.epub` file from the add-book sheet's file
  /// input. The payload is the raw browser `File` object wrapped in
  /// a `Dynamic` — the reducer dispatches the `parse_epub` effect,
  /// which hands it back to the FFI for parsing. Carries `Dynamic`
  /// rather than a typed handle because a `File` object does not
  /// round-trip through Gleam's typed runtime.
  EpubFileSelected(file: Dynamic)

  /// `parse_epub_file` resolved. The success arm copies the
  /// extracted title and segmenter-shaped body text into
  /// `paste_title` / `paste_text` so the reader sees the imported
  /// book pre-filled in the same form they would otherwise paste
  /// into — they can review and edit the title before submitting.
  /// The error arm surfaces a human-readable message in
  /// `paste_error`.
  EpubParsed(result: Result(EpubExtract, EpubError))

  /// `GET /api/settings` resolved. The success arm decodes the body
  /// as `UserSettings`, stamps `model.global_defaults`, and applies
  /// every field to the matching effective model field — pushing CSS
  /// custom properties and body classes via the same FFI calls the
  /// individual setters use. The error arm logs and continues with
  /// the compiled-in defaults; settings load is non-blocking by
  /// design.
  SettingsLoaded(Result(String, ffi.FetchError))

  /// `GET /api/books/:id/settings` resolved. The success arm decodes
  /// the body as `BookSettings`, merges each field with
  /// `model.global_defaults`, and applies the merged values to the
  /// four overridable effective fields. The error arm logs and
  /// continues with the in-effect globals — a stuck request leaves
  /// the reader using the user's last-known global preferences.
  ///
  /// The `book_id` is the id the GET was issued for. The reducer
  /// drops responses whose id no longer matches `model.active_book_id`
  /// (or whose view has flipped back to `Library`) — see the guard at
  /// the top of `apply_book_settings_loaded`. The id round-trips so
  /// "open A → back to library → open B → A's response lands" cannot
  /// stamp A's overrides onto B's session.
  BookSettingsLoaded(book_id: String, result: Result(String, ffi.FetchError))

  /// `GET /api/books/:id/state` resolved. The success arm decodes the
  /// body as a `ReadingState`, unpacks the base64 bitsets back into
  /// `Set(Int)` projections, maps `mode` onto the typed `Mode` variant,
  /// and stamps `current_page`, `erased`, `erased_words`, and `mode`
  /// onto the model. The error arm logs and continues with the empty
  /// defaults `apply_text_load` already installed — a stuck request
  /// leaves the reader on page 0 with no erasures, the same state a
  /// fresh book would carry.
  ///
  /// The `book_id` round-trips the originating request id so the
  /// reducer can drop responses whose id no longer matches
  /// `model.active_book_id` (or whose view has flipped back to
  /// `Library`). Same race-guard shape as `BookSettingsLoaded` —
  /// "open A → back → open B → A's GET lands" cannot stamp A's
  /// progress onto B's session.
  ReadingStateLoaded(book_id: String, result: Result(String, ffi.FetchError))

  /// Reader pressed "Reset to default" in the per-book section of
  /// the settings panel. Clears every per-book override (writes
  /// `BookSettings(None, None, None, None)` to the server and the
  /// model), and restores the four overridable effective fields to
  /// `model.global_defaults`. A no-op when there is no active book.
  ResetBookSettings

  /// Reader tapped the delete icon on a book card. Sets
  /// `confirm_delete_id` to `Some(id)` so the confirmation overlay
  /// renders for that specific card. No request is fired yet.
  ConfirmDelete(id: String)

  /// Reader tapped "Cancel" on the delete confirmation overlay.
  /// Clears `confirm_delete_id` without firing a DELETE request.
  CancelDelete

  /// Reader tapped "Delete" on the delete confirmation overlay.
  /// Fires `DELETE /api/books/:id` and clears `confirm_delete_id`.
  ExecuteDelete(id: String)

  /// `DELETE /api/books/:id` resolved. The `Ok` arm removes the book
  /// from `model.books` and, when the deleted book is the currently
  /// active reader book, navigates back to the library. The `Error`
  /// arm surfaces the failure in `library_error` without removing the
  /// book from the grid.
  BookDeleted(id: String, result: Result(String, ffi.FetchError))

  /// Reader tapped the Jump button on the bottom bar (open) or the
  /// scrim / close affordance on the modal (close). Flips
  /// `model.jump_menu_open`. Closing the menu mid-preview is harmless
  /// — `jump_preview` is independent and lives until `LockInJump` or
  /// `UndoJump` resolves it.
  ToggleJumpMenu

  /// Reader picked a page from the Jump Ahead menu. The reducer
  /// stashes the pre-jump position on `jump_preview`, pauses the fade
  /// engine for the preview, and moves the reader forward to the
  /// target page. Backward targets (`page_index <= current_page`) are
  /// rejected — the menu only renders forward chapters, and the
  /// numeric input clamps to the same range, but the reducer-side
  /// guard is the authority.
  JumpToPage(page_index: Int)

  /// Reader tapped a chapter row in the Jump Ahead menu. Looked up
  /// against `chapter_entries`; on a hit, delegates to the same path
  /// `JumpToPage` uses. A no-op when the index has no entry — the
  /// chapter list is the reducer's source for "what page does this
  /// chapter live on?", so a stale tap (chapter dropped on a
  /// re-pagination after the menu opened) collapses to no action
  /// rather than landing the reader on a wrong page.
  JumpToChapter(chapter_index: Int)

  /// Reader tapped Lock In on the preview banner. Bulk-vanishes
  /// every word on pages before `current_page` (the reader has
  /// "read" them by jumping past them), clears `jump_preview` so the
  /// banner disappears, and chains a `save_reading_state` so the
  /// server learns about the new position and the freshly-vanished
  /// word bitset together.
  LockInJump

  /// Reader tapped Go Back on the preview banner. Restores the
  /// pre-jump position, engine state, and word pointer from
  /// `jump_preview`, then clears the snapshot. No save fires — the
  /// reading position is unchanged from before the jump.
  UndoJump

  /// Controlled change of the Jump Ahead menu's page-number input.
  /// Stores the new value on `model.jump_page_input` so the Enter-
  /// key handler and the Go button can both read it without
  /// reaching into the DOM. Carries the raw string so the field
  /// can echo "12" while the reader is mid-typing rather than
  /// the parsed int, which would round-trip badly on partial
  /// input.
  SetJumpPageInput(value: String)

  /// Reader tapped the Go button next to the Jump Ahead menu's
  /// page-number input. Reads `model.jump_page_input`, parses it as
  /// a 1-based page number, and dispatches the same code path the
  /// Enter-key handler does. Invalid / empty / out-of-range inputs
  /// are reducer-side no-ops — the input field's `min`/`max` HTML
  /// attributes are advisory; the reducer is the authority.
  SubmitJumpPage

  /// `POST /api/books/:id/sessions` resolved. Carries the originating
  /// `book_id` so the reducer can ignore a response that lands after
  /// the reader has navigated to a different book, and a structured
  /// result so a transient failure is surfaced to the console without
  /// stranding the in-flight `active_session_id` field on the model.
  SessionCreated(book_id: String, result: Result(String, ffi.FetchError))

  /// `PUT /api/books/:id/sessions/:session_id` resolved. Fired after
  /// the closing PUT lands so the reducer can re-fetch the stats
  /// surface (which depends on the server-side aggregation reflecting
  /// the newly-closed session).
  SessionEnded(result: Result(String, ffi.FetchError))

  /// `document.visibilitychange` fired. Carries the document's new
  /// `visibilityState === "visible"` flag. The reducer ends the
  /// in-flight reading session on hide and starts a new one on show
  /// (subject to `view == Reader` / `active_book_id == Some(_)`).
  VisibilityChanged(visible: Bool)

  /// `GET /api/books/:id/stats` resolved. The success arm decodes the
  /// body as `BookStats` and stamps it onto `model.book_stats` for
  /// the active book; the error arm logs and leaves the prior value
  /// in place.
  FetchBookStatsResult(book_id: String, result: Result(String, ffi.FetchError))

  /// `GET /api/stats` resolved. The success arm decodes the body as
  /// `LibraryStats` and stamps it onto `model.library_stats`; the
  /// error arm logs and leaves the prior value in place.
  FetchLibraryStatsResult(result: Result(String, ffi.FetchError))

  /// `GET /api/stats/books` resolved. The success arm decodes the body
  /// as a list of `(book_id, BookStats)` pairs and stamps it onto
  /// `model.library_book_stats`; the error arm logs and leaves the
  /// prior map in place.
  FetchLibraryBookStatsResult(result: Result(String, ffi.FetchError))

  /// Reader tapped the stats button (open) or the scrim / close button
  /// on the stats overlay (close). Flips `model.stats_open`. Opening
  /// also chains a fresh `fetch_library_stats` so the overlay always
  /// shows the latest aggregate values.
  ToggleStatsView

  /// Reader tapped the edit-metadata affordance on a book card.
  /// Seeds `model.editing_metadata` with the current title / author /
  /// genre values so the form starts pre-filled with what the book
  /// already carries. A no-op when no book matches the id (a stale
  /// tap after a `BookDeleted` race).
  OpenEditMetadata(id: String)

  /// Scrim tap or close button on the metadata edit sheet. Clears
  /// `editing_metadata` without firing a PATCH; any unsaved input is
  /// discarded.
  CloseEditMetadata

  /// Controlled title input change on the metadata edit sheet.
  /// Stores the new value on `editing_metadata.title` and clears
  /// the in-flight error so the message disappears as soon as the
  /// reader starts typing again.
  SetEditMetadataTitle(value: String)

  /// Controlled author input change on the metadata edit sheet.
  SetEditMetadataAuthor(value: String)

  /// Controlled genre input change on the metadata edit sheet.
  SetEditMetadataGenre(value: String)

  /// "Save" pressed on the metadata edit sheet. Validates that the
  /// title is non-empty, marks `editing_metadata.submitting: True`,
  /// and dispatches `update_book_metadata`. The save button's
  /// `disabled` reflects `submitting` so a double-tap cannot fire
  /// two PATCHes.
  SubmitEditMetadata

  /// `PATCH /api/books/:id` resolved. The `Ok` arm replaces the
  /// matching book in `model.books` with the updated metadata and
  /// closes the edit sheet. The `Error` arm leaves the sheet open
  /// with a human-readable message in `editing_metadata.error` so
  /// the reader can retry.
  BookMetadataUpdated(id: String, result: Result(BookMeta, ffi.FetchError))

  /// Controlled change of the Jump Ahead menu's text-search input.
  /// Stores the new query on `model.jump_search_query` and recomputes
  /// `model.jump_search_results` against the pages strictly ahead of
  /// `current_page`. The recompute is intentionally synchronous in
  /// the reducer rather than effect-driven — the search walks page
  /// text in pure Gleam and the result list is capped at
  /// `search.jump_search_result_limit`, so per-keystroke recompute is
  /// well within frame budget. Empty / whitespace-only queries
  /// collapse to an empty result list rather than scanning the book.
  SetJumpSearchQuery(value: String)

  /// Reader tapped a row in the Jump Ahead search results. Delegates
  /// to the same code path as `JumpToPage` — the search results are
  /// just a different surface for the existing jump mechanism, and
  /// re-using `apply_jump_to_page` means lock-in / undo / engine
  /// pause / chapter-cache refresh all flow through one tested arm.
  SelectSearchResult(page_index: Int)

  /// Sentinel Msg variant used as the placeholder type parameter for
  /// `decode.failure` in event decoders that intentionally never
  /// dispatch — `stop_click_propagation` on overlay sheets, the
  /// `keydown` decoder's non-`Enter` arm in the Jump Ahead page
  /// input, etc. `decode.failure` always fails the decode and
  /// collapses the event, but its first parameter still has to be a
  /// real Msg value for the type checker; using a dedicated no-op
  /// variant rather than reusing a meaningful Msg makes the intent
  /// unambiguous to a future reader skimming the decoder.
  ///
  /// The reducer's `NoOp` arm is a unit-noop: returns the model
  /// unchanged and no effect. By construction, no dispatch site ever
  /// fires it; if a future change accidentally wires `NoOp` to a real
  /// event, the only visible behaviour is "the model holds steady",
  /// which is the safest possible failure mode for an accidental
  /// dispatch.
  NoOp
}
