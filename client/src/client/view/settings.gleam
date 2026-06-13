//// Settings overlay. Rendered as a fixed-position scrim wrapping a
//// bottom-sheet panel. The scrim itself catches taps that fall
//// outside the panel and closes the overlay — same as the close
//// button — so the reader can dismiss without aiming for a small
//// target. Inside, every row maps to one setting on the model.

import gleam/float
import gleam/int
import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{
  type Msg, ResetBookSettings, SetFontSize, SetGhostOpacity, SetLineSpacing,
  SetMode, SetPageDelay, SetParagraphDelay, SetWpm, ToggleDarkMode,
  ToggleDyslexiaFont, ToggleGhostMode, ToggleSettings,
}
import client/state.{
  type Model, Manual, Reader, RealTime, max_font_size, max_ghost_opacity,
  max_line_spacing, max_page_delay_ms, max_paragraph_delay_ms, max_wpm,
  min_font_size, min_ghost_opacity, min_line_spacing, min_page_delay_ms,
  min_paragraph_delay_ms, min_wpm,
}
import client/types.{type BookSettings}
import client/view/overlay_helpers.{stop_click_propagation}
import client/view/random_delete

/// Render the settings overlay (scrim + sheet).
pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class("settings-overlay"),
      attribute.role("dialog"),
      attribute.aria_modal(True),
      attribute.aria_label("Reader settings"),
      // A click on the scrim — not the panel — closes the overlay.
      // The panel itself stops propagation via the inner click guard
      // below, so taps inside the panel never reach this listener.
      event.on_click(ToggleSettings),
    ],
    [view_settings_sheet(model)],
  )
}

/// Inner sheet for the settings panel. The sheet swallows click
/// events so taps inside it don't bubble up to the scrim's close
/// handler — without this guard, every slider drag and toggle press
/// would also close the panel. The propagation guard is the shared
/// `overlay_helpers.stop_click_propagation` helper.
///
/// Visual structure (matching `mobile-reader-prototype.html`):
///
///   .sheet-handle                 — visual drag affordance
///   .settings-panel-header        — uppercase section title + close
///   pacing group
///     mode toggle
///     WPM / paragraph / page delay sliders
///   <hr> divider
///   appearance group
///     theme toggle
///     font / line-spacing sliders
///   <hr> divider
///   reading-aid group
///     ghost mode + opacity, dyslexia font
fn view_settings_sheet(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-panel"), stop_click_propagation()], [
    html.div(
      [
        attribute.class("settings-sheet-handle"),
        attribute.aria_hidden(True),
      ],
      [],
    ),
    view_settings_header(),
    view_mode_toggle(model),
    view_wpm_slider(model),
    view_paragraph_delay_slider(model),
    view_page_delay_slider(model),
    html.hr([attribute.class("settings-divider")]),
    view_theme_toggle(model),
    view_font_size_slider(model),
    view_line_spacing_slider(model),
    html.hr([attribute.class("settings-divider")]),
    view_ghost_mode_toggle(model),
    view_ghost_opacity_slider(model),
    view_dyslexia_font_toggle(model),
    random_delete.view_section(model),
    view_book_override_section(model),
  ])
}

/// Per-book override controls. Rendered only when the reader is in
/// the reader view with an active book id — the library view has no
/// per-book scope to attach a reset to. The visible section is a
/// single "Reset to default" button: every slider in the panel above
/// it already routes its writes through `persist_target`, so a
/// dedicated per-book editing surface would duplicate the existing
/// controls. The reset button collapses every override to `None`,
/// applies the global defaults to the four overridable fields, and
/// PUTs the cleared record so the server row drops its values.
///
/// The footer note explains the scoping — without it the reader
/// would have no way to tell that pacing edits made while reading
/// only affect this book.
fn view_book_override_section(model: Model) -> Element(Msg) {
  case model.view, model.active_book_id {
    Reader, Some(_) -> view_book_override_panel(model)
    _, _ -> element.none()
  }
}

fn view_book_override_panel(model: Model) -> Element(Msg) {
  let has_overrides = case model.book_settings {
    None -> False
    Some(s) -> book_settings_has_overrides(s)
  }
  html.div([attribute.class("settings-book-overrides")], [
    html.hr([attribute.class("settings-divider")]),
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Per-book overrides")]),
    ]),
    html.div([attribute.class("settings-row-hint")], [
      html.text(
        "Pacing and ghost opacity changes while reading apply to this book only.",
      ),
    ]),
    html.button(
      [
        attribute.class("btn-bar"),
        attribute.type_("button"),
        attribute.disabled(!has_overrides),
        attribute.aria_label("Reset book overrides to defaults"),
        event.on_click(ResetBookSettings),
      ],
      [html.text("Reset to default")],
    ),
  ])
}

fn book_settings_has_overrides(settings: BookSettings) -> Bool {
  option.is_some(settings.wpm)
  || option.is_some(settings.paragraph_delay_ms)
  || option.is_some(settings.page_delay_ms)
  || option.is_some(settings.ghost_opacity)
}

fn view_settings_header() -> Element(Msg) {
  html.div([attribute.class("settings-panel-header")], [
    html.h2([attribute.class("settings-panel-title")], [
      html.text("Reader settings"),
    ]),
    html.button(
      [
        attribute.class("settings-panel-close"),
        attribute.aria_label("Close settings"),
        attribute.type_("button"),
        event.on_click(ToggleSettings),
      ],
      [html.text("✕")],
    ),
  ])
}

