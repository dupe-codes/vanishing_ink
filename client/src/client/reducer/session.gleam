//// Reading-session lifecycle helpers. Owns the four reducer arms that
//// open, close, react to a visibility change, and dispatch the
//// follow-up stats fetches:
////
////   * `apply_start_session` — POST a fresh session for the active book.
////   * `apply_end_session` — PUT the closing counters and re-fetch the
////     per-book and library aggregates.
////   * `apply_visibility_changed` — close on tab hide, open on tab
////     show when the reader is on a book.
////   * `apply_toggle_stats_view` — open / close the library stats
////     overlay; opening also re-fetches the aggregates so the view
////     never paints a stale snapshot.
////
//// The session lifecycle is per-book: every `apply_book_loaded`
//// opens a fresh row, every `apply_go_to_library` (or book switch,
//// or tab-hide) closes it. The closing PUT carries the deltas
//// (`pages_turned`, `words_read`, `words_skipped`, `duration_seconds`)
//// against the snapshot captured at open.

import gleam/dict
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/set
import lustre/effect.{type Effect}

import client/effects.{
  create_reading_session, describe_fetch_error, end_reading_session,
  fetch_book_stats, fetch_library_book_stats, fetch_library_stats,
  fetch_speed_trend, refresh_session_snapshot,
}
import client/ffi
import client/msg.{type Msg}
import client/state.{type Model, Model, Reader}
import shared/stats.{
  book_stats_decoder, book_stats_entry_decoder, library_stats_decoder,
  session_speed_decoder,
}

// ---------------------------------------------------------------------------
// Open
// ---------------------------------------------------------------------------

/// Open a fresh reading session for the active book. Generates a
/// client-side UUID, snapshots the page and erased-word count so the
/// closing PUT can compute deltas, stamps the started-at timestamp
/// (ISO 8601 for transport, epoch ms for in-flight arithmetic), and
/// chains the POST + the per-book stats fetch.
///
/// A no-op when no book is active — the session has nothing to
/// attach to. A no-op when a session is already in flight — the
/// caller (jump, book switch, visibility change) is responsible for
/// ending the previous session before requesting a new one, so an
/// already-active session means the dispatch site missed the end
/// hook; defaulting to "ignore the duplicate open" is safer than
/// abandoning the live row.
///
/// Stamps the FFI session snapshot via `set_session_snapshot` so the
/// `pagehide` listener has a payload to flush if the reader closes
/// the tab before the session ends normally. The snapshot reads back
/// the same closing-PUT body that `apply_end_session` would write,
/// just with the deltas frozen at "session open" (zero everywhere
/// except `ended_at`, which the beacon path stamps fresh from the
/// browser at flush time — or rather, the reducer stamps the latest
/// wall-clock value into the snapshot whenever it refreshes).
pub fn apply_start_session(model: Model) -> #(Model, Effect(Msg)) {
  case model.active_book_id, model.active_session_id {
    Some(book_id), None -> {
      let id = ffi.generate_uuid()
      let started_at = ffi.now_iso8601()
      let started_at_ms = ffi.now_ms()
      let opened =
        Model(
          ..model,
          active_session_id: Some(id),
          session_start_page: model.current_page,
          session_start_erased_count: set.size(model.erased_words),
          session_words_skipped: 0,
          session_started_at: Some(started_at),
          session_started_at_ms: started_at_ms,
        )
      refresh_session_snapshot(opened)
      #(
        opened,
        effect.batch([
          create_reading_session(book_id, id, started_at),
          fetch_book_stats(book_id),
        ]),
      )
    }
    _, _ -> #(model, effect.none())
  }
}

// The session-snapshot helper used to live here; it has been moved
// into `client/effects` so `save_reading_state` can call it inline
// without forming a `effects → reducer/session → effects` import
// cycle. The exported name (`refresh_session_snapshot`) is unchanged.

// ---------------------------------------------------------------------------
// Close
// ---------------------------------------------------------------------------

