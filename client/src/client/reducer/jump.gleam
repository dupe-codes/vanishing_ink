//// Reducer arms for the Jump Ahead surface: open / close the modal,
//// jump-to-page (raw page number from the numeric input), jump-to-
//// chapter (resolved against the cached `chapter_entries`), lock in
//// the jump (bulk-vanish every word on pages before the new
//// `current_page` and clear the preview), and undo the jump (restore
//// `current_page`, `engine_state`, and `next_word_index` from the
//// stashed `JumpPreview`).
////
//// **Engine invariant.** The engine in `client/engine` panics if
//// `engine_state == Running` and `next_word_index == None` (see the
//// `Running, None` arm in `apply_advance_word`). Every transition
//// here pauses the engine *before* mutating page state, then restores
//// the prior engine state on lock-in or undo. The Pause-during-
//// preview window is therefore the only state the model occupies
//// while `current_page` differs from the engine's pre-jump anchor,
//// and the panic invariant can never fire from this path.
////
//// **Save discipline.** `apply_jump_to_page` deliberately does *not*
//// chain `save_reading_state`: the reader is previewing, not
//// committing, and a save during preview would persist a position
//// they may yet undo. The save fires on `apply_lock_in_jump`, paired
//// with the bulk word-bitset update so the server learns about the
//// new page and the freshly-vanished words in one PUT.
////
//// The save-gate is reinforced inside `save_reading_state` itself —
//// see `should_save_reading_state` in `client/effects.gleam`. Any
//// reducer arm reachable during preview (touch / vim-key erase,
//// settings sliders, `GoToLibrary`, the engine's page-cross tick)
//// chains a save unconditionally; the central predicate short-
//// circuits it while `jump_preview: Some(_)`, so the discipline
//// here does not have to be reified at every dispatch site.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import lustre/effect.{type Effect}

import client/effects.{measure_lines_after_paint, save_reading_state}
import client/msg.{type Msg}
import client/pagination.{type Page}
import client/state.{type Model, JumpPreview, Model, Paused, Running, Stopped}
import client/state/helpers.{
  change_page, compute_chapter_entries, compute_current_chapter_title,
}

/// Flip `Model.jump_menu_open`. Closing the menu does not touch
/// `jump_preview` — a reader who closes the menu while previewing
/// stays on the previewed page until they tap Lock In or Go Back on
/// the preview banner.
///
/// Clears `jump_page_input` on every toggle so a half-typed value
/// from a prior open does not pre-populate the field next time, and
/// a value the reader just submitted does not linger as visible
/// chrome after the menu closes.
pub fn apply_toggle_jump_menu(model: Model) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..model,
      jump_menu_open: !model.jump_menu_open,
      jump_page_input: "",
    ),
    effect.none(),
  )
}

/// Controlled change of the Jump Ahead menu's page-input field.
/// Stores the raw string so the input can echo "12" while the
/// reader is mid-typing rather than the parsed Int, which would
/// round-trip badly on partial input.
pub fn apply_set_jump_page_input(
  model: Model,
  value: String,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, jump_page_input: value), effect.none())
}

/// Submit the Jump Ahead menu's page-input field. Reads the stored
/// `jump_page_input`, parses it as a 1-based page number, and
/// delegates to `apply_jump_to_page` after converting to the
/// 0-based reducer surface. Invalid / empty / out-of-range inputs
/// collapse to a no-op — the reducer guards in `apply_jump_to_page`
/// are the authority.
pub fn apply_submit_jump_page(model: Model) -> #(Model, Effect(Msg)) {
  case int.parse(model.jump_page_input) {
    Error(_) -> #(model, effect.none())
    Ok(one_based) -> apply_jump_to_page(model, one_based - 1)
  }
}

