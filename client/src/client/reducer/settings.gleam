//// Settings setters plus the persist-target machinery they share.
//// Owns every `apply_set_*` / `apply_toggle_*` helper for the
//// eight wire-form `UserSettings` fields, plus the
//// `apply_set_mode` mode toggle, the deliberately-unpersisted
//// `apply_toggle_dyslexia_font`, and `apply_reset_book_settings`.
//// The `effective_*` helpers are `pub` because
//// `client/reducer/settings_load` reads them when merging an
//// in-flight GET response against the active book's overrides.

import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import lustre/effect.{type Effect}

import client/effects.{
  repaginate_after_paint, save_book_settings, save_global_settings,
  save_reading_state,
}
import client/ffi
import client/msg.{type Msg}
import client/state.{
  type Mode, type Model, Manual, Model, Reader, RealTime, Stopped,
  body_class_dyslexia_font, body_class_ghost_mode, body_class_light_mode,
  css_var_font_size, css_var_ghost_opacity, css_var_line_height,
  empty_book_settings, max_font_size, max_ghost_opacity, max_line_spacing,
  max_page_delay_ms, max_paragraph_delay_ms, max_wpm, min_font_size,
  min_ghost_opacity, min_line_spacing, min_page_delay_ms, min_paragraph_delay_ms,
  min_wpm,
}
import client/state/helpers.{clamp_float, clamp_int}
import client/types.{
  type BookSettings, type UserSettings, BookSettings, UserSettings,
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

pub fn effective_wpm(
  overrides: Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(wpm: Some(v), ..)) -> v
    _ -> defaults.default_wpm
  }
}

pub fn effective_paragraph_delay(
  overrides: Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(paragraph_delay_ms: Some(v), ..)) -> v
    _ -> defaults.default_paragraph_delay_ms
  }
}

pub fn effective_page_delay(
  overrides: Option(BookSettings),
  defaults: UserSettings,
) -> Int {
  case overrides {
    Some(BookSettings(page_delay_ms: Some(v), ..)) -> v
    _ -> defaults.default_page_delay_ms
  }
}

pub fn effective_ghost_opacity(
  overrides: Option(BookSettings),
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

pub fn apply_toggle_dark_mode(model: Model) -> #(Model, Effect(Msg)) {
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

pub fn apply_set_font_size(model: Model, size: Int) -> #(Model, Effect(Msg)) {
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

pub fn apply_set_line_spacing(
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

pub fn apply_toggle_ghost_mode(model: Model) -> #(Model, Effect(Msg)) {
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

pub fn apply_set_ghost_opacity(
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

pub fn apply_set_wpm(model: Model, value: Int) -> #(Model, Effect(Msg)) {
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

pub fn apply_set_paragraph_delay(
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

pub fn apply_set_page_delay(model: Model, value: Int) -> #(Model, Effect(Msg)) {
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
pub fn apply_toggle_dyslexia_font(model: Model) -> #(Model, Effect(Msg)) {
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

/// Clear every per-book override for the current book. Writes an
/// all-null record to the server (which deletes the override row's
/// values), restores the four effective fields to the global
/// defaults, and updates `model.book_settings` to match. A no-op
/// when no book is loaded — the reader cannot dispatch this Msg
/// from the library view in practice (the UI only renders the
/// Reset button when reading), but the guard keeps the helper
/// total.
pub fn apply_reset_book_settings(model: Model) -> #(Model, Effect(Msg)) {
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
// Mode setter
// ---------------------------------------------------------------------------

/// Switch reading mode. Leaving `RealTime` halts the engine and
/// clears the timer; entering `RealTime` simply records the new
/// mode (the reader must press Space/tap to actually start the
/// engine).
pub fn apply_set_mode(model: Model, mode: Mode) -> #(Model, Effect(Msg)) {
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