/// Close the in-flight reading session. Computes the four counter
/// deltas against the snapshot captured at open, chains the closing
/// PUT, and clears the active session fields on the model. A no-op
/// when no session is in flight.
///
/// `pages_turned` clamps at zero — the app forbids backward
/// navigation, but a viewport-resize-driven re-pagination during the
/// session could shrink `current_page` past `session_start_page`. In
/// that case `pages_turned` collapses to zero rather than reporting a
/// negative count.
///
/// `duration_seconds` is the floor-divided millisecond delta against
/// the open snapshot. Sub-second sessions report zero seconds — fine
/// for the aggregate, which sums whole-second values.
pub fn apply_end_session(model: Model) -> #(Model, Effect(Msg)) {
  case model.active_book_id, model.active_session_id {
    Some(book_id), Some(session_id) -> {
      let ended_at = ffi.now_iso8601()
      let now_ms = ffi.now_ms()
      let duration_seconds = case now_ms - model.session_started_at_ms {
        ms if ms < 0 -> 0
        ms -> ms / 1000
      }
      let pages_turned = case model.current_page - model.session_start_page {
        delta if delta < 0 -> 0
        delta -> delta
      }
      let current_erased = set.size(model.erased_words)
      let words_read = case
        current_erased
        - model.session_start_erased_count
        - model.session_words_skipped
      {
        delta if delta < 0 -> 0
        delta -> delta
      }
      // Stamp the snapshot one last time from the pre-clear model so
      // the slot carries the closing payload — same five fields the
      // PUT below queues. Browsers commonly cancel in-flight `fetch()`
      // on the unload path, so if a tab close fires `pagehide`
      // between Lustre dispatching `put_effect` and the request
      // landing, the beacon needs a body to flush. A duplicate write
      // (PUT lands AND beacon lands) is benign — the server is
      // last-write-wins and both payloads are identical at the
      // millisecond level — but a lost write (PUT cancelled, beacon
      // sees an empty slot) is not. `apply_session_ended` clears the
      // snapshot after the PUT confirms.
      refresh_session_snapshot(model)
      let closed =
        Model(
          ..model,
          active_session_id: None,
          session_started_at: None,
          session_started_at_ms: 0,
          session_start_page: 0,
          session_start_erased_count: 0,
          session_words_skipped: 0,
        )
      let put_effect =
        end_reading_session(
          book_id: book_id,
          session_id: session_id,
          ended_at: ended_at,
          words_read: words_read,
          words_skipped: model.session_words_skipped,
          pages_turned: pages_turned,
          duration_seconds: duration_seconds,
        )
      #(closed, put_effect)
    }
    _, _ -> #(model, effect.none())
  }
}

// ---------------------------------------------------------------------------
// Visibility change
// ---------------------------------------------------------------------------

/// Apply a `VisibilityChanged(visible)` dispatch. The reader tabbing
/// away ends the active session — the reader is no longer engaged,
/// and the closing PUT captures whatever progress they made up to
/// that point. The reader tabbing back opens a fresh session against
/// the same book so the next chunk of reading is recorded under a
/// distinct row.
///
/// The "tab back" arm guards on `view == Reader` and
/// `active_book_id == Some(_)` so a hide-while-in-library / show
/// transition does not spuriously open a session that has nothing
/// to attach to.
pub fn apply_visibility_changed(
  model: Model,
  visible: Bool,
) -> #(Model, Effect(Msg)) {
  case visible {
    False -> apply_end_session(model)
    True ->
      case model.view, model.active_book_id, model.active_session_id {
        Reader, Some(_), None -> apply_start_session(model)
        _, _, _ -> #(model, effect.none())
      }
  }
}

// ---------------------------------------------------------------------------
// Stats overlay
// ---------------------------------------------------------------------------

/// Flip `model.stats_open`. Opening chains fresh aggregate fetches —
/// `fetch_library_stats` for the tile values plus `fetch_speed_trend`
/// for the sparkline — so the overlay always paints with the latest
/// data rather than a stale snapshot from boot. Closing has no side
/// effect.
pub fn apply_toggle_stats_view(model: Model) -> #(Model, Effect(Msg)) {
  let opening = !model.stats_open
  let effect = case opening {
    True -> effect.batch([fetch_library_stats(), fetch_speed_trend()])
    False -> effect.none()
  }
  #(Model(..model, stats_open: opening), effect)
}

