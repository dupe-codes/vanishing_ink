//// `Effect(Msg)` builders. Every value returned from this module is a
//// side-effect descriptor — fetch a JSON endpoint, save a record,
//// schedule a timer, or schedule a post-paint DOM read. Lustre runs
//// these effects after the model has been updated, and each one
//// dispatches a follow-up `Msg` back through the reducer when it
//// resolves.
////
//// The fetch helpers are thin wrappers around the FFI primitives in
//// `client/ffi.gleam`. Each one stringifies the response body, applies
//// a decoder, and routes the result through one `Msg` variant. Decode
//// failures collapse into the matching `FetchError.DecodeError` so
//// callers see one error shape regardless of where the failure
//// originated.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import lustre/effect.{type Effect}

import client/epub
import client/ffi
import client/msg.{
  type Msg, AdvanceWord, BookCreated, BookDeleted, BookLoaded,
  BookSettingsLoaded, BooksLoaded, EpubParsed, LinesMeasured, ParagraphsMeasured,
  ReadingStateLoaded, SettingsLoaded, ViewportResized,
}
import client/state.{
  type LineBox, type Model, LineBox, Manual, RealTime, measurement_id,
  page_content_id,
}
import client/types.{type BookSettings, type UserSettings}

// ---------------------------------------------------------------------------
// Fetch effects
// ---------------------------------------------------------------------------

/// `GET /api/books` and dispatch `BooksLoaded`.
pub fn fetch_books() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/books", fn(result) {
      let decoded =
        result
        |> result.try(fn(body) {
          json.parse(body, decode.list(types.book_meta_decoder()))
          |> result.map_error(fn(_) {
            ffi.DecodeError("Failed to decode book list")
          })
        })
      dispatch(BooksLoaded(decoded))
    })
  })
}

/// `GET /api/books/:id` and dispatch `BookLoaded`. The decoder
/// produces a `#(BookMeta, SegmentedText)` so the reducer can stamp
/// both onto the model in one arm.
pub fn fetch_book(id: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/books/" <> id, fn(result) {
      let decoded =
        result
        |> result.try(fn(body) {
          json.parse(body, types.book_with_segments_decoder())
          |> result.map_error(fn(_) { ffi.DecodeError("Failed to decode book") })
        })
      dispatch(BookLoaded(decoded))
    })
  })
}

/// `GET /api/settings` and dispatch `SettingsLoaded` with the raw
/// response body string. The reducer arm runs the decoder so a
/// decode failure surfaces as `Error(DecodeError(_))` alongside
/// every other fetch failure — keeping the load path's error
/// surface symmetrical with the books fetches.
pub fn fetch_settings() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/settings", fn(result) {
      dispatch(SettingsLoaded(result))
    })
  })
}

/// `GET /api/books/:id/settings` and dispatch `BookSettingsLoaded`.
/// Same shape as `fetch_settings` — the body is forwarded raw so
/// the reducer can branch on the decode result inline. The id is
/// closed over and re-emitted on the dispatched Msg so the reducer
/// can drop a stale response that lands after the reader has
/// navigated away or opened a different book.
pub fn fetch_book_settings(id: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/books/" <> id <> "/settings", fn(result) {
      dispatch(BookSettingsLoaded(id, result))
    })
  })
}

/// `GET /api/books/:id/state` and dispatch `ReadingStateLoaded`. Same
/// shape as `fetch_book_settings` — the raw body is forwarded so the
/// reducer branches on the decode result inline, and the id is closed
/// over and re-emitted on the dispatched Msg so a stale response that
/// lands after the reader has navigated away or opened a different
/// book can be dropped.
pub fn fetch_reading_state(id: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_get("/api/books/" <> id <> "/state", fn(result) {
      dispatch(ReadingStateLoaded(id, result))
    })
  })
}

