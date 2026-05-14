//// Vim-style keyboard cursor helpers. The cursor (`focused_sentence`)
//// is a desktop-only affordance — touch input never sets it — and
//// these helpers implement every keyboard-driven move: per-sentence
//// step (`focus_sentence_step`), per-paragraph step
//// (`focus_paragraph_step`), and the erase-and-advance composite
//// (`apply_erase_focused`). Sentence erasure is shared with the
//// touch/click path through `client/reducer/touch.apply_erase`.

import gleam/option.{None, Some}

import client/navigation
import client/reducer/touch.{apply_erase}
import client/state.{type Model, Model}
import client/state/helpers.{change_page}

/// Step the keyboard cursor by one sentence in `direction`,
/// crossing page boundaries when the next visible sentence lives
/// on a different page. When the cursor is dormant
/// (`focused_sentence: None`), the first press initialises focus
/// to the first non-erased sentence on the current page rather
/// than moving — the press wakes the cursor up.
pub fn focus_sentence_step(
  model: Model,
  direction: navigation.Direction,
) -> Model {
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
pub fn focus_paragraph_step(
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
pub fn apply_erase_focused(model: Model) -> Model {
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