/// Flip `model.reader_stats_open`. Opening chains
/// `fetch_book_stats(active_book_id)` plus `fetch_speed_trend` so the
/// per-book overlay paints with the latest aggregates and sparkline
/// rather than a stale snapshot. Closing has no side effect. A toggle
/// fires with no active book is harmless — the flag flips, but the
/// modal renders nothing useful and `fetch_book_stats` would have
/// nothing to attach to, so the open path skips the book-stats fetch
/// when `active_book_id` is `None`. The speed-trend fetch is
/// book-independent and fires either way so the sparkline reflects the
/// reader's overall pace whenever the surface opens.
pub fn apply_toggle_reader_stats(model: Model) -> #(Model, Effect(Msg)) {
  let opening = !model.reader_stats_open
  let effect = case opening {
    True ->
      case model.active_book_id {
        Some(book_id) ->
          effect.batch([fetch_book_stats(book_id), fetch_speed_trend()])
        None -> fetch_speed_trend()
      }
    False -> effect.none()
  }
  #(Model(..model, reader_stats_open: opening), effect)
}

// ---------------------------------------------------------------------------
// Stats fetch results
// ---------------------------------------------------------------------------

/// Apply a `FetchBookStatsResult` dispatch. The Msg carries the
/// originating `book_id` and the raw response body; this helper
/// decodes the body, drops it when the active book has changed, and
/// stamps the decoded value onto `model.book_stats`.
pub fn apply_fetch_book_stats_result(
  model: Model,
  book_id: String,
  result: Result(String, ffi.FetchError),
) -> #(Model, Effect(Msg)) {
  case model.view, model.active_book_id {
    Reader, Some(active_id) if active_id == book_id ->
      case result {
        Error(error) -> {
          io.println(
            "Failed to load book stats: " <> describe_fetch_error(error),
          )
          #(model, effect.none())
        }
        Ok(body) ->
          case json.parse(body, book_stats_decoder()) {
            Error(_) -> {
              io.println("Failed to decode /api/books/:id/stats response")
              #(model, effect.none())
            }
            Ok(stats_record) -> #(
              Model(..model, book_stats: Some(stats_record)),
              effect.none(),
            )
          }
      }
    _, _ -> #(model, effect.none())
  }
}

/// Apply a `FetchLibraryStatsResult` dispatch. Decodes the body and
/// stamps the result onto `model.library_stats`; a decode failure or
/// network error logs and leaves the prior value in place.
pub fn apply_fetch_library_stats_result(
  model: Model,
  result: Result(String, ffi.FetchError),
) -> #(Model, Effect(Msg)) {
  case result {
    Error(error) -> {
      io.println(
        "Failed to load library stats: " <> describe_fetch_error(error),
      )
      #(model, effect.none())
    }
    Ok(body) ->
      case json.parse(body, library_stats_decoder()) {
        Error(_) -> {
          io.println("Failed to decode /api/stats response")
          #(model, effect.none())
        }
        Ok(stats_record) -> #(
          Model(..model, library_stats: Some(stats_record)),
          effect.none(),
        )
      }
  }
}

/// Apply a `FetchLibraryBookStatsResult` dispatch. The wire shape is
/// a JSON array of `{book_id, ...stats}` objects; we decode it into
/// a list of `(book_id, BookStats)` pairs and project it onto a
/// `Dict` so the library card lookup at render time is constant-time.
pub fn apply_fetch_library_book_stats_result(
  model: Model,
  result: Result(String, ffi.FetchError),
) -> #(Model, Effect(Msg)) {
  case result {
    Error(error) -> {
      io.println(
        "Failed to load library book stats: " <> describe_fetch_error(error),
      )
      #(model, effect.none())
    }
    Ok(body) ->
      case json.parse(body, decode.list(book_stats_entry_decoder())) {
        Error(_) -> {
          io.println("Failed to decode /api/stats/books response")
          #(model, effect.none())
        }
        Ok(entries) -> #(
          Model(..model, library_book_stats: dict.from_list(entries)),
          effect.none(),
        )
      }
  }
}