/// Jump to a specific page index. Rejects targets at or before the
/// current page so the modal cannot violate the app-wide forward-
/// only navigation invariant.
///
/// On success: stash the pre-jump position, pause the fade engine,
/// advance the page, close the menu, and chain a line-measurement so
/// the active-line overlay re-anchors on the new page.
pub fn apply_jump_to_page(
  model: Model,
  page_index: Int,
) -> #(Model, Effect(Msg)) {
  case page_index <= model.current_page || page_index >= model.total_pages {
    True -> #(model, effect.none())
    False -> {
      let preview =
        JumpPreview(
          source_page: model.current_page,
          prior_engine_state: model.engine_state,
          prior_next_word_index: model.next_word_index,
        )
      // Pause the engine *before* moving the page so the model never
      // sits in the `Running, None` shape the engine panics on. The
      // post-jump page may have no eligible words for the engine's
      // current `next_word_index`, so we also clear the pointer here
      // and leave it to lock-in / undo to restore a valid one.
      let paused =
        Model(
          ..model,
          engine_state: Paused,
          next_word_index: None,
          jump_preview: Some(preview),
          jump_menu_open: False,
        )
      let advanced = change_page(paused, page_index)
      // Clear the cached line geometry on a real page change — the
      // overlay anchors to the new page's word spans, not the old
      // page's coordinates. Mirrors `apply_next_page`'s cross-page
      // cleanup. `change_page` already refreshed `chapter_entries`
      // against the new page so the menu drops chapters now behind
      // the reader on its next open.
      let with_cleared_overlay =
        Model(..advanced, line_boxes: [], active_line: None)
      #(with_cleared_overlay, measure_lines_after_paint())
    }
  }
}

/// Look up the chapter by its stable `Chapter.index` and delegate to
/// `apply_jump_to_page`. A no-op when the index has no entry — the
/// menu only renders forward chapters, and a stale tap (chapter
/// dropped on a re-pagination after the menu opened) collapses to no
/// action rather than crashing.
///
/// The lookup is by `chapter_index`, not by list position. If the
/// engine ticks or a re-pagination drops earlier entries between
/// paint and tap, the row the reader saw as "Chapter Two" still
/// resolves to chapter 2 — whichever position chapter 2 now occupies
/// in `chapter_entries` — rather than landing them on whatever
/// chapter currently sits at the same list index. A stable identity
/// also means a chapter that has already been passed and removed
/// from the cache simply collapses to no action.
pub fn apply_jump_to_chapter(
  model: Model,
  chapter_index: Int,
) -> #(Model, Effect(Msg)) {
  case entry_for_chapter_index(model.chapter_entries, chapter_index) {
    None -> #(model, effect.none())
    Some(entry) -> apply_jump_to_page(model, entry.page_index)
  }
}

/// Lock in the in-flight jump. Bulk-vanish every word on pages
/// strictly before `current_page` (those pages have been "read" by
/// skipping past them), drop the preview snapshot, restore the
/// engine state captured in the preview, and chain a save so the
/// server picks up the new position and the new word bitset.
///
/// The save chain depends on `jump_preview: None` being written
/// *before* the effect is constructed — `save_reading_state`'s gate
/// (`should_save_reading_state` in `client/effects.gleam`) blocks the
/// PUT whenever `jump_preview: Some(_)`. The `restored` model has the
/// preview cleared, so the save fires; building the effect off the
/// pre-clear `model` would silently collapse to `effect.none()`.
///
/// Restoring the engine state runs through `restore_engine_after_jump`
/// so a `Running` snapshot lands on a valid `next_word_index` instead
/// of re-introducing the `Running, None` invariant violation.
pub fn apply_lock_in_jump(model: Model) -> #(Model, Effect(Msg)) {
  case model.jump_preview {
    None -> #(model, effect.none())
    Some(preview) -> {
      let vanished_words =
        words_before_page(model.pages, model.current_page)
        |> set.union(model.erased_words, _)
      let restored =
        restore_engine_after_jump(
          Model(..model, erased_words: vanished_words, jump_preview: None),
          preview,
        )
      #(restored, save_reading_state(restored))
    }
  }
}