/// Persist the current global preferences via `PUT /api/settings`.
/// Fire-and-forget — the JS callback logs failures to the console so
/// a future operator session can investigate, but the UI does not
/// surface a banner because settings saves race with rapid slider
/// drags and a queued error toast would feel noisier than the bug
/// it indicates.
///
/// ORDERING — rapid slider drags fire one PUT per `Set*` dispatch
/// with no debounce and no sequence number. On a single HTTP/2
/// connection these typically arrive in dispatch order, but the
/// architecture does not enforce it: under packet reordering, a
/// retried request, or a future multiplexed client, the last value
/// on the server may not reflect the user's final intent.
/// Acceptable for the MVP — a debounce or a monotonic request-id
/// gate would pin the invariant if it ever matters.
pub fn save_global_settings(settings: UserSettings) -> Effect(Msg) {
  let body =
    settings
    |> user_settings_to_json
    |> json.to_string
  effect.from(fn(_dispatch) {
    ffi.fetch_json_put("/api/settings", body, fn(result) {
      case result {
        Ok(_) -> Nil
        Error(error) ->
          io.println(
            "Failed to save global settings: " <> describe_fetch_error(error),
          )
      }
    })
  })
}

/// Persist the current per-book overrides via
/// `PUT /api/books/:id/settings`. Same fire-and-forget shape as
/// `save_global_settings`; the only failure surface is the console.
/// The same lack-of-ordering caveat applies — see the ORDERING note
/// on `save_global_settings`.
pub fn save_book_settings(id: String, settings: BookSettings) -> Effect(Msg) {
  let body =
    settings
    |> book_settings_to_json
    |> json.to_string
  effect.from(fn(_dispatch) {
    ffi.fetch_json_put("/api/books/" <> id <> "/settings", body, fn(result) {
      case result {
        Ok(_) -> Nil
        Error(error) ->
          io.println(
            "Failed to save book settings: " <> describe_fetch_error(error),
          )
      }
    })
  })
}

/// Persist the current per-book reading progress via
/// `PUT /api/books/:id/state`. Fire-and-forget — the JS callback logs
/// failures to the console so a future operator session can
/// investigate, but the UI does not surface a banner because the saves
/// race with rapid erases / page turns and a queued error toast would
/// feel noisier than the bug it indicates.
///
/// A no-op when `model.active_book_id` is `None` — there's no row to
/// write to. The guard means callers can chain this effect
/// unconditionally without first inspecting the model; library-view
/// dispatches collapse to `effect.none()` for free.
///
/// ORDERING — same caveat as `save_book_settings`: rapid erases /
/// page turns fire one PUT per dispatch with no debounce and no
/// sequence number. The server's last-write-wins guard rejects
/// out-of-order writes via the `updated_at` comparison, so a delayed
/// PUT that arrives after a newer one is silently dropped on the
/// server side rather than clobbering the latest state.
pub fn save_reading_state(model: Model) -> Effect(Msg) {
  case model.active_book_id {
    None -> effect.none()
    Some(id) -> {
      let mode_value = case model.mode {
        Manual -> "manual"
        RealTime -> "ghost"
      }
      let body =
        json.object([
          #("book_id", json.string(id)),
          #("mode", json.string(mode_value)),
          #(
            "sentence_bitset",
            json.nullable(encode_indices_to_base64(model.erased), json.string),
          ),
          #(
            "word_bitset",
            json.nullable(
              encode_indices_to_base64(model.erased_words),
              json.string,
            ),
          ),
          #("current_page", json.int(model.current_page)),
          #("updated_at", json.string(ffi.now_iso8601())),
        ])
        |> json.to_string
      effect.from(fn(_dispatch) {
        ffi.fetch_json_put("/api/books/" <> id <> "/state", body, fn(result) {
          case result {
            Ok(_) -> Nil
            Error(error) ->
              io.println(
                "Failed to save reading state: " <> describe_fetch_error(error),
              )
          }
        })
      })
    }
  }
}

/// `DELETE /api/books/:id` and dispatch `BookDeleted`. The server
/// responds 204 No Content on success and 404 when the id is not found;
/// both resolve through the same `Result(String, FetchError)` shape the
/// other fetch effects use, so the update arm can treat a 404 as an
/// error the same way it treats a network failure.
pub fn delete_book_effect(id: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.fetch_json_delete("/api/books/" <> id, fn(result) {
      dispatch(BookDeleted(id, result))
    })
  })
}