/// Apply a `FetchSpeedTrendResult` dispatch. The wire shape is a JSON
/// array of `{date, wpm}` samples in reverse-chronological order; we
/// decode it as-is and stamp it onto `model.speed_trend`. The view
/// layer reverses the list when rendering so the polyline reads
/// left-to-right in chronological order — keeping the on-model order
/// the same as the wire order means the reducer stays a pure
/// projection of the response.
///
/// A decode failure or network error clears `speed_trend` so a stale
/// snapshot from the previous open does not paint the new overlay
/// alongside an error. The console log carries the diagnostic so a
/// future operator session can investigate without a UI banner that
/// would compete with the rest of the stats surface.
pub fn apply_fetch_speed_trend_result(
  model: Model,
  result: Result(String, ffi.FetchError),
) -> #(Model, Effect(Msg)) {
  case result {
    Error(error) -> {
      io.println("Failed to load speed trend: " <> describe_fetch_error(error))
      #(Model(..model, speed_trend: []), effect.none())
    }
    Ok(body) ->
      case json.parse(body, decode.list(session_speed_decoder())) {
        Error(_) -> {
          io.println("Failed to decode /api/stats/speed response")
          #(Model(..model, speed_trend: []), effect.none())
        }
        Ok(samples) -> #(Model(..model, speed_trend: samples), effect.none())
      }
  }
}

/// Apply a `SessionCreated` dispatch. The success arm is a quiet no-op
/// — the session row is created server-side and the client already
/// stamped the id on the model. The error arm logs and clears the
/// in-flight id so the closing PUT does not fire against a row that
/// never landed.
pub fn apply_session_created(
  model: Model,
  book_id: String,
  result: Result(String, ffi.FetchError),
) -> #(Model, Effect(Msg)) {
  case result {
    Ok(_) -> #(model, effect.none())
    Error(error) -> {
      io.println(
        "Failed to create reading session: " <> describe_fetch_error(error),
      )
      // Clear the session id only when the in-flight id still matches
      // the failed POST's book — a fresh session may have already
      // opened against a different book by the time this lands.
      case model.active_book_id == Some(book_id) {
        True -> {
          let cleared =
            Model(
              ..model,
              active_session_id: None,
              session_started_at: None,
              session_started_at_ms: 0,
              session_start_page: 0,
              session_start_erased_count: 0,
              session_words_skipped: 0,
            )
          // Funnel through the snapshot helper so the FFI slot follows
          // the cleared model — `apply_session_opened`'s prior stamp
          // pointed at a session_id the server refused, and a
          // subsequent `pagehide` would beacon a `POST` for a row
          // that does not exist. The helper's "no active session"
          // arm zeroes the slot. Mirrors the success-path funnelling
          // of `apply_session_ended`.
          refresh_session_snapshot(cleared)
          #(cleared, effect.none())
        }
        False -> #(model, effect.none())
      }
    }
  }
}

/// Apply a `SessionEnded` dispatch. Chains the per-book and library
/// stats fetches so the overlay surfaces the updated aggregates on
/// its next open. The success arm doesn't need to update model state
/// beyond what `apply_end_session` already wrote; the error arm logs
/// and continues (the row was never closed; the next session-end
/// retries will write fresher counters).
///
/// On success, clears the FFI snapshot slot — the closing PUT
/// confirmed and the row is durable, so a subsequent `pagehide`
/// must not re-flush the same payload. On failure, the snapshot
/// stays in place so a `pagehide` racing the failed PUT can deliver
/// the closing counters via `sendBeacon` as a fallback. The slot is
/// cleared by going through `refresh_session_snapshot(model)`: the
/// caller already cleared `active_session_id` in `apply_end_session`,
/// so the helper's "no active session" arm fires and zeroes the
/// slot — keeps both stamp and clear paths funnelling through one
/// helper.
pub fn apply_session_ended(
  model: Model,
  result: Result(String, ffi.FetchError),
) -> #(Model, Effect(Msg)) {
  let log_effect = case result {
    Ok(_) -> {
      refresh_session_snapshot(model)
      effect.none()
    }
    Error(error) ->
      effect.from(fn(_dispatch) {
        io.println(
          "Failed to end reading session: " <> describe_fetch_error(error),
        )
      })
  }
  // Refresh the library aggregates and the bulk per-book map either
  // way — even a failed PUT may have applied server-side before the
  // network gave up, and the aggregates are cheap to re-fetch. The
  // per-book stats for the active book only fire when a reader is
  // still in `Reader` view; the closing PUT might have flowed out of
  // `apply_go_to_library`, in which case the next `book_stats` fetch
  // lands on the next book open.
  let active_book_effect = case model.active_book_id {
    Some(book_id) -> fetch_book_stats(book_id)
    None -> effect.none()
  }
  #(
    model,
    effect.batch([
      log_effect,
      fetch_library_stats(),
      fetch_library_book_stats(),
      active_book_effect,
    ]),
  )
}
