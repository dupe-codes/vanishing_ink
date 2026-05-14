//// Real-time fade engine. Implements the WPM-paced timer that fades
//// individual words on the current page, advances across page
//// boundaries, and recomputes the active-line overlay's anchor on
//// every tick.
////
//// The engine is a three-state machine: `Stopped`, `Running`, `Paused`.
//// Transitions:
////
////   Stopped --StartFade-->         Running  (find first eligible word,
////                                            schedule first tick)
////   Running --AdvanceWord-->       Running  (fade current, schedule next)
////                          \
////                           \-->   Stopped  (no more words; engine done)
////   Running --PauseFade-->         Paused   (clear timer, keep next index)
////   Paused  --ResumeFade-->        Running  (schedule next tick at WPM)
////   *       --SetMode(Manual)-->   Stopped  (mode switch always halts)
////
//// There is no user-facing `StopFade` Msg: the engine reaches
//// `Stopped` either through `SetMode(Manual)` (the back arrow on
//// the reader header) or through document exhaustion in
//// `advance_to_next_page_loop`. The internal `apply_stop_fade`
//// helper is the implementation of that second path; the previous
//// revision also exposed a `StopFade` Msg variant that had no view
//// dispatcher, which left a reducer arm reachable only from tests.
//// The variant was removed when no UI affordance materialised for
//// it; if a future design wants an explicit "Stop" button distinct
//// from "leave RealTime mode," reintroduce the Msg and route it
//// through `apply_stop_fade`.
////
//// The FFI's single-slot word timer is the runtime authority on
//// "is there a timer in flight": every transition that should kill
//// the timer calls `ffi.clear_word_timer`, every transition that
//// schedules one calls `ffi.start_word_timer`. `AdvanceWord` also
//// guards on `engine_state == Running` so a stale tick that
//// somehow survives `clear_word_timer` (it shouldn't — the FFI is
//// synchronous) cannot mutate state behind a paused engine.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lustre/effect.{type Effect}

import client/effects.{
  measure_lines_after_paint, save_reading_state, schedule_advance_word,
}
import client/ffi
import client/msg.{type Msg}
import client/pagination.{type Page}
import client/state.{
  type LineBox, type Model, Model, Paused, Running, Stopped, go_to_page,
  ms_per_minute,
}

// ---------------------------------------------------------------------------
// WordContext (private)
// ---------------------------------------------------------------------------

/// Reading-order context for a single word inside the current
/// page. Carries the word's global index alongside its enclosing
/// paragraph and sentence indices so the engine can detect
/// paragraph boundaries (for the inter-paragraph delay) and skip
/// words whose parent sentence has already been manually erased.
type WordContext {
  WordContext(
    word_global_index: Int,
    paragraph_global_index: Int,
    sentence_global_index: Int,
  )
}

// ---------------------------------------------------------------------------
// Engine transitions
// ---------------------------------------------------------------------------

pub fn apply_start_fade(model: Model) -> #(Model, Effect(Msg)) {
  case first_eligible_word_on_current_page(model) {
    None -> #(model, effect.none())
    Some(ctx) -> {
      let with_next =
        Model(
          ..model,
          engine_state: Running,
          next_word_index: Some(ctx.word_global_index),
        )
      // Resolve the active line against the in-memory boxes from the
      // last layout pass. The overlay therefore renders correctly on
      // the first frame after Start, even when no `LinesMeasured`
      // tick has fired yet for this run (the boxes are still valid
      // because the page hasn't reflowed).
      let started =
        Model(..with_next, active_line: resolve_active_line(with_next))
      #(started, schedule_advance_word(word_interval_ms(model.wpm)))
    }
  }
}

pub fn apply_pause_fade(model: Model) -> #(Model, Effect(Msg)) {
  case model.engine_state {
    Running -> {
      let paused = Model(..model, engine_state: Paused)
      #(
        paused,
        effect.batch([
          effect.from(fn(_dispatch) { ffi.clear_word_timer() }),
          // Pause is a natural save point — the engine has burned
          // through a stretch of words since the last save, and the
          // reader is about to look away. Re-running the save here
          // catches the word-bitset progress that `AdvanceWord`
          // deliberately skips on every tick.
          save_reading_state(paused),
        ]),
      )
    }
    _ -> #(model, effect.none())
  }
}