/// Hand a picked `.epub` file off to the FFI parser and dispatch
/// `EpubParsed` when it resolves. The `Dynamic` payload is the raw
/// browser `File` reference — the reducer has no use for it directly,
/// so we treat it as opaque and pass it through.
///
/// The parse runs asynchronously (foliate-js awaits `File.arrayBuffer()`
/// then walks the spine in turn); the `effect.from` shape mirrors the
/// fetch helpers so a future progress-bar or cancellation surface can
/// land in the same place as the existing network call sites.
pub fn parse_epub(file: Dynamic) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    epub.parse_epub_file(file, fn(result) { dispatch(EpubParsed(result)) })
  })
}

/// `POST /api/books` with the JSON body `{ "title", "text" }` and
/// dispatch `BookCreated`. The server segments and stores the text;
/// the response carries both the new metadata and the parsed
/// segments so the client could open the reader directly — today
/// we stay in the library so the reader can see the new card
/// appear before deciding to open it.
pub fn create_book(title: String, text: String) -> Effect(Msg) {
  let body =
    json.object([#("title", json.string(title)), #("text", json.string(text))])
    |> json.to_string
  effect.from(fn(dispatch) {
    ffi.fetch_json_post("/api/books", body, fn(result) {
      let decoded =
        result
        |> result.try(fn(body) {
          json.parse(body, types.create_book_response_decoder())
          |> result.map_error(fn(_) {
            ffi.DecodeError("Failed to decode create response")
          })
        })
      dispatch(BookCreated(decoded))
    })
  })
}

// ---------------------------------------------------------------------------
// JSON encoders
// ---------------------------------------------------------------------------

pub fn user_settings_to_json(settings: UserSettings) -> json.Json {
  json.object([
    #("font_size", json.int(settings.font_size)),
    #("line_spacing", json.float(settings.line_spacing)),
    #("dark_mode", json.bool(settings.dark_mode)),
    #("ghost_mode", json.bool(settings.ghost_mode)),
    #("ghost_opacity", json.float(settings.ghost_opacity)),
    #("default_wpm", json.int(settings.default_wpm)),
    #(
      "default_paragraph_delay_ms",
      json.int(settings.default_paragraph_delay_ms),
    ),
    #("default_page_delay_ms", json.int(settings.default_page_delay_ms)),
  ])
}

pub fn book_settings_to_json(settings: BookSettings) -> json.Json {
  json.object([
    #("wpm", json.nullable(settings.wpm, json.int)),
    #(
      "paragraph_delay_ms",
      json.nullable(settings.paragraph_delay_ms, json.int),
    ),
    #("page_delay_ms", json.nullable(settings.page_delay_ms, json.int)),
    #("ghost_opacity", json.nullable(settings.ghost_opacity, json.float)),
  ])
}

// ---------------------------------------------------------------------------
// Base64 bitset encode / decode
// ---------------------------------------------------------------------------

/// Project a `Set(Int)` of indices into the wire-format optional
/// base64 string. An empty set rides as `None` so the JSON encoder
/// emits `null` — symmetric with the server's empty-default shape and
/// cheaper than transmitting an empty BitArray. Non-empty sets feed
/// through the FFI bit-packer.
pub fn encode_indices_to_base64(indices: Set(Int)) -> Option(String) {
  case set.is_empty(indices) {
    True -> None
    False -> Some(ffi.pack_indices_to_base64(set.to_list(indices)))
  }
}

/// Inverse of `encode_indices_to_base64`. A `None` payload (the
/// server's default for a book with no recorded progress) decodes to
/// the empty set; a `Some(base64)` payload is unpacked through the
/// FFI bit-decoder and projected back into a `Set(Int)`.
pub fn decode_base64_to_indices(encoded: Option(String)) -> Set(Int) {
  case encoded {
    None -> set.new()
    Some(value) ->
      value
      |> ffi.unpack_base64_to_indices
      |> set.from_list
  }
}

// ---------------------------------------------------------------------------
// Measurement / repagination effects
// ---------------------------------------------------------------------------

