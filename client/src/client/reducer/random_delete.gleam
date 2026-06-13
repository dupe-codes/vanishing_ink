//// Random destructive deletion. The "exposure therapy" feature: a
//// subportion of text is deleted *before the reader reaches it* so they
//// sit with the discomfort of missing things. There is no timer and no
//// cadence — deletions are one-shot batches applied at well-defined
//// moments:
////
////   * page-per-page — a persistent toggle (`random_page_delete_on`).
////     While on, every page that loads (a turn, or the moment the
////     toggle flips on) immediately deletes a subportion of *that
////     page's* units. See `apply_page_deletion` and the
////     `apply_next_page` / swipe hooks in `client/reducer`.
////   * full-sweep — a one-shot action (`ApplyFullSweep`) that deletes a
////     subportion across the whole book at once. Once per book, ever.
////
//// **Determinism and idempotence.** The pick is computed from a fixed
//// per-book seed (derived from the book id, never the wall clock) over
//// the *full* candidate set in scope — NOT over the set of currently
//// visible units. Computing the count and the sample against the full,
//// erase-independent unit list is what makes re-applying a page's
//// deletion (e.g. on revisit, or after a re-pagination) reproduce the
//// identical pick: the same indices are re-written into the `erased` /
//// `erased_words` sets, which is a no-op against what is already there.
//// Filtering candidates by current visibility before sampling would
//// shrink the candidate set on every revisit, change the pick, and
//// reintroduce the compounding (revisits deleting more and more) the
//// determinism is designed to prevent. The selection helpers are pure
//// (seed in, index sets out) so the determinism is directly testable.
////
//// Rendering is free: writing a word's `global_index` into
//// `erased_words`, or a sentence's `global_index` into `erased`, hides
//// it via the existing opacity render path — no new view logic. Sentence
//// deletions mirror `reducer/touch.apply_erase`'s double-write (insert
//// into `erased` AND project the sentence's words into `erased_words`)
//// so session word-counts stay correct.

import gleam/list
import gleam/option.{Some}
import gleam/set.{type Set}
import lustre/effect.{type Effect}

import prng/random.{type Seed}

import client/effects.{save_reading_state}
import client/msg.{type Msg}
import client/pagination.{type Page}
import client/state.{
  type DeletionGranularity, type DeletionIntensity, type Model, DeletePhrase,
  DeleteSentence, DeleteWord, Model,
}
import shared/segmenter.{type SegmentedText}

/// Lower / upper bound on the phrase window — an N-consecutive-word slice
/// within a single sentence. `N` is a deterministic draw in
/// `[min_phrase_words, max_phrase_words]`, each bounded down to the
/// sentence's own word count so a short sentence yields a short phrase
/// and the window never runs past the sentence's end (and so never
/// crosses a sentence boundary).
const min_phrase_words: Int = 3

const max_phrase_words: Int = 7

/// One sentence's deletion candidate: its `global_index` and the
/// document-ordered `global_index` of every word it contains. The word
/// list is the *full* set (not filtered by current erase state) so the
/// deterministic pick is reproducible — see the module header.
pub type SentenceUnit {
  SentenceUnit(sentence_index: Int, word_indices: List(Int))
}

// ---------------------------------------------------------------------------
// Candidate enumeration
// ---------------------------------------------------------------------------

/// Enumerate one page's sentences as deletion units, in reading order.
pub fn page_units(page: Page) -> List(SentenceUnit) {
  page.paragraphs
  |> list.flat_map(fn(page_paragraph) {
    page_paragraph.paragraph.sentences
    |> list.map(sentence_unit)
  })
}

/// Enumerate the whole book's sentences as deletion units, in reading
/// order. Walks `text` directly — the full-sweep scope is the entire
/// document, not the current page.
pub fn book_units(text: SegmentedText) -> List(SentenceUnit) {
  text.chapters
  |> list.flat_map(fn(chapter) {
    chapter.paragraphs
    |> list.flat_map(fn(paragraph) {
      paragraph.sentences
      |> list.map(sentence_unit)
    })
  })
}

