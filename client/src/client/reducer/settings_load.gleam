//// Handlers for the three GET-response messages that hydrate the
//// running model with server-side state: `SettingsLoaded`,
//// `BookSettingsLoaded`, and `ReadingStateLoaded`. Each helper takes
//// the decoded payload and reconciles it against the current model,
//// stamping the CSS cascade where the loaded value differs from
//// what the view is currently rendering. Stale-response guards live
//// here too — `apply_book_settings_loaded` and
//// `apply_reading_state_loaded` drop responses whose originating
//// `book_id` no longer matches `model.active_book_id`.

import gleam/float
import gleam/int
import gleam/option.{None, Some}
import gleam/set
import lustre/effect.{type Effect}

import client/effects.{decode_base64_to_indices, repaginate_after_paint}
import client/ffi
import client/msg.{type Msg}
import client/pagination
import client/reducer/settings.{
  effective_ghost_opacity, effective_page_delay, effective_paragraph_delay,
  effective_wpm,
}
import client/state.{
  type Model, Manual, Model, Reader, RealTime, body_class_ghost_mode,
  body_class_light_mode, css_var_font_size, css_var_ghost_opacity,
  css_var_line_height,
}
import client/state/helpers.{compute_chapter_entries}
import client/types.{type BookSettings, type ReadingState, type UserSettings}

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
pub fn apply_settings_loaded(
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
pub fn apply_book_settings_loaded(
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
///
/// SESSION SNAPSHOT RE-STAMP — `apply_book_loaded` opens the session
/// synchronously with `erased_words = set.new()` and `current_page = 0`
/// because the persisted state has not landed yet. Without intervention
/// here, the closing PUT would compute
/// `words_read = current_erased - 0 = saved_bitset_size + within_session_reads`
/// and `pages_turned = current_page - 0`, retroactively crediting every
/// previously-erased word and every page of resumed progress to this
/// session. When an active session is in flight for this book, re-stamp
/// `session_start_erased_count` to the freshly-loaded word-bitset size
/// and `session_start_page` to the resumed page so the deltas reflect
/// only the work done within the session.
pub fn apply_reading_state_loaded(
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
      let loaded_erased = decode_base64_to_indices(state.sentence_bitset)
      let loaded_erased_words = decode_base64_to_indices(state.word_bitset)
      // Refresh the forward-chapter cache against the resumed page.
      // Pagination may have already run on this book (the user
      // jumped back into a partially-paginated session), so the
      // existing `chapter_entries` would otherwise reflect the
      // pre-resume page=0 view of the menu rather than the
      // server's saved position.
      let chapter_entries = compute_chapter_entries(model.pages, target_page)
      // Re-stamp the session snapshots so the closing PUT computes
      // deltas against the resumed baseline rather than the pre-load
      // zeros captured by `apply_start_session` in `apply_book_loaded`.
      // The no-active-session branch leaves the snapshots untouched —
      // the visibility-change re-open path opens the next session
      // against an already-populated model, so its snapshots are
      // correct on first stamp.
      let #(restamped_start_page, restamped_start_erased_count) = case
        model.active_session_id
      {
        Some(_) -> #(target_page, set.size(loaded_erased_words))
        None -> #(model.session_start_page, model.session_start_erased_count)
      }
      #(
        Model(
          ..model,
          mode: mode,
          erased: loaded_erased,
          erased_words: loaded_erased_words,
          current_page: target_page,
          chapter_entries: chapter_entries,
          session_start_page: restamped_start_page,
          session_start_erased_count: restamped_start_erased_count,
        ),
        effect.none(),
      )
    }
    _, _ -> #(model, effect.none())
  }
}