/// Schedule an `after_paint` effect that reads paragraph heights and
/// the available content-area height from the live DOM, then
/// dispatches `ParagraphsMeasured`. Falls back to `window.innerHeight`
/// when the page-content sentinel cannot be located so pagination
/// still produces output rather than getting wedged.
pub fn measure_after_paint() -> Effect(Msg) {
  effect.after_paint(fn(dispatch, _root) {
    let available_height = case ffi.get_element_height("#" <> page_content_id) {
      Ok(height) -> height
      Error(_) -> ffi.get_viewport_height()
    }
    let heights = ffi.measure_paragraphs("#" <> measurement_id)
    dispatch(ParagraphsMeasured(
      heights: heights,
      available_height: available_height,
    ))
  })
}

/// Schedule an `after_paint` effect that walks the visible page's
/// `[data-global-index]` word spans and dispatches `LinesMeasured`
/// with one `LineBox` per visual line. The FFI returns four-tuples
/// (top, height, first_gi, last_gi); this helper converts each to a
/// `LineBox` record before dispatching so the rest of the reducer
/// surface speaks in the domain type rather than raw geometry.
///
/// Read against `#vi-page-content` (the visible page container) — not
/// the off-screen measurement mirror — because the visible page is
/// what the overlay anchors into. The measurement mirror has the same
/// width and word-wrap behaviour but lives at a different y-offset, so
/// reading its line tops would point the overlay at the wrong rows.
pub fn measure_lines_after_paint() -> Effect(Msg) {
  effect.after_paint(fn(dispatch, _root) {
    let tuples = ffi.measure_word_lines("#" <> page_content_id)
    let boxes = list.map(tuples, line_box_from_tuple)
    dispatch(LinesMeasured(boxes: boxes))
  })
}

/// Convert one FFI four-tuple into a `LineBox`. Pulled out so the
/// measurement effect reads as one `list.map` rather than carrying
/// an inline `fn(tuple) { ... }` literal.
fn line_box_from_tuple(tuple: #(Float, Float, Int, Int)) -> LineBox {
  let #(top, height, first_gi, last_gi) = tuple
  LineBox(
    top: top,
    height: height,
    first_word_gi: first_gi,
    last_word_gi: last_gi,
  )
}

/// Re-trigger pagination by dispatching `ViewportResized`. Used after
/// settings changes that alter paragraph wrap heights (font size,
/// line spacing, dyslexia font). Going through the existing message
/// keeps one re-measure path instead of two — `ViewportResized` is
/// already the single producer of the measurement effect for window
/// resizes, and threading settings changes through the same arm means
/// every future measurement-side concern (e.g. a debounce, or a
/// progress indicator) only has to land in one place.
pub fn repaginate_after_paint() -> Effect(Msg) {
  effect.from(fn(dispatch) { dispatch(ViewportResized) })
}

// ---------------------------------------------------------------------------
// Fade engine timer scheduling
// ---------------------------------------------------------------------------

/// Schedule the next AdvanceWord dispatch after `delay_ms`. The
/// FFI's single-slot timer clears any prior in-flight handle
/// synchronously, so this is safe to call from any
/// engine-transition arm without first calling
/// `clear_word_timer` defensively.
pub fn schedule_advance_word(delay_ms: Int) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi.start_word_timer(delay_ms, fn() { dispatch(AdvanceWord) })
  })
}

// ---------------------------------------------------------------------------
// Error rendering
// ---------------------------------------------------------------------------

/// Project a `FetchError` to a human-readable string suitable for a
/// toast / error banner. Pulled out so the three failure-path arms
/// share one rendering — drift between them would otherwise
/// produce inconsistent UX for the same underlying failure.
///
/// Exposed for tests that pin the error-message surface — every
/// `FetchError` arm should produce a non-empty, user-readable
/// sentence rather than a `string.inspect` of the raw record.
pub fn describe_fetch_error(error: ffi.FetchError) -> String {
  case error {
    ffi.NetworkError(message) ->
      case message {
        "" -> "Could not reach the server."
        _ -> "Could not reach the server: " <> message
      }
    ffi.HttpError(status, body) ->
      case body {
        "" -> "Server returned " <> int.to_string(status) <> "."
        _ -> "Server returned " <> int.to_string(status) <> ": " <> body
      }
    ffi.DecodeError(detail) -> detail
  }
}