fn sentence_unit(sentence: segmenter.Sentence) -> SentenceUnit {
  SentenceUnit(
    sentence_index: sentence.global_index,
    word_indices: list.map(sentence.words, fn(word) { word.global_index }),
  )
}

// ---------------------------------------------------------------------------
// Pure selection
// ---------------------------------------------------------------------------

/// Delete a subportion of `units` at the given granularity and
/// intensity, folding the result into the supplied `erased` /
/// `erased_words` sets. Pure and deterministic: the same `seed_int` and
/// `units` always produce the same updated sets. Returns
/// `#(erased, erased_words)`.
pub fn delete_units(
  units: List(SentenceUnit),
  granularity: DeletionGranularity,
  intensity: DeletionIntensity,
  seed_int: Int,
  erased: Set(Int),
  erased_words: Set(Int),
) -> #(Set(Int), Set(Int)) {
  let seed = random.new_seed(seed_int)
  case granularity {
    DeleteWord -> delete_words(units, intensity, seed, erased, erased_words)
    DeleteSentence ->
      delete_sentences(units, intensity, seed, erased, erased_words)
    DeletePhrase -> delete_phrases(units, intensity, seed, erased, erased_words)
  }
}

fn delete_words(
  units: List(SentenceUnit),
  intensity: DeletionIntensity,
  seed: Seed,
  erased: Set(Int),
  erased_words: Set(Int),
) -> #(Set(Int), Set(Int)) {
  let candidates = list.flat_map(units, fn(unit) { unit.word_indices })
  let target = state.deletion_count(intensity, list.length(candidates))
  // `sample` is single-pass reservoir sampling — O(n) over the whole
  // book on a full sweep, which the codebase prefers over re-flattening
  // and re-picking per unit.
  let #(picked, _seed) = random.step(random.sample(candidates, target), seed)
  #(erased, list.fold(picked, erased_words, fn(acc, idx) { set.insert(acc, idx) }))
}

fn delete_sentences(
  units: List(SentenceUnit),
  intensity: DeletionIntensity,
  seed: Seed,
  erased: Set(Int),
  erased_words: Set(Int),
) -> #(Set(Int), Set(Int)) {
  let target = state.deletion_count(intensity, list.length(units))
  let #(picked, _seed) = random.step(random.sample(units, target), seed)
  list.fold(picked, #(erased, erased_words), fn(acc, unit) {
    let #(erased_acc, words_acc) = acc
    // Mirror `apply_erase`: insert the sentence AND project its words so
    // the session word-count reflects the sentence-level erase.
    let words_next =
      list.fold(unit.word_indices, words_acc, fn(words, idx) {
        set.insert(words, idx)
      })
    #(set.insert(erased_acc, unit.sentence_index), words_next)
  })
}

fn delete_phrases(
  units: List(SentenceUnit),
  intensity: DeletionIntensity,
  seed: Seed,
  erased: Set(Int),
  erased_words: Set(Int),
) -> #(Set(Int), Set(Int)) {
  // Only sentences with at least one word can host a phrase.
  let candidates = list.filter(units, fn(unit) { unit.word_indices != [] })
  let target = state.deletion_count(intensity, list.length(candidates))
  let #(picked, after_sample) =
    random.step(random.sample(candidates, target), seed)
  // Thread the seed through each picked sentence so every window draw is
  // deterministic and reproducible. The sample preserves list order, so
  // the threading order is itself deterministic across revisits.
  let #(words_next, _seed) =
    list.fold(picked, #(erased_words, after_sample), fn(acc, unit) {
      let #(words_acc, seed_acc) = acc
      let #(window, seed_after) = phrase_window(unit.word_indices, seed_acc)
      let words_with_window =
        list.fold(window, words_acc, fn(words, idx) { set.insert(words, idx) })
      #(words_with_window, seed_after)
    })
  #(erased, words_next)
}