fn view_theme_toggle(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Dark mode"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(model.dark_mode),
        event.on_check(fn(_checked) { ToggleDarkMode }),
      ]),
    ]),
  ])
}

fn view_ghost_mode_toggle(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Ghost mode"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(model.ghost_mode),
        event.on_check(fn(_checked) { ToggleGhostMode }),
      ]),
    ]),
  ])
}

fn view_dyslexia_font_toggle(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Dyslexia-friendly font"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(model.dyslexia_font),
        event.on_check(fn(_checked) { ToggleDyslexiaFont }),
      ]),
    ]),
  ])
}

fn view_font_size_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Font size")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(int.to_string(model.font_size) <> "px"),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(int.to_string(min_font_size)),
      attribute.max(int.to_string(max_font_size)),
      attribute.step("1"),
      attribute.value(int.to_string(model.font_size)),
      attribute.aria_label("Font size in pixels"),
      event.on_input(fn(value) {
        // `parse` returns `Result(Int, Nil)` — a slider always emits a
        // valid integer string, but on the off chance the browser
        // sends something garbled, fall back to the current model
        // value via the clamp in the reducer.
        case int.parse(value) {
          Ok(parsed) -> SetFontSize(parsed)
          Error(_) -> SetFontSize(model.font_size)
        }
      }),
    ]),
  ])
}

fn view_line_spacing_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Line spacing")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(float.to_string(model.line_spacing)),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(float.to_string(min_line_spacing)),
      attribute.max(float.to_string(max_line_spacing)),
      attribute.step("0.1"),
      attribute.value(float.to_string(model.line_spacing)),
      attribute.aria_label("Line spacing multiplier"),
      event.on_input(fn(value) {
        case float.parse(value) {
          Ok(parsed) -> SetLineSpacing(parsed)
          Error(_) -> SetLineSpacing(model.line_spacing)
        }
      }),
    ]),
  ])
}

fn view_mode_toggle(model: Model) -> Element(Msg) {
  // Checkbox semantics: unchecked → `Manual`, checked → `RealTime`.
  // The label reads as "Real-time fade mode" so the off state
  // (the default) reads as "the original tap/click reader" without
  // needing to name it explicitly. `event.on_check` carries the
  // new checkbox state, which maps directly to `Mode`.
  let checked = model.mode == RealTime
  html.div([attribute.class("settings-row")], [
    html.label([attribute.class("settings-toggle")], [
      html.span([attribute.class("settings-toggle-label")], [
        html.text("Real-time fade mode"),
      ]),
      html.input([
        attribute.class("settings-toggle-input"),
        attribute.type_("checkbox"),
        attribute.checked(checked),
        event.on_check(fn(is_on) {
          case is_on {
            True -> SetMode(RealTime)
            False -> SetMode(Manual)
          }
        }),
      ]),
    ]),
  ])
}

fn view_wpm_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Reading speed")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(int.to_string(model.wpm) <> " wpm"),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(int.to_string(min_wpm)),
      attribute.max(int.to_string(max_wpm)),
      attribute.step("10"),
      attribute.value(int.to_string(model.wpm)),
      attribute.aria_label("Words per minute"),
      event.on_input(fn(value) {
        case int.parse(value) {
          Ok(parsed) -> SetWpm(parsed)
          Error(_) -> SetWpm(model.wpm)
        }
      }),
    ]),
  ])
}

fn view_paragraph_delay_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Paragraph pause")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(int.to_string(model.paragraph_delay_ms) <> " ms"),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(int.to_string(min_paragraph_delay_ms)),
      attribute.max(int.to_string(max_paragraph_delay_ms)),
      attribute.step("100"),
      attribute.value(int.to_string(model.paragraph_delay_ms)),
      attribute.aria_label("Paragraph pause in milliseconds"),
      event.on_input(fn(value) {
        case int.parse(value) {
          Ok(parsed) -> SetParagraphDelay(parsed)
          Error(_) -> SetParagraphDelay(model.paragraph_delay_ms)
        }
      }),
    ]),
  ])
}

fn view_page_delay_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Page pause")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(int.to_string(model.page_delay_ms) <> " ms"),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(int.to_string(min_page_delay_ms)),
      attribute.max(int.to_string(max_page_delay_ms)),
      attribute.step("100"),
      attribute.value(int.to_string(model.page_delay_ms)),
      attribute.aria_label("Page pause in milliseconds"),
      event.on_input(fn(value) {
        case int.parse(value) {
          Ok(parsed) -> SetPageDelay(parsed)
          Error(_) -> SetPageDelay(model.page_delay_ms)
        }
      }),
    ]),
  ])
}

fn view_ghost_opacity_slider(model: Model) -> Element(Msg) {
  html.div([attribute.class("settings-row")], [
    html.div([attribute.class("settings-row-header")], [
      html.span([], [html.text("Ghost opacity")]),
      html.span([attribute.class("settings-row-value")], [
        html.text(float.to_string(model.ghost_opacity)),
      ]),
    ]),
    html.input([
      attribute.class("settings-slider"),
      attribute.type_("range"),
      attribute.min(float.to_string(min_ghost_opacity)),
      attribute.max(float.to_string(max_ghost_opacity)),
      attribute.step("0.01"),
      attribute.value(float.to_string(model.ghost_opacity)),
      attribute.aria_label("Ghost mode opacity"),
      event.on_input(fn(value) {
        case float.parse(value) {
          Ok(parsed) -> SetGhostOpacity(parsed)
          Error(_) -> SetGhostOpacity(model.ghost_opacity)
        }
      }),
    ]),
  ])
}
