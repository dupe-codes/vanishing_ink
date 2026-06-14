//// Random destructive deletion — wire vocabulary, seed derivation, and
//// intensity mapping. Extracted from `client/state` so that module
//// stays within the file budget: the `DeletionGranularity` /
//// `DeletionIntensity` *types* stay in `state` by type-gravity (the
//// `Model` carries them), but these pure helper *functions* form their
//// own cohesive surface — the closed string vocabulary the reading-state
//// wire round-trips through, plus the deterministic seed/count maths the
//// reducer's selection logic depends on — and do not have to live beside
//// the central state record.
////
//// The conversions live in one place so the encode side
//// (`effects.save_reading_state`) and the decode side
//// (`settings_load.apply_reading_state_loaded`) share one source of
//// truth and a rename surfaces as a compile error rather than a silent
//// drift. This module imports the types from `client/state` and is
//// imported by `effects`, `reducer/settings_load`, and
//// `reducer/random_delete`; `state` never imports it, so no cycle forms.

import gleam/int
import gleam/list
import gleam/string

import client/state.{
  type DeletionGranularity, type DeletionIntensity, DeletePhrase, DeleteSentence,
  DeleteWord, High, Low, Medium,
}

/// Salt mixed into the per-book seed for the full-sweep action so its
/// pick does not correlate with any single page's page-per-page pick.
/// A prime chosen to be far outside any realistic `page_index` range —
/// page-per-page salts with the raw page index, so a distinct constant
/// keeps the two affordances' RNG streams independent on the same book.
pub const full_sweep_seed_salt: Int = 2_654_435_761

/// Modulus bounding the derived seed into a 31-bit range. Keeps the
/// fold below inside JavaScript's safe-integer range on every step
/// (the JS target represents `Int` as a 64-bit float) so the same seed
/// is produced on both the Erlang and JS backends — the determinism
/// the feature's tests depend on.
const seed_modulus: Int = 2_147_483_647

pub fn deletion_granularity_to_wire(
  granularity: DeletionGranularity,
) -> String {
  case granularity {
    DeleteWord -> "word"
    DeletePhrase -> "phrase"
    DeleteSentence -> "sentence"
  }
}

/// Inverse of `deletion_granularity_to_wire`. Unknown values fall back
/// to `DeleteWord` so a future wire-vocabulary expansion (or a row that
/// predates a value) cannot strand the reader on an undecodable
/// granularity — the same defensive shape `ReadingState.mode` uses.
pub fn deletion_granularity_from_wire(value: String) -> DeletionGranularity {
  case value {
    "phrase" -> DeletePhrase
    "sentence" -> DeleteSentence
    _ -> DeleteWord
  }
}

pub fn deletion_intensity_to_wire(intensity: DeletionIntensity) -> String {
  case intensity {
    Low -> "low"
    Medium -> "medium"
    High -> "high"
  }
}

/// Inverse of `deletion_intensity_to_wire`. Unknown values fall back to
/// `Low` — the gentlest setting — for the same reason
/// `deletion_granularity_from_wire` falls back to `DeleteWord`.
pub fn deletion_intensity_from_wire(value: String) -> DeletionIntensity {
  case value {
    "medium" -> Medium
    "high" -> High
    _ -> Low
  }
}

/// How many units to delete from a scope of `total` candidate units at
/// the given intensity. Integer division floors the result so the
/// count is deterministic across both compile targets — no float
/// rounding to disagree on. `Low` ≈ 10%, `Medium` ≈ 25%, `High` ≈ 50%.
/// A scope smaller than the divisor deletes nothing, which is the right
/// behaviour for a one- or two-unit page at low intensity.
pub fn deletion_count(intensity: DeletionIntensity, total: Int) -> Int {
  case intensity {
    Low -> total / 10
    Medium -> total / 4
    High -> total / 2
  }
}

/// Derive a deterministic PRNG seed from a book id and a salt. The
/// per-book seed is what makes the same units vanish on every read of a
/// given book; the salt decorrelates the page-per-page stream (salted
/// with `page_index`) from the full-sweep stream (salted with
/// `full_sweep_seed_salt`). Never seeded from the wall clock — the
/// determinism is the feature, and the test suite guards against
/// introduced randomness.
///
/// The fold is a polynomial rolling hash (`acc * 31 + codepoint`) taken
/// modulo `seed_modulus` on every step so no intermediate overflows the
/// JS safe-integer range; the salt is folded in last the same way.
pub fn derive_deletion_seed(book_id: String, salt: Int) -> Int {
  let base =
    book_id
    |> string.to_utf_codepoints
    |> list.fold(0, fn(acc, cp) {
      let mixed = acc * 31 + string.utf_codepoint_to_int(cp)
      let assert Ok(bounded) = int.modulo(mixed, seed_modulus)
      bounded
    })
  let assert Ok(seed) = int.modulo(base * 31 + salt, seed_modulus)
  seed
}