/// Pick a deterministic N-consecutive-word window inside one sentence's
/// word list. Returns the window's word indices and the stepped seed.
fn phrase_window(words: List(Int), seed: Seed) -> #(List(Int), Seed) {
  let length = list.length(words)
  // Bound both ends of the window-length draw to the sentence: a
  // sentence shorter than `min_phrase_words` deletes its whole run, and
  // the upper bound never exceeds the sentence either.
  let lower = int_min(min_phrase_words, length)
  let upper = int_min(max_phrase_words, length)
  let #(window_length, seed_1) = random.step(random.int(lower, upper), seed)
  // `start` ranges over `[0, length - window_length]` so the window
  // stays inside the sentence.
  let #(start, seed_2) =
    random.step(random.int(0, length - window_length), seed_1)
  let window = words |> list.drop(start) |> list.take(window_length)
  #(window, seed_2)
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

// ---------------------------------------------------------------------------
// Reducer arms
// ---------------------------------------------------------------------------

/// Apply the current page's page-per-page deletion onto the model. A
/// no-op when the toggle is off, no book is active, or pagination has
/// not produced the current page yet. The per-page seed salts the book
/// seed with `current_page`, so each page deletes a different (but
/// stable) subportion. Pure model mutation — the caller chains the
/// `save_reading_state` effect.
pub fn apply_page_deletion(model: Model) -> Model {
  case
    model.random_page_delete_on,
    model.active_book_id,
    pagination.nth(model.pages, model.current_page)
  {
    True, Some(book_id), Some(page) -> {
      let seed = state.derive_deletion_seed(book_id, model.current_page)
      let #(erased, erased_words) =
        delete_units(
          page_units(page),
          model.deletion_granularity,
          model.deletion_intensity,
          seed,
          model.erased,
          model.erased_words,
        )
      Model(..model, erased: erased, erased_words: erased_words)
    }
    _, _, _ -> model
  }
}

/// Flip the page-per-page toggle. Turning it on immediately deletes from
/// the page already loaded; turning it off leaves prior deletions in
/// place and stops touching future pages. Persists either way.
pub fn apply_toggle_page_delete(model: Model) -> #(Model, Effect(Msg)) {
  let toggled =
    Model(..model, random_page_delete_on: !model.random_page_delete_on)
  let updated = case toggled.random_page_delete_on {
    True -> apply_page_deletion(toggled)
    False -> toggled
  }
  #(updated, save_reading_state(updated))
}

/// Record a new deletion granularity and persist it. Governs future
/// deletions only — prior deletions are permanent and unchanged.
pub fn apply_set_deletion_granularity(
  model: Model,
  granularity: DeletionGranularity,
) -> #(Model, Effect(Msg)) {
  let updated = Model(..model, deletion_granularity: granularity)
  #(updated, save_reading_state(updated))
}

/// Record a new deletion intensity and persist it. Governs future
/// deletions only.
pub fn apply_set_deletion_intensity(
  model: Model,
  intensity: DeletionIntensity,
) -> #(Model, Effect(Msg)) {
  let updated = Model(..model, deletion_intensity: intensity)
  #(updated, save_reading_state(updated))
}

/// Apply the one-shot full-sweep deletion across the whole book and lock
/// the once-per-book guard. A no-op (and no effect) when the sweep has
/// already run for this book, no text is loaded, or no book is active.
/// Persists the new erased sets and the guard together.
pub fn apply_full_sweep(model: Model) -> #(Model, Effect(Msg)) {
  case model.full_sweep_applied, model.text, model.active_book_id {
    False, Some(text), Some(book_id) -> {
      let seed = state.derive_deletion_seed(book_id, state.full_sweep_seed_salt)
      let #(erased, erased_words) =
        delete_units(
          book_units(text),
          model.deletion_granularity,
          model.deletion_intensity,
          seed,
          model.erased,
          model.erased_words,
        )
      let updated =
        Model(
          ..model,
          erased: erased,
          erased_words: erased_words,
          full_sweep_applied: True,
        )
      #(updated, save_reading_state(updated))
    }
    _, _, _ -> #(model, effect.none())
  }
}
