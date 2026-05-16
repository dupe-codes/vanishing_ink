//// Target-agnostic tests for the `shared/stats` module. The streak
//// computation is pure Gleam — date arithmetic is injected through
//// `is_next_day` so neither the server's Erlang `calendar` wrapper
//// nor any hypothetical JS implementation crosses the test boundary.
//// Living in `shared/test/` keeps the home of the tests adjacent to
//// the home of the function under test, so a future refactor of
//// `shared/stats.gleam` finds its tests without crossing the
//// shared / server package boundary.

import gleam/json as gleam_json
import gleeunit
import shared/stats

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn compute_current_streak_days_counts_consecutive_back_from_today_test() {
  let is_next_day = fn(a: String, b: String) -> Bool {
    case a, b {
      "2026-05-10", "2026-05-11" -> True
      "2026-05-11", "2026-05-12" -> True
      "2026-05-12", "2026-05-13" -> True
      _, _ -> False
    }
  }
  let days = ["2026-05-13", "2026-05-12", "2026-05-11", "2026-05-10"]
  assert stats.compute_current_streak_days(
      session_days: days,
      today: "2026-05-13",
      is_next_day: is_next_day,
    )
    == 4
}

pub fn compute_current_streak_days_handles_yesterday_today_gap_test() {
  let is_next_day = fn(a: String, b: String) -> Bool {
    case a, b {
      "2026-05-12", "2026-05-13" -> True
      _, _ -> False
    }
  }
  // No session today, but yesterday counts — the streak survives
  // until the reader actually misses a day.
  let days = ["2026-05-12"]
  assert stats.compute_current_streak_days(
      session_days: days,
      today: "2026-05-13",
      is_next_day: is_next_day,
    )
    == 1
}

pub fn compute_current_streak_days_breaks_on_gap_test() {
  let is_next_day = fn(_a: String, _b: String) -> Bool { False }
  // Most recent session is from "long ago"; the streak is zero.
  let days = ["2026-05-01"]
  assert stats.compute_current_streak_days(
      session_days: days,
      today: "2026-05-13",
      is_next_day: is_next_day,
    )
    == 0
}

pub fn compute_current_streak_days_empty_list_is_zero_test() {
  let is_next_day = fn(_a: String, _b: String) -> Bool { False }
  assert stats.compute_current_streak_days(
      session_days: [],
      today: "2026-05-13",
      is_next_day: is_next_day,
    )
    == 0
}

pub fn session_speed_codec_round_trips_test() {
  // The encoder and decoder are symmetric: a record encoded to JSON
  // and then decoded back must equal the input. Pinning the wire form
  // alongside the round-trip catches a field-name drift on either
  // side — the test would surface as a decode failure rather than as
  // a silent shape mismatch at runtime.
  let sample = stats.SessionSpeed(date: "2026-05-13T10:00:00.000Z", wpm: 180)
  let encoded = stats.session_speed_to_json(sample) |> gleam_json.to_string
  assert encoded == "{\"date\":\"2026-05-13T10:00:00.000Z\",\"wpm\":180}"
  let assert Ok(decoded) =
    gleam_json.parse(encoded, stats.session_speed_decoder())
  assert decoded == sample
}