/// Undo the in-flight jump. Restores the pre-jump page, engine
/// state, and `next_word_index`, drops the preview snapshot, and
/// chains a line-measurement so the active-line overlay re-anchors
/// to the restored page. No save fires — the reading position is
/// unchanged from before the jump.
pub fn apply_undo_jump(model: Model) -> #(Model, Effect(Msg)) {
  case model.jump_preview {
    None -> #(model, effect.none())
    Some(preview) -> {
      // `change_page` rejects backward navigation, so a direct call
      // would no-op here. Bypass the helper and reseat the page
      // index plus the cached chapter title and chapter list
      // directly — undo is the explicit exception to the forward-
      // only rule, and the caches need to mirror whichever page is
      // now visible.
      //
      // Clamp defensively: the preview window is narrow but a
      // viewport-resize-driven re-pagination *during* preview can
      // shrink `pages` so the stashed `source_page` falls past the
      // new last page. Clamping closes that race rather than
      // landing the reader on an out-of-range `current_page`.
      let restored_page =
        pagination.clamp_page_index(preview.source_page, model.total_pages)
      let chapter_title =
        compute_current_chapter_title(model.text, model.pages, restored_page)
      let restored =
        Model(
          ..model,
          current_page: restored_page,
          current_chapter_title: chapter_title,
          engine_state: preview.prior_engine_state,
          next_word_index: preview.prior_next_word_index,
          jump_preview: None,
          line_boxes: [],
          active_line: None,
          chapter_entries: compute_chapter_entries(model.pages, restored_page),
        )
      #(restored, measure_lines_after_paint())
    }
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Collect every `Word.global_index` on pages with `index < limit`.
/// Returns the empty set when `limit <= 0`. Mirrors the traversal in
/// `engine.page_word_contexts` (page → paragraph → sentence → word)
/// so the bulk-vanish set is constructed from the same shape the
/// fade engine reads.
fn words_before_page(pages: List(Page), limit: Int) -> set.Set(Int) {
  pages
  |> list.filter(fn(page) { page.index < limit })
  |> list.flat_map(fn(page) { page.paragraphs })
  |> list.flat_map(fn(page_paragraph) { page_paragraph.paragraph.sentences })
  |> list.flat_map(fn(sentence) { sentence.words })
  |> list.map(fn(word) { word.global_index })
  |> set.from_list
}

/// Restore the engine to its pre-jump state after the page has
/// moved. The cases mirror the `EngineState` ADT:
///
/// * `Stopped` — clear `next_word_index`. The engine is dormant; the
///   prior pointer is meaningless on the new page.
/// * `Paused` — keep the preview's `prior_next_word_index`. A paused
///   engine never ticks, so a stale pointer is safe; a future
///   `ResumeFade` would either find an eligible word and continue,
///   or hit the `next_eligible_after` `None` arm and advance pages
///   naturally.
/// * `Running` — re-anchor the pointer to the first eligible word on
///   the now-current page. The engine panics on `Running, None`, so
///   leaving the prior pointer in place (which may not exist on the
///   current page) is unsafe.
///
/// The `Running` arm walks the page exactly the way the engine's
/// `apply_start_fade` does (`first_eligible_word`). When the new
/// page has no eligible word — every word on it is already in
/// `erased_words` after the bulk vanish, or its parent sentence is
/// in `erased` — the engine drops to `Stopped` so the
/// `Running, None` invariant is preserved.
fn restore_engine_after_jump(
  model: Model,
  preview: state.JumpPreview,
) -> Model {
  case preview.prior_engine_state {
    Stopped -> Model(..model, engine_state: Stopped, next_word_index: None)
    Paused ->
      Model(
        ..model,
        engine_state: Paused,
        next_word_index: preview.prior_next_word_index,
      )
    Running ->
      case first_eligible_word(model) {
        Some(idx) ->
          Model(..model, engine_state: Running, next_word_index: Some(idx))
        None -> Model(..model, engine_state: Stopped, next_word_index: None)
      }
  }
}

/// First eligible word on `model.current_page` — not in
/// `erased_words` and parent sentence not in `erased`. Mirrors the
/// engine's `first_eligible_word_on_current_page` (kept local rather
/// than threading a public helper across modules to avoid a circular
/// import from reducer → engine through state/helpers).
fn first_eligible_word(model: Model) -> option.Option(Int) {
  case pagination.nth(model.pages, model.current_page) {
    None -> None
    Some(page) ->
      page.paragraphs
      |> list.flat_map(fn(page_paragraph) { page_paragraph.paragraph.sentences })
      |> list.flat_map(fn(sentence) {
        list.map(sentence.words, fn(word) {
          #(word.global_index, sentence.global_index)
        })
      })
      |> list.find(fn(pair) {
        let #(word_idx, sentence_idx) = pair
        !set.contains(model.erased_words, word_idx)
        && !set.contains(model.erased, sentence_idx)
      })
      |> option.from_result
      |> option.map(fn(pair) { pair.0 })
  }
}

/// Find the entry for the given segmenter-stable chapter index.
/// Returns `None` when no entry carries that chapter — the chapter
/// is either behind the reader (dropped from the forward-only cache)
/// or untitled (and so was never added to the cache).
fn entry_for_chapter_index(
  entries: List(state.ChapterEntry),
  chapter_index: Int,
) -> option.Option(state.ChapterEntry) {
  list.find(entries, fn(entry) { entry.chapter_index == chapter_index })
  |> option.from_result
}