pub fn apply_resume_fade(model: Model) -> #(Model, Effect(Msg)) {
  case model.engine_state {
    Paused -> #(
      Model(..model, engine_state: Running),
      schedule_advance_word(word_interval_ms(model.wpm)),
    )
    _ -> #(model, effect.none())
  }
}

pub fn apply_stop_fade(model: Model) -> #(Model, Effect(Msg)) {
  let stopped =
    // `active_line: None` so the overlay disappears when the engine
    // halts — there's no active word for it to track. Keeping the
    // last position visible across a Stop would mislead the reader
    // about where the engine is (which is "nowhere").
    Model(
      ..model,
      engine_state: Stopped,
      next_word_index: None,
      active_line: None,
    )
  #(
    stopped,
    effect.batch([
      effect.from(fn(_dispatch) { ffi.clear_word_timer() }),
      // End-of-book save: the engine has consumed every remaining
      // word and is shutting down. Flush the final `erased_words`
      // state so a page reload after engine exhaustion lands the
      // reader on the same last page rather than rewinding to the
      // last cross-page save.
      save_reading_state(stopped),
    ]),
  )
}

/// Process one tick of the fade engine. Guarded against stale
/// ticks: when the engine is not `Running`, the tick is a no-op.
/// Otherwise, marks the current `next_word_index` as faded,
/// resolves the next target (next eligible word on the current
/// page, or the first eligible word on the next page when this
/// page is exhausted), and schedules the next tick at the
/// appropriate delay. When no eligible word remains anywhere
/// after the current page, the engine stops.
///
/// `Running, None` is treated as an invariant violation rather
/// than a silent no-op: the `Model` header guarantees that
/// `Running` carries `Some(_)` in `next_word_index`, and any
/// path that produces the inverse is a reducer bug that should
/// fail loudly at its source rather than propagate as a phantom-
/// tick no-op.
pub fn apply_advance_word(model: Model) -> #(Model, Effect(Msg)) {
  case model.engine_state, model.next_word_index {
    Running, Some(current_idx) -> advance_with_current(model, current_idx)
    Running, None ->
      panic as "apply_advance_word: Running engine must carry Some(next_word_index)"
    Stopped, _ -> #(model, effect.none())
    Paused, _ -> #(model, effect.none())
  }
}

fn advance_with_current(
  model: Model,
  current_idx: Int,
) -> #(Model, Effect(Msg)) {
  let faded =
    Model(..model, erased_words: set.insert(model.erased_words, current_idx))
  case next_eligible_after(faded, current_idx) {
    Some(#(next_ctx, crosses_paragraph)) -> {
      let delay = case crosses_paragraph {
        True -> word_interval_ms(faded.wpm) + faded.paragraph_delay_ms
        False -> word_interval_ms(faded.wpm)
      }
      let with_next =
        Model(..faded, next_word_index: Some(next_ctx.word_global_index))
      // The line boxes don't shift on a within-page tick (the page
      // hasn't reflowed), so the existing `line_boxes` is still
      // valid — re-resolving the active line against them moves
      // the overlay between rows as the engine crosses lines.
      let scheduled =
        Model(..with_next, active_line: resolve_active_line(with_next))
      #(scheduled, schedule_advance_word(delay))
    }
    None -> advance_to_next_page(faded)
  }
}

/// Move the engine onto the next page when the current page is
/// exhausted. Walks forward through the remaining pages until one
/// with at least one eligible word is found; stops the engine when
/// no such page exists. Uses `go_to_page` for the page change so
/// the existing forward-only navigation invariant is preserved
/// and the focused-sentence cursor (if any) follows along.
fn advance_to_next_page(model: Model) -> #(Model, Effect(Msg)) {
  // Read the cached `total_pages` rather than recomputing
  // `list.length(model.pages)`. The Model invariant guarantees the
  // two are equal, and reading the cache here matches the pattern
  // the view path already uses — leaving a single canonical source
  // of truth for "how many pages does this model have".
  advance_to_next_page_loop(model, model.current_page + 1, model.total_pages)
}

fn advance_to_next_page_loop(
  model: Model,
  candidate: Int,
  total: Int,
) -> #(Model, Effect(Msg)) {
  case candidate >= total {
    True -> apply_stop_fade(model)
    False -> {
      let on_page = go_to_page(model, candidate)
      case first_eligible_word_on_current_page(on_page) {
        Some(ctx) -> {
          // Cross-page tick: the page reflow means the existing
          // `line_boxes` no longer describe the visible page.
          // Clear them and clear `active_line` so the overlay
          // disappears for the one frame between the page render
          // and the next `LinesMeasured`. `measure_lines_after_paint`
          // is batched into the effect chain so the overlay
          // re-emerges on the new line as soon as the fresh
          // geometry lands.
          let scheduled =
            Model(
              ..on_page,
              next_word_index: Some(ctx.word_global_index),
              line_boxes: [],
              active_line: None,
            )
          #(
            scheduled,
            effect.batch([
              schedule_advance_word(on_page.page_delay_ms),
              measure_lines_after_paint(),
              // The engine just consumed a full page of words and is
              // crossing into a new one. This is the debounce point
              // for real-time fade saves: the per-tick `AdvanceWord`
              // path deliberately skips persistence, so the
              // page-boundary tick is what flushes the accumulated
              // `erased_words` progress to the server alongside the
              // updated `current_page`.
              save_reading_state(scheduled),
            ]),
          )
        }
        None -> advance_to_next_page_loop(on_page, candidate + 1, total)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Word eligibility / scanning
// ---------------------------------------------------------------------------

/// Resolve the fade engine's first target on the current page.
/// "Eligible" means the word is not in `erased_words` and its
/// parent sentence is not in `erased`. Returns `None` when every
/// word on the current page is hidden — the engine treats this
/// as an empty page and either does not start (from
/// `apply_start_fade`) or advances past it (from
/// `advance_to_next_page`).
fn first_eligible_word_on_current_page(model: Model) -> Option(WordContext) {
  case pagination.nth(model.pages, model.current_page) {
    None -> None
    Some(page) ->
      page
      |> page_word_contexts
      |> list.find(fn(ctx) {
        is_word_visible(ctx, model.erased_words, model.erased)
      })
      |> option.from_result
  }
}

/// Find the next eligible word strictly after `current_idx` in
/// document order on the current page. Returns the target context
/// alongside a `Bool` that's `True` when the next word lives in a
/// different paragraph than the just-faded word — the caller uses
/// that flag to add the inter-paragraph delay to the schedule.
///
/// Implemented as a single forward scan over `page_word_contexts`:
/// the previous two-pass form (one `list.find` to resolve
/// `current_paragraph`, then a `drop_through_word` + second
/// `list.find` to skip past `current_idx`) walked the list twice
/// per tick — ~400 list-element visits at 200-word pages and
/// 200 WPM. The fused scan captures the current word's paragraph
/// when it passes through it and continues looking for the next
/// eligible word in the same traversal.
fn next_eligible_after(
  model: Model,
  current_idx: Int,
) -> Option(#(WordContext, Bool)) {
  case pagination.nth(model.pages, model.current_page) {
    None -> None
    Some(page) ->
      scan_for_next_eligible(
        page_word_contexts(page),
        current_idx,
        None,
        model.erased_words,
        model.erased,
      )
  }
}

/// Tail-recursive helper for `next_eligible_after`. `current_paragraph`
/// carries the just-faded word's paragraph index once the scan has
/// passed it, and stays `None` until then. The arm split is therefore
/// "before / at / after the current word":
///
/// * `None` + non-match → keep walking, current word not yet seen.
/// * `None` + match → capture this element's paragraph and skip it.
/// * `Some(_)` + visible → return as the next eligible target along
///   with the crosses-paragraph flag.
/// * `Some(_)` + erased → keep walking.
///
/// If the scan exhausts the list without ever finding `current_idx`,
/// the result is `None` — the caller treats that as a "page
/// exhausted" signal and walks forward to the next page.
fn scan_for_next_eligible(
  contexts: List(WordContext),
  current_idx: Int,
  current_paragraph: Option(Int),
  erased_words: Set(Int),
  erased_sentences: Set(Int),
) -> Option(#(WordContext, Bool)) {
  case contexts, current_paragraph {
    [], _ -> None
    [ctx, ..rest], None ->
      case ctx.word_global_index == current_idx {
        True ->
          scan_for_next_eligible(
            rest,
            current_idx,
            Some(ctx.paragraph_global_index),
            erased_words,
            erased_sentences,
          )
        False ->
          scan_for_next_eligible(
            rest,
            current_idx,
            None,
            erased_words,
            erased_sentences,
          )
      }
    [ctx, ..rest], Some(captured_paragraph) ->
      case is_word_visible(ctx, erased_words, erased_sentences) {
        True -> Some(#(ctx, ctx.paragraph_global_index != captured_paragraph))
        False ->
          scan_for_next_eligible(
            rest,
            current_idx,
            Some(captured_paragraph),
            erased_words,
            erased_sentences,
          )
      }
  }
}

/// Flatten one page into reading-order word contexts. Iteration
/// is `page.paragraphs[].paragraph.sentences[].words[]` —
/// document order matches the Word.global_index sequence the
/// segmenter assigned at build time.
fn page_word_contexts(page: Page) -> List(WordContext) {
  page.paragraphs
  |> list.flat_map(fn(page_paragraph) {
    page_paragraph.paragraph.sentences
    |> list.flat_map(fn(sentence) {
      sentence.words
      |> list.map(fn(word) {
        WordContext(
          word_global_index: word.global_index,
          paragraph_global_index: page_paragraph.global_index,
          sentence_global_index: sentence.global_index,
        )
      })
    })
  })
}

/// A word is visible when neither its own bitset entry nor its
/// parent sentence's entry is set. Shared between the engine's
/// eligibility search and the view's render path so the two
/// stay in lock-step.
fn is_word_visible(
  ctx: WordContext,
  erased_words: Set(Int),
  erased_sentences: Set(Int),
) -> Bool {
  !set.contains(erased_words, ctx.word_global_index)
  && !set.contains(erased_sentences, ctx.sentence_global_index)
}

/// Words-per-minute → per-word delay in milliseconds. Integer
/// division — the residual fractional millisecond is sub-frame
/// at every realistic WPM and would not be observable in the
/// rendered fade.
fn word_interval_ms(wpm: Int) -> Int {
  ms_per_minute / wpm
}

// ---------------------------------------------------------------------------
// Line geometry
// ---------------------------------------------------------------------------

/// Resolve the line index whose word range contains `word_global_index`.
/// Returns `None` when the boxes list is empty (mid-measurement) or
/// when the word index falls outside every measured range (a manual
/// erasure or page turn between measurement and lookup). The lookup
/// is `O(lines)` because the line count per page is small — typically
/// 20-40 — and the alternative (binary search) would carry more
/// complexity than it saves at these magnitudes.
///
/// Implemented as a single-pass tail-recursive scan with early exit
/// on first match. The previous `index_map |> find |> result.map`
/// pipeline materialised an intermediate `List(#(Int, LineBox))`
/// before searching it — the same logic in one pass with no
/// intermediate allocation.
pub fn line_index_for_word(
  boxes: List(LineBox),
  word_global_index: Int,
) -> Option(Int) {
  scan_lines_for_word(boxes, word_global_index, 0)
}

fn scan_lines_for_word(
  boxes: List(LineBox),
  word_global_index: Int,
  index: Int,
) -> Option(Int) {
  case boxes {
    [] -> None
    [box, ..rest] ->
      case
        box.first_word_gi <= word_global_index
        && word_global_index <= box.last_word_gi
      {
        True -> Some(index)
        False -> scan_lines_for_word(rest, word_global_index, index + 1)
      }
  }
}

/// Resolve the active line for the current `next_word_index` against
/// the current `line_boxes`. Returns `None` when the engine has no
/// target or no boxes are available; otherwise returns the index of
/// the line that contains the target word. Pulled out so every
/// reducer arm that touches `next_word_index` or `line_boxes` reads
/// the same lookup and the two fields stay in lock-step.
pub fn resolve_active_line(model: Model) -> Option(Int) {
  case model.next_word_index, model.line_boxes {
    None, _ -> None
    _, [] -> None
    Some(idx), boxes -> line_index_for_word(boxes, idx)
  }
}
