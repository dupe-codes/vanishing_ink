//// Integration tests for the Vanishing Ink server. Each test boots a
//// fresh in-memory SQLite database, builds a `web.Context`, and drives
//// the router through `wisp/simulate`. The tests deliberately exercise
//// the public HTTP surface end to end — they would catch any drift
//// between the SQL layer, the router, and the JSON encoders.
////
//// METHODOLOGY: each HTTP test reads the response body and asserts on
//// the whole decoded payload rather than a hand-picked field. That
//// way a silent change to any unverified default (a schema default,
//// an encoder field, the `last_read_at` write) surfaces as a value
//// mismatch on the first assertion that crosses it.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import gleeunit
import server/db
import server/db_sessions
import server/router
import server/types.{
  type BookSettings, type ReadingSession, type ReadingState, type UserSettings,
  BookSettings, ReadingSession, ReadingState,
}
import server/web
import shared/segmenter
import shared/stats.{BookStats}
import sqlight
import wisp
import wisp/simulate

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_context(f: fn(web.Context) -> Nil) -> Nil {
  // ":memory:" gives every test an isolated database that disappears
  // when the connection closes — perfect for hermetic testing.
  let assert Ok(conn) = db.initialize(":memory:")
  f(web.Context(db: conn, static_dir: "../client/dist"))
  let assert Ok(_) = sqlight.close(conn)
  Nil
}

// ---------------------------------------------------------------------------
// Wire-format decoders. Inverse of the encoders in `server/types`; kept
// inline in the test module because the production code never decodes
// these JSON shapes — only the client does, and the client is a
// different package.
// ---------------------------------------------------------------------------

type BookCreateResponse {
  BookCreateResponse(book: BookMetaWire, segments: segmenter.SegmentedText)
}

type BookMetaWire {
  BookMetaWire(
    id: String,
    title: String,
    author: Option(String),
    genre: Option(String),
    word_count: Int,
    sentence_count: Int,
    uploaded_at: String,
    last_read_at: Option(String),
  )
}

type BookFullWire {
  BookFullWire(
    id: String,
    title: String,
    author: Option(String),
    genre: Option(String),
    raw_text: String,
    word_count: Int,
    sentence_count: Int,
    uploaded_at: String,
    last_read_at: Option(String),
    segments: segmenter.SegmentedText,
  )
}

fn book_meta_wire_decoder() -> decode.Decoder(BookMetaWire) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use author <- decode.field("author", decode.optional(decode.string))
  use genre <- decode.field("genre", decode.optional(decode.string))
  use word_count <- decode.field("word_count", decode.int)
  use sentence_count <- decode.field("sentence_count", decode.int)
  use uploaded_at <- decode.field("uploaded_at", decode.string)
  use last_read_at <- decode.field(
    "last_read_at",
    decode.optional(decode.string),
  )
  decode.success(BookMetaWire(
    id: id,
    title: title,
    author: author,
    genre: genre,
    word_count: word_count,
    sentence_count: sentence_count,
    uploaded_at: uploaded_at,
    last_read_at: last_read_at,
  ))
}

fn book_create_response_decoder() -> decode.Decoder(BookCreateResponse) {
  use book <- decode.field("book", book_meta_wire_decoder())
  use segments <- decode.field("segments", segmenter.decoder())
  decode.success(BookCreateResponse(book: book, segments: segments))
}

fn book_full_decoder() -> decode.Decoder(BookFullWire) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use author <- decode.field("author", decode.optional(decode.string))
  use genre <- decode.field("genre", decode.optional(decode.string))
  use raw_text <- decode.field("raw_text", decode.string)
  use word_count <- decode.field("word_count", decode.int)
  use sentence_count <- decode.field("sentence_count", decode.int)
  use uploaded_at <- decode.field("uploaded_at", decode.string)
  use last_read_at <- decode.field(
    "last_read_at",
    decode.optional(decode.string),
  )
  use segments <- decode.field("segments", segmenter.decoder())
  decode.success(BookFullWire(
    id: id,
    title: title,
    author: author,
    genre: genre,
    raw_text: raw_text,
    word_count: word_count,
    sentence_count: sentence_count,
    uploaded_at: uploaded_at,
    last_read_at: last_read_at,
    segments: segments,
  ))
}

fn reading_state_wire_decoder() -> decode.Decoder(ReadingState) {
  use book_id <- decode.field("book_id", decode.string)
  use mode <- decode.field("mode", decode.string)
  use sentence_bitset <- decode.field(
    "sentence_bitset",
    decode.optional(decode.string),
  )
  use word_bitset <- decode.field("word_bitset", decode.optional(decode.string))
  use current_page <- decode.field("current_page", decode.int)
  use percent_progress <- decode.field("percent_progress", decode.float)
  use updated_at <- decode.field("updated_at", decode.optional(decode.string))
  // Bitsets in `ReadingState` are `BitArray`, but the wire form is
  // base64. Decoding through the `String` and re-base64-decoding keeps
  // the round-trip honest end-to-end.
  let sentence = sentence_bitset |> option.then(base64_to_bit_array)
  let word = word_bitset |> option.then(base64_to_bit_array)
  decode.success(ReadingState(
    book_id: book_id,
    mode: mode,
    sentence_bitset: sentence,
    word_bitset: word,
    current_page: current_page,
    percent_progress: percent_progress,
    updated_at: updated_at,
  ))
}

fn base64_to_bit_array(encoded: String) -> Option(BitArray) {
  case bit_array.base64_decode(encoded) {
    Ok(bytes) -> Some(bytes)
    Error(_) -> None
  }
}

fn user_settings_wire_decoder() -> decode.Decoder(UserSettings) {
  use font_size <- decode.field("font_size", decode.int)
  use line_spacing <- decode.field("line_spacing", decode.float)
  use dark_mode <- decode.field("dark_mode", decode.bool)
  use ghost_mode <- decode.field("ghost_mode", decode.bool)
  use ghost_opacity <- decode.field("ghost_opacity", decode.float)
  use default_wpm <- decode.field("default_wpm", decode.int)
  use default_paragraph_delay_ms <- decode.field(
    "default_paragraph_delay_ms",
    decode.int,
  )
  use default_page_delay_ms <- decode.field("default_page_delay_ms", decode.int)
  decode.success(types.UserSettings(
    font_size: font_size,
    line_spacing: line_spacing,
    dark_mode: dark_mode,
    ghost_mode: ghost_mode,
    ghost_opacity: ghost_opacity,
    default_wpm: default_wpm,
    default_paragraph_delay_ms: default_paragraph_delay_ms,
    default_page_delay_ms: default_page_delay_ms,
  ))
}

fn decode_body(response: wisp.Response, decoder: decode.Decoder(a)) -> a {
  let assert Ok(decoded) = json.parse(simulate.read_body(response), decoder)
  decoded
}

const default_user_settings = types.UserSettings(
  font_size: 18,
  line_spacing: 1.6,
  dark_mode: True,
  ghost_mode: False,
  ghost_opacity: 0.06,
  default_wpm: 200,
  default_paragraph_delay_ms: 1000,
  default_page_delay_ms: 2000,
)

// ---------------------------------------------------------------------------
// Liveness
// ---------------------------------------------------------------------------

pub fn status_route_returns_ok_json_test() {
  use ctx <- with_context
  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/status"),
      ctx,
    )
  assert response.status == 200
  assert simulate.read_body(response) == "{\"status\":\"ok\"}"
}

pub fn spa_fallback_serves_index_html_test() {
  use ctx <- with_context
  let response =
    router.handle_request(simulate.browser_request(http.Get, "/"), ctx)
  assert response.status == 200
  assert string.contains(simulate.read_body(response), "Vanishing Ink")
}

pub fn unknown_route_serves_spa_shell_test() {
  use ctx <- with_context
  let response =
    router.handle_request(simulate.browser_request(http.Get, "/nope"), ctx)
  // Non-API routes get the SPA shell so client-side view routing works.
  assert response.status == 200
  assert string.contains(simulate.read_body(response), "Vanishing Ink")
}

// ---------------------------------------------------------------------------
// Books
// ---------------------------------------------------------------------------

const sample_text = "It was the best of times. It was the worst of times."

pub fn create_book_returns_full_payload_and_persists_test() {
  use ctx <- with_context

  let body =
    json.object([
      #("title", json.string("Tale of Two Cities")),
      #("author", json.string("Dickens")),
      #("text", json.string(sample_text)),
    ])

  let response =
    simulate.browser_request(http.Post, "/api/books")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 201

  // Decode the entire response body and assert against a single
  // expected record. `id` and `uploaded_at` are server-generated, so
  // we accept whatever the server produced and pin every other field.
  let decoded = decode_body(response, book_create_response_decoder())
  let expected_segments = segmenter.segment(sample_text)
  let expected =
    BookCreateResponse(
      book: BookMetaWire(
        id: decoded.book.id,
        title: "Tale of Two Cities",
        author: Some("Dickens"),
        genre: None,
        word_count: 12,
        sentence_count: 2,
        uploaded_at: decoded.book.uploaded_at,
        last_read_at: None,
      ),
      segments: expected_segments,
    )
  assert decoded == expected
  // Sanity-check the server-generated fields without relying on a
  // specific format — wisp's `random_string(32)` yields a 32-grapheme
  // identifier and `clock.now_iso8601` an ISO 8601 UTC string.
  assert decoded.book.id != ""
  assert decoded.book.uploaded_at != ""

  // Persistence check via the listing endpoint: the same record must
  // come back through `GET /api/books`.
  let listing_response =
    router.handle_request(simulate.browser_request(http.Get, "/api/books"), ctx)
  assert listing_response.status == 200
  let listing =
    decode_body(listing_response, decode.list(book_meta_wire_decoder()))
  assert listing == [decoded.book]
}

pub fn create_book_missing_title_is_400_with_field_message_test() {
  use ctx <- with_context
  let body = json.object([#("text", json.string("some text"))])
  let response =
    simulate.browser_request(http.Post, "/api/books")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)
  assert response.status == 400
  let detail = simulate.read_body(response)
  // The decode error must surface the missing field by name so the
  // client knows what to send next.
  assert string.contains(detail, "title")
}

pub fn create_book_empty_text_is_400_with_field_message_test() {
  use ctx <- with_context
  let body =
    json.object([
      #("title", json.string("Empty Book")),
      #("text", json.string("")),
    ])
  let response =
    simulate.browser_request(http.Post, "/api/books")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)
  assert response.status == 400
  // Wisp's `bad_request(detail)` prefixes "Bad request: " — exact
  // match so a future change to the formatter shows up here.
  assert simulate.read_body(response) == "Bad request: text must not be empty"
}

pub fn get_missing_book_is_404_test() {
  use ctx <- with_context
  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/books/nope"),
      ctx,
    )
  assert response.status == 404
  assert simulate.read_body(response) == "Not found"
}

pub fn get_book_returns_full_payload_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Tale", Some("Dickens"), sample_text)

  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/books/" <> created.book.id),
      ctx,
    )
  assert response.status == 200

  let decoded = decode_body(response, book_full_decoder())
  let expected =
    BookFullWire(
      id: created.book.id,
      title: "Tale",
      author: Some("Dickens"),
      genre: None,
      raw_text: sample_text,
      word_count: 12,
      sentence_count: 2,
      uploaded_at: created.book.uploaded_at,
      last_read_at: None,
      segments: segmenter.segment(sample_text),
    )
  assert decoded == expected
}

// ---------------------------------------------------------------------------
// Reading state — HTTP layer
// ---------------------------------------------------------------------------

pub fn get_reading_state_for_unwritten_book_returns_empty_default_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  let response = http_get_reading_state(ctx, created.book.id)
  assert response.status == 200

  let decoded = decode_body(response, reading_state_wire_decoder())
  // `updated_at` is `None`, not the 1970 sentinel — the client should
  // see `null` for a book that has never been written to.
  assert decoded
    == ReadingState(
      book_id: created.book.id,
      mode: "manual",
      sentence_bitset: None,
      word_bitset: None,
      current_page: 0,
      percent_progress: 0.0,
      updated_at: None,
    )
}

pub fn get_reading_state_for_missing_book_is_404_test() {
  use ctx <- with_context
  let response = http_get_reading_state(ctx, "no-such-book")
  assert response.status == 404
  assert simulate.read_body(response) == "Not found"
}

pub fn put_reading_state_round_trips_through_http_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  let bytes = <<1, 2, 3, 4>>
  let body =
    json.object([
      #("mode", json.string("ghost")),
      #("sentence_bitset", json.string(bit_array.base64_encode(bytes, True))),
      #("word_bitset", json.null()),
      #("current_page", json.int(5)),
      #("percent_progress", json.float(60.0)),
      #("updated_at", json.string("2026-05-12T02:00:00Z")),
    ])

  let response =
    simulate.browser_request(
      http.Put,
      "/api/books/" <> created.book.id <> "/state",
    )
    |> simulate.json_body(body)
    |> router.handle_request(ctx)
  assert response.status == 200

  let decoded = decode_body(response, reading_state_wire_decoder())
  assert decoded
    == ReadingState(
      book_id: created.book.id,
      mode: "ghost",
      sentence_bitset: Some(bytes),
      word_bitset: None,
      current_page: 5,
      percent_progress: 60.0,
      // Canonicalised to millisecond precision so all timestamps
      // share width — `parse_iso8601` always emits `.sss`.
      updated_at: Some("2026-05-12T02:00:00.000Z"),
    )

  // A subsequent GET must return the same payload — the upsert is
  // visible through the HTTP read path, not just by direct db query.
  let get_response = http_get_reading_state(ctx, created.book.id)
  assert decode_body(get_response, reading_state_wire_decoder()) == decoded
}

pub fn put_reading_state_stamps_books_last_read_at_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  let body = put_reading_state_body("manual", 2, "2026-05-12T04:00:00Z")
  let response = http_put_reading_state(ctx, created.book.id, body)
  assert response.status == 200

  // The book metadata returned by the listing endpoint should now
  // carry the same `last_read_at` the PUT used.
  let listing =
    router.handle_request(simulate.browser_request(http.Get, "/api/books"), ctx)
  let books = decode_body(listing, decode.list(book_meta_wire_decoder()))
  let expected =
    BookMetaWire(
      id: created.book.id,
      title: "Title",
      author: None,
      genre: None,
      word_count: 12,
      sentence_count: 2,
      uploaded_at: created.book.uploaded_at,
      last_read_at: Some("2026-05-12T04:00:00.000Z"),
    )
  assert books == [expected]
}

/// End-to-end LWW guard: a stale PUT must not regress either
/// `reading_state.updated_at` OR `books.last_read_at`. The SQL-layer
/// test below verifies the upsert predicate in isolation; this test
/// closes the seam at the HTTP layer where a successful fresh PUT is
/// followed by an older PUT — both the reading-state body and the
/// library listing's `last_read_at` must reflect the FRESH timestamp.
pub fn put_reading_state_rejects_stale_write_end_to_end_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  // Fresh write at 03:00 — lands.
  let fresh_body = put_reading_state_body("ghost", 7, "2026-05-12T03:00:00Z")
  let fresh_response = http_put_reading_state(ctx, created.book.id, fresh_body)
  assert fresh_response.status == 200
  let fresh_decoded = decode_body(fresh_response, reading_state_wire_decoder())
  assert fresh_decoded
    == ReadingState(
      book_id: created.book.id,
      mode: "ghost",
      sentence_bitset: None,
      word_bitset: None,
      current_page: 7,
      percent_progress: 0.0,
      updated_at: Some("2026-05-12T03:00:00.000Z"),
    )

  // Stale write at 02:00 — must be a no-op on disk. The server's
  // response still re-reads, so it surfaces the 03:00 row.
  let stale_body = put_reading_state_body("manual", 99, "2026-05-12T02:00:00Z")
  let stale_response = http_put_reading_state(ctx, created.book.id, stale_body)
  assert stale_response.status == 200
  let stale_decoded = decode_body(stale_response, reading_state_wire_decoder())
  assert stale_decoded == fresh_decoded

  // The reading-state read path agrees.
  let get_response = http_get_reading_state(ctx, created.book.id)
  assert decode_body(get_response, reading_state_wire_decoder())
    == fresh_decoded

  // Critically: the listing's `last_read_at` must STILL be the fresh
  // 03:00 timestamp, not the stale 02:00 one. An earlier iteration of
  // this code stamped `books.last_read_at` unconditionally, which
  // would have surfaced here as a 02:00 value — a silent disagreement
  // between the reading_state and books views of "when was this last
  // touched".
  let listing =
    router.handle_request(simulate.browser_request(http.Get, "/api/books"), ctx)
  let books = decode_body(listing, decode.list(book_meta_wire_decoder()))
  let expected =
    BookMetaWire(
      id: created.book.id,
      title: "Title",
      author: None,
      genre: None,
      word_count: 12,
      sentence_count: 2,
      uploaded_at: created.book.uploaded_at,
      last_read_at: Some("2026-05-12T03:00:00.000Z"),
    )
  assert books == [expected]
}

pub fn put_reading_state_rejects_unknown_mode_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let body = put_reading_state_body("rampage", 0, "2026-05-12T02:00:00Z")
  let response = http_put_reading_state(ctx, created.book.id, body)
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "mode")
  // Persisted state must not have changed — the empty default still
  // surfaces on a follow-up GET.
  let get_response = http_get_reading_state(ctx, created.book.id)
  let decoded = decode_body(get_response, reading_state_wire_decoder())
  assert decoded.updated_at == None
}

pub fn put_reading_state_rejects_garbage_updated_at_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  // `"ZZZZ"` is the canonical wedge-attempt timestamp: not a valid
  // ISO 8601 string but lexicographically greater than every real
  // RFC 3339 UTC string. The server must reject it at the boundary.
  let body = put_reading_state_body("manual", 0, "ZZZZ")
  let response = http_put_reading_state(ctx, created.book.id, body)
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "updated_at")
  // The persisted state should still be the empty default — no row
  // was wedged with a poisoned timestamp.
  let get_response = http_get_reading_state(ctx, created.book.id)
  let decoded = decode_body(get_response, reading_state_wire_decoder())
  assert decoded.updated_at == None
}

pub fn put_reading_state_canonicalises_updated_at_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  // An ISO 8601 timestamp with a numeric `+00:00` offset is equivalent
  // to a UTC timestamp; the server must canonicalise it to the `Z`
  // form so the SQL-side lexicographic comparison stays valid.
  // Sub-second precision is also normalised to millisecond width so
  // all stored timestamps share the same `.sss` suffix.
  let body = put_reading_state_body("manual", 0, "2026-05-12T02:00:00+00:00")
  let response = http_put_reading_state(ctx, created.book.id, body)
  assert response.status == 200
  let decoded = decode_body(response, reading_state_wire_decoder())
  assert decoded.updated_at == Some("2026-05-12T02:00:00.000Z")
}

/// A client that sends millisecond precision should see it preserved
/// in the canonical form — strict monotonicity of `updated_at` would
/// be silently broken if the server truncated to whole seconds.
pub fn put_reading_state_preserves_millisecond_precision_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let body = put_reading_state_body("manual", 0, "2026-05-12T02:00:00.250Z")
  let response = http_put_reading_state(ctx, created.book.id, body)
  assert response.status == 200
  let decoded = decode_body(response, reading_state_wire_decoder())
  assert decoded.updated_at == Some("2026-05-12T02:00:00.250Z")
}

pub fn put_reading_state_rejects_negative_current_page_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let body = put_reading_state_body("manual", -1, "2026-05-12T02:00:00Z")
  let response = http_put_reading_state(ctx, created.book.id, body)
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "current_page")
  // Persisted state should still be the empty default.
  let get_response = http_get_reading_state(ctx, created.book.id)
  let decoded = decode_body(get_response, reading_state_wire_decoder())
  assert decoded.updated_at == None
}

pub fn put_reading_state_for_missing_book_is_404_test() {
  use ctx <- with_context
  let body = put_reading_state_body("manual", 0, "2026-05-12T02:00:00Z")
  let response = http_put_reading_state(ctx, "nope", body)
  assert response.status == 404
  assert simulate.read_body(response) == "Not found"
}

/// Round-trip the new page-based `percent_progress` field end-to-end.
/// The PUT body carries an explicit value, the response echoes the
/// same value, and a subsequent GET resurfaces it from the
/// `reading_state.percent_progress` column. Pinning the full
/// `ReadingState` record (rather than just `.percent_progress`) keeps
/// the round-trip honest — a silent drop of any other field on either
/// side of the wire would otherwise slip through. The boundary value
/// `100.0` is folded into the same test so the validator's
/// accept-at-upper-bound path is exercised end-to-end alongside the
/// mid-range `42.5` round-trip.
pub fn put_reading_state_round_trips_percent_progress_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  // Mid-range value first. The response and the subsequent GET both
  // pin the *whole* `ReadingState` record, following the precedent of
  // `put_reading_state_round_trips_through_http_test`: pinning only
  // `.percent_progress` would let a silent drop of any other field
  // (current_page, mode, updated_at canonicalisation) slip through.
  let mid_body =
    json.object([
      #("mode", json.string("manual")),
      #("sentence_bitset", json.null()),
      #("word_bitset", json.null()),
      #("current_page", json.int(4)),
      #("percent_progress", json.float(42.5)),
      #("updated_at", json.string("2026-05-12T02:00:00Z")),
    ])
  let mid_response = http_put_reading_state(ctx, created.book.id, mid_body)
  assert mid_response.status == 200
  let mid_decoded = decode_body(mid_response, reading_state_wire_decoder())
  let mid_expected =
    ReadingState(
      book_id: created.book.id,
      mode: "manual",
      sentence_bitset: None,
      word_bitset: None,
      current_page: 4,
      percent_progress: 42.5,
      updated_at: Some("2026-05-12T02:00:00.000Z"),
    )
  assert mid_decoded == mid_expected

  let mid_get_response = http_get_reading_state(ctx, created.book.id)
  let mid_reloaded = decode_body(mid_get_response, reading_state_wire_decoder())
  assert mid_reloaded == mid_expected

  // Boundary case: `percent_progress == 100.0` is the most natural
  // value a reader on the last page sends, so it must round-trip
  // alongside the mid-range case. A later write at the upper bound
  // overwrites the mid-range row (LWW), so the reload pins the
  // boundary state — proving the validator accepts the upper bound
  // and the column stores it back unchanged.
  let upper_body =
    json.object([
      #("mode", json.string("manual")),
      #("sentence_bitset", json.null()),
      #("word_bitset", json.null()),
      #("current_page", json.int(9)),
      #("percent_progress", json.float(100.0)),
      #("updated_at", json.string("2026-05-12T03:00:00Z")),
    ])
  let upper_response = http_put_reading_state(ctx, created.book.id, upper_body)
  assert upper_response.status == 200
  let upper_decoded = decode_body(upper_response, reading_state_wire_decoder())
  let upper_expected =
    ReadingState(
      book_id: created.book.id,
      mode: "manual",
      sentence_bitset: None,
      word_bitset: None,
      current_page: 9,
      percent_progress: 100.0,
      updated_at: Some("2026-05-12T03:00:00.000Z"),
    )
  assert upper_decoded == upper_expected

  let upper_get_response = http_get_reading_state(ctx, created.book.id)
  let upper_reloaded =
    decode_body(upper_get_response, reading_state_wire_decoder())
  assert upper_reloaded == upper_expected
}

/// A PUT that omits `percent_progress` lands with the schema-default
/// of `0.0`. The optional-field decode on the server is what keeps an
/// older client that has not been redeployed yet from 400-ing on
/// every save — the value defaults to the same `0.0` the schema's
/// `DEFAULT 0.0` would inject for an `ALTER TABLE`-upgraded row.
pub fn put_reading_state_defaults_percent_progress_when_absent_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  // The PUT body omits `percent_progress` entirely (the
  // `put_reading_state_body` helper predates the field). Pinning the
  // whole `ReadingState` record proves that (a) the optional-field
  // decode injects `0.0`, and (b) no other field is mutated as a
  // side-effect of the default landing.
  let body = put_reading_state_body("manual", 3, "2026-05-12T02:00:00Z")
  let response = http_put_reading_state(ctx, created.book.id, body)
  assert response.status == 200
  let decoded = decode_body(response, reading_state_wire_decoder())
  let expected =
    ReadingState(
      book_id: created.book.id,
      mode: "manual",
      sentence_bitset: None,
      word_bitset: None,
      current_page: 3,
      percent_progress: 0.0,
      updated_at: Some("2026-05-12T02:00:00.000Z"),
    )
  assert decoded == expected

  let get_response = http_get_reading_state(ctx, created.book.id)
  let reloaded = decode_body(get_response, reading_state_wire_decoder())
  assert reloaded == expected
}

/// A PUT with a `percent_progress` outside `[0, 100]` is refused with
/// a 400 — the column stores a `REAL` and the schema would happily
/// accept a negative or oversize value, but the validator at the
/// handler boundary keeps the persisted value within the same range
/// the rest of the surface assumes.
pub fn put_reading_state_rejects_out_of_range_percent_progress_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  let too_high =
    json.object([
      #("mode", json.string("manual")),
      #("sentence_bitset", json.null()),
      #("word_bitset", json.null()),
      #("current_page", json.int(0)),
      #("percent_progress", json.float(150.0)),
      #("updated_at", json.string("2026-05-12T02:00:00Z")),
    ])
  let high_response = http_put_reading_state(ctx, created.book.id, too_high)
  assert high_response.status == 400
  assert string.contains(simulate.read_body(high_response), "percent_progress")

  let too_low =
    json.object([
      #("mode", json.string("manual")),
      #("sentence_bitset", json.null()),
      #("word_bitset", json.null()),
      #("current_page", json.int(0)),
      #("percent_progress", json.float(-0.1)),
      #("updated_at", json.string("2026-05-12T02:00:00Z")),
    ])
  let low_response = http_put_reading_state(ctx, created.book.id, too_low)
  assert low_response.status == 400
  assert string.contains(simulate.read_body(low_response), "percent_progress")
}

// ---------------------------------------------------------------------------
// Reading state — SQL layer
// ---------------------------------------------------------------------------

pub fn reading_state_upsert_last_write_wins_test() {
  use ctx <- with_context

  // Seed a book directly via the db layer; faster than going through
  // the HTTP create endpoint and still exercises the same SQL path.
  let assert Ok(Nil) =
    db.create_book(
      ctx.db,
      id: "book-1",
      title: "Test",
      author: None,
      genre: None,
      raw_text: "Sentence one. Sentence two.",
      segments_json: "{\"chapters\":[]}",
      word_count: 4,
      sentence_count: 2,
      uploaded_at: "2026-05-12T00:00:00Z",
    )

  // First write at t = 2:00:00.
  let assert Ok(Nil) =
    db.update_reading_state(
      ctx.db,
      book_id: "book-1",
      mode: "manual",
      sentence_bitset: None,
      word_bitset: None,
      current_page: 3,
      percent_progress: 30.0,
      updated_at: "2026-05-12T02:00:00Z",
    )

  // Stale write at t = 1:00:00 — should be ignored by the
  // last-write-wins guard.
  let assert Ok(Nil) =
    db.update_reading_state(
      ctx.db,
      book_id: "book-1",
      mode: "ghost",
      sentence_bitset: None,
      word_bitset: None,
      current_page: 99,
      percent_progress: 99.0,
      updated_at: "2026-05-12T01:00:00Z",
    )

  // The newer write at 02:00 should still be visible. Assert the
  // whole record so a regression that overwrites any one field
  // surfaces as a value mismatch on the first hit.
  let assert Ok(Some(state)) = db.get_reading_state(ctx.db, "book-1")
  assert state
    == ReadingState(
      book_id: "book-1",
      mode: "manual",
      sentence_bitset: None,
      word_bitset: None,
      current_page: 3,
      percent_progress: 30.0,
      updated_at: Some("2026-05-12T02:00:00Z"),
    )

  // Newer write at t = 3:00:00 should land.
  let assert Ok(Nil) =
    db.update_reading_state(
      ctx.db,
      book_id: "book-1",
      mode: "ghost",
      sentence_bitset: Some(<<1, 2, 3>>),
      word_bitset: Some(<<4, 5, 6>>),
      current_page: 7,
      percent_progress: 70.0,
      updated_at: "2026-05-12T03:00:00Z",
    )
  let assert Ok(Some(state)) = db.get_reading_state(ctx.db, "book-1")
  assert state
    == ReadingState(
      book_id: "book-1",
      mode: "ghost",
      sentence_bitset: Some(<<1, 2, 3>>),
      word_bitset: Some(<<4, 5, 6>>),
      current_page: 7,
      percent_progress: 70.0,
      updated_at: Some("2026-05-12T03:00:00Z"),
    )
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

pub fn settings_default_row_exists_test() {
  use ctx <- with_context
  let assert Ok(settings) = db.get_settings(ctx.db)
  // Assert the entire defaults record so that drift on any one
  // schema default — `ghost_opacity`, `default_wpm`, etc. — is
  // caught here rather than passing silently.
  assert settings == default_user_settings
}

pub fn settings_get_endpoint_returns_defaults_test() {
  use ctx <- with_context
  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/settings"),
      ctx,
    )
  assert response.status == 200
  let decoded = decode_body(response, user_settings_wire_decoder())
  assert decoded == default_user_settings
}

pub fn settings_update_round_trips_test() {
  use ctx <- with_context
  let new_settings =
    types.UserSettings(
      font_size: 24,
      line_spacing: 2.0,
      dark_mode: False,
      ghost_mode: True,
      ghost_opacity: 0.15,
      default_wpm: 300,
      default_paragraph_delay_ms: 500,
      default_page_delay_ms: 1500,
    )
  let assert Ok(Nil) = db.update_settings(ctx.db, new_settings)
  let assert Ok(read_back) = db.get_settings(ctx.db)
  assert read_back == new_settings
}

pub fn settings_put_rejects_out_of_range_values_test() {
  use ctx <- with_context
  // Each field is exercised in isolation by starting from a known-
  // good record and poisoning one value. Asserting the body contains
  // the field name keeps the test honest about which validator fired.
  let cases = [
    #(
      "font_size",
      types.UserSettings(..valid_settings(), font_size: -1),
      "font_size",
    ),
    #(
      "line_spacing",
      types.UserSettings(..valid_settings(), line_spacing: 0.0),
      "line_spacing",
    ),
    #(
      "ghost_opacity_high",
      types.UserSettings(..valid_settings(), ghost_opacity: 7.5),
      "ghost_opacity",
    ),
    #(
      "ghost_opacity_low",
      types.UserSettings(..valid_settings(), ghost_opacity: -0.1),
      "ghost_opacity",
    ),
    #(
      "default_wpm",
      types.UserSettings(..valid_settings(), default_wpm: 0),
      "default_wpm",
    ),
    #(
      "default_paragraph_delay_ms",
      types.UserSettings(..valid_settings(), default_paragraph_delay_ms: -1),
      "default_paragraph_delay_ms",
    ),
    #(
      "default_page_delay_ms",
      types.UserSettings(..valid_settings(), default_page_delay_ms: -1),
      "default_page_delay_ms",
    ),
  ]
  list.each(cases, fn(case_) {
    let #(_name, bad_settings, expected_field) = case_
    let response =
      simulate.browser_request(http.Put, "/api/settings")
      |> simulate.json_body(user_settings_to_json(bad_settings))
      |> router.handle_request(ctx)
    assert response.status == 400
    assert string.contains(simulate.read_body(response), expected_field)
  })
  // Settings on disk should still be the defaults — none of the bad
  // writes can have squeaked through.
  let get_response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/settings"),
      ctx,
    )
  assert decode_body(get_response, user_settings_wire_decoder())
    == default_user_settings
}

fn valid_settings() -> UserSettings {
  default_user_settings
}

pub fn settings_put_endpoint_round_trips_test() {
  use ctx <- with_context
  let new_settings =
    types.UserSettings(
      font_size: 20,
      line_spacing: 1.8,
      dark_mode: False,
      ghost_mode: True,
      ghost_opacity: 0.1,
      default_wpm: 250,
      default_paragraph_delay_ms: 800,
      default_page_delay_ms: 1700,
    )
  let response =
    simulate.browser_request(http.Put, "/api/settings")
    |> simulate.json_body(user_settings_to_json(new_settings))
    |> router.handle_request(ctx)
  assert response.status == 200
  let put_decoded = decode_body(response, user_settings_wire_decoder())
  assert put_decoded == new_settings

  // A follow-up GET must echo the same record — the PUT actually
  // persisted, not just reflected the input back.
  let get_response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/settings"),
      ctx,
    )
  assert decode_body(get_response, user_settings_wire_decoder()) == new_settings
}

// ---------------------------------------------------------------------------
// Book settings
// ---------------------------------------------------------------------------

pub fn book_settings_get_for_unwritten_book_returns_all_null_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let response = http_get_book_settings(ctx, created.book.id)
  assert response.status == 200
  // No row → an all-null record so the client can decode with a single
  // shape regardless of whether the book has overrides yet.
  let decoded = decode_body(response, book_settings_wire_decoder())
  assert decoded == types.empty_book_settings()
}

pub fn book_settings_get_for_missing_book_is_404_test() {
  use ctx <- with_context
  let response = http_get_book_settings(ctx, "no-such-book")
  assert response.status == 404
  assert simulate.read_body(response) == "Not found"
}

pub fn book_settings_put_for_missing_book_is_404_test() {
  use ctx <- with_context
  let body = book_settings_to_json(types.empty_book_settings())
  let response =
    simulate.browser_request(http.Put, "/api/books/no-such-book/settings")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)
  assert response.status == 404
}

pub fn book_settings_put_round_trips_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let new_settings =
    BookSettings(
      wpm: Some(350),
      paragraph_delay_ms: Some(400),
      page_delay_ms: Some(900),
      ghost_opacity: Some(0.2),
    )

  let response = http_put_book_settings(ctx, created.book.id, new_settings)
  assert response.status == 200
  let put_decoded = decode_body(response, book_settings_wire_decoder())
  assert put_decoded == new_settings

  // The GET reflects what was just persisted.
  let get_response = http_get_book_settings(ctx, created.book.id)
  assert decode_body(get_response, book_settings_wire_decoder()) == new_settings
}

pub fn book_settings_put_clears_overrides_with_all_null_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  // Seed with overrides…
  let with_overrides =
    BookSettings(
      wpm: Some(100),
      paragraph_delay_ms: Some(50),
      page_delay_ms: None,
      ghost_opacity: Some(0.1),
    )
  let seed_response =
    http_put_book_settings(ctx, created.book.id, with_overrides)
  assert seed_response.status == 200

  // …then clear them.
  let cleared_response =
    http_put_book_settings(ctx, created.book.id, types.empty_book_settings())
  assert cleared_response.status == 200
  assert decode_body(cleared_response, book_settings_wire_decoder())
    == types.empty_book_settings()

  // GET must reflect the cleared state — INSERT OR REPLACE keeps the
  // row but every column is now SQL NULL, so the wire form is the
  // all-null record.
  let get_response = http_get_book_settings(ctx, created.book.id)
  assert decode_body(get_response, book_settings_wire_decoder())
    == types.empty_book_settings()
}

pub fn book_settings_put_rejects_out_of_range_values_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let cases = [
    #("wpm", BookSettings(..types.empty_book_settings(), wpm: Some(0)), "wpm"),
    #(
      "paragraph_delay_ms",
      BookSettings(..types.empty_book_settings(), paragraph_delay_ms: Some(-5)),
      "paragraph_delay_ms",
    ),
    #(
      "page_delay_ms",
      BookSettings(..types.empty_book_settings(), page_delay_ms: Some(-1)),
      "page_delay_ms",
    ),
    #(
      "ghost_opacity_high",
      BookSettings(..types.empty_book_settings(), ghost_opacity: Some(1.5)),
      "ghost_opacity",
    ),
    #(
      "ghost_opacity_low",
      BookSettings(..types.empty_book_settings(), ghost_opacity: Some(-0.2)),
      "ghost_opacity",
    ),
  ]
  list.each(cases, fn(case_) {
    let #(_name, bad_settings, expected_field) = case_
    let response = http_put_book_settings(ctx, created.book.id, bad_settings)
    assert response.status == 400
    assert string.contains(simulate.read_body(response), expected_field)
  })
  // None of the bad writes squeaked through — the GET still surfaces
  // the all-null default.
  let get_response = http_get_book_settings(ctx, created.book.id)
  assert decode_body(get_response, book_settings_wire_decoder())
    == types.empty_book_settings()
}

pub fn book_settings_put_accepts_partial_overrides_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  // Only `wpm` is set — the other three fall back to the global
  // default through the client merge; the server persists exactly
  // what the wire carries.
  let partial =
    BookSettings(
      wpm: Some(275),
      paragraph_delay_ms: None,
      page_delay_ms: None,
      ghost_opacity: None,
    )
  let response = http_put_book_settings(ctx, created.book.id, partial)
  assert response.status == 200
  let get_response = http_get_book_settings(ctx, created.book.id)
  assert decode_body(get_response, book_settings_wire_decoder()) == partial
}

// ---------------------------------------------------------------------------
// Delete book
// ---------------------------------------------------------------------------

pub fn delete_book_returns_204_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Doomed Book", None, sample_text)
  let response =
    router.handle_request(
      simulate.browser_request(http.Delete, "/api/books/" <> created.book.id),
      ctx,
    )
  assert response.status == 204
}

pub fn delete_book_not_found_returns_404_test() {
  use ctx <- with_context
  let response =
    router.handle_request(
      simulate.browser_request(http.Delete, "/api/books/no-such-book"),
      ctx,
    )
  assert response.status == 404
}

pub fn delete_book_removes_from_list_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Ephemeral", None, sample_text)

  // Verify it appears in the listing before deletion.
  let before_resp =
    router.handle_request(simulate.browser_request(http.Get, "/api/books"), ctx)
  let before = decode_body(before_resp, decode.list(book_meta_wire_decoder()))
  assert list.any(before, fn(b) { b.id == created.book.id })

  // Pin the delete response status. A drop to `let _` would let a
  // 500 (or a 404 from a latent id-encoding bug) slip past, with
  // the after-list assertion below silently doing the work of two
  // — we want to know which step broke if either does.
  let delete_resp =
    router.handle_request(
      simulate.browser_request(http.Delete, "/api/books/" <> created.book.id),
      ctx,
    )
  assert delete_resp.status == 204

  // Must no longer appear after deletion.
  let after_resp =
    router.handle_request(simulate.browser_request(http.Get, "/api/books"), ctx)
  let after = decode_body(after_resp, decode.list(book_meta_wire_decoder()))
  assert !list.any(after, fn(b) { b.id == created.book.id })
}

pub fn delete_book_cascades_reading_state_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "With State", None, sample_text)
  let id = created.book.id

  // Write a reading state row, and pin that the PUT actually
  // succeeded — a 200 is the only thing that proves we have a row
  // for the subsequent DELETE to cascade. Discarding this response
  // would let a future tightening of `validate_reading_state_input`
  // (or any other PUT-side regression) leave the row unwritten,
  // after which the cascade has nothing to remove and the final
  // `state == None` assertion passes trivially.
  let put_resp =
    http_put_reading_state(
      ctx,
      id,
      put_reading_state_body("manual", 0, "2026-05-13T00:00:00Z"),
    )
  assert put_resp.status == 200

  // Belt-and-braces: read the dependent row directly so the test
  // distinguishes "the cascade worked" from "there was nothing to
  // cascade". Without this read, a PUT that returned 200 but
  // silently wrote nothing would still pass the post-delete check.
  let assert Ok(Some(_)) = db.get_reading_state(ctx.db, id)

  // Delete the book; the reading_state row must cascade.
  let delete_resp =
    router.handle_request(
      simulate.browser_request(http.Delete, "/api/books/" <> id),
      ctx,
    )
  assert delete_resp.status == 204

  // Direct db check: reading_state row must be gone.
  let assert Ok(state) = db.get_reading_state(ctx.db, id)
  assert state == None
}

pub fn delete_book_cascades_book_settings_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "With Settings", None, sample_text)
  let id = created.book.id

  // Write a book_settings row. As above, pin the PUT status so a
  // silent failure on the write path cannot make this cascade test
  // pass for the wrong reason.
  let put_resp =
    http_put_book_settings(
      ctx,
      id,
      BookSettings(
        wpm: Some(300),
        paragraph_delay_ms: None,
        page_delay_ms: None,
        ghost_opacity: None,
      ),
    )
  assert put_resp.status == 200

  // Confirm the dependent row exists before the cascade runs.
  let assert Ok(Some(_)) = db.get_book_settings(ctx.db, id)

  // Delete the book; the book_settings row must cascade.
  let delete_resp =
    router.handle_request(
      simulate.browser_request(http.Delete, "/api/books/" <> id),
      ctx,
    )
  assert delete_resp.status == 204

  // Direct db check: book_settings row must be gone.
  let assert Ok(settings) = db.get_book_settings(ctx.db, id)
  assert settings == None
}

// ---------------------------------------------------------------------------
// Reading sessions — HTTP layer
// ---------------------------------------------------------------------------

pub fn post_session_creates_row_and_returns_201_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let response =
    http_post_session(ctx, created.book.id, "session-1", "2026-05-12T10:00:00Z")
  assert response.status == 201

  let decoded = decode_body(response, reading_session_wire_decoder())
  assert decoded
    == ReadingSession(
      id: "session-1",
      book_id: created.book.id,
      started_at: "2026-05-12T10:00:00.000Z",
      ended_at: None,
      words_read: 0,
      words_skipped: 0,
      pages_turned: 0,
      duration_seconds: 0,
    )

  // Belt-and-braces: read directly from the DB to confirm the row
  // landed — without this a future regression that fakes the
  // response body would still pass the HTTP-level assertion.
  let assert Ok(Some(row)) =
    db_sessions.get_reading_session(ctx.db, "session-1")
  assert row == decoded
}

pub fn post_session_for_missing_book_is_404_test() {
  use ctx <- with_context
  let response =
    http_post_session(ctx, "no-such-book", "s1", "2026-05-12T10:00:00Z")
  assert response.status == 404
}

pub fn post_session_rejects_empty_id_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let response =
    http_post_session(ctx, created.book.id, "", "2026-05-12T10:00:00Z")
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "id")
}

pub fn post_session_rejects_garbage_started_at_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let response = http_post_session(ctx, created.book.id, "s1", "ZZZZ")
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "started_at")
}

pub fn put_session_round_trips_through_http_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let _ =
    http_post_session(ctx, created.book.id, "session-1", "2026-05-12T10:00:00Z")

  let body = end_session_body("2026-05-12T10:05:00Z", 120, 30, 4, 300)
  let response = http_put_session(ctx, created.book.id, "session-1", body)
  assert response.status == 200

  let decoded = decode_body(response, reading_session_wire_decoder())
  assert decoded
    == ReadingSession(
      id: "session-1",
      book_id: created.book.id,
      started_at: "2026-05-12T10:00:00.000Z",
      ended_at: Some("2026-05-12T10:05:00.000Z"),
      words_read: 120,
      words_skipped: 30,
      pages_turned: 4,
      duration_seconds: 300,
    )
}

/// The client's `pagehide`/`sendBeacon` durability path flushes the
/// closing counters by POSTing to the item endpoint — `sendBeacon`
/// only supports POST, so the dispatcher in `server/sessions.gleam`
/// routes Post → put_session_handler. Pin both the 200 status and
/// the persisted row shape so a future edit that removes the Post
/// arm fails this test loudly rather than silently breaking the
/// beacon path.
pub fn post_session_update_round_trips_through_http_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let _ =
    http_post_session(ctx, created.book.id, "session-1", "2026-05-12T10:00:00Z")

  let body = end_session_body("2026-05-12T10:05:00Z", 120, 30, 4, 300)
  let response =
    http_post_session_update(ctx, created.book.id, "session-1", body)
  assert response.status == 200

  let decoded = decode_body(response, reading_session_wire_decoder())
  assert decoded
    == ReadingSession(
      id: "session-1",
      book_id: created.book.id,
      started_at: "2026-05-12T10:00:00.000Z",
      ended_at: Some("2026-05-12T10:05:00.000Z"),
      words_read: 120,
      words_skipped: 30,
      pages_turned: 4,
      duration_seconds: 300,
    )

  // And the row truly persisted — fetching the session from the DB
  // returns the same closed shape. A handler that 200s without
  // writing would slip past the status-only assertion above.
  let assert Ok(Some(persisted)) =
    db_sessions.get_reading_session(ctx.db, "session-1")
  assert persisted
    == ReadingSession(
      id: "session-1",
      book_id: created.book.id,
      started_at: "2026-05-12T10:00:00.000Z",
      ended_at: Some("2026-05-12T10:05:00.000Z"),
      words_read: 120,
      words_skipped: 30,
      pages_turned: 4,
      duration_seconds: 300,
    )
}

pub fn put_session_with_mismatched_book_id_is_404_test() {
  use ctx <- with_context
  let book_a = http_create_book(ctx, "A", None, sample_text)
  let book_b = http_create_book(ctx, "B", None, sample_text)
  let _ =
    http_post_session(ctx, book_a.book.id, "session-1", "2026-05-12T10:00:00Z")

  let body = end_session_body("2026-05-12T10:05:00Z", 1, 0, 0, 60)
  // The session belongs to book A, but the URL claims book B —
  // the row's parent is immutable so the handler must refuse.
  let response = http_put_session(ctx, book_b.book.id, "session-1", body)
  assert response.status == 404
}

pub fn put_session_rejects_negative_counters_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let _ =
    http_post_session(ctx, created.book.id, "session-1", "2026-05-12T10:00:00Z")
  let body = end_session_body("2026-05-12T10:05:00Z", -1, 0, 0, 0)
  let response = http_put_session(ctx, created.book.id, "session-1", body)
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "words_read")
}

pub fn put_session_for_missing_id_is_404_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let body = end_session_body("2026-05-12T10:05:00Z", 1, 0, 0, 60)
  let response = http_put_session(ctx, created.book.id, "no-such-session", body)
  assert response.status == 404
}

pub fn delete_book_cascades_reading_sessions_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "With Sessions", None, sample_text)
  let id = created.book.id
  let post_resp =
    http_post_session(ctx, id, "session-1", "2026-05-12T10:00:00Z")
  assert post_resp.status == 201
  let assert Ok(Some(_)) = db_sessions.get_reading_session(ctx.db, "session-1")

  let delete_resp =
    router.handle_request(
      simulate.browser_request(http.Delete, "/api/books/" <> id),
      ctx,
    )
  assert delete_resp.status == 204

  let assert Ok(missing) = db_sessions.get_reading_session(ctx.db, "session-1")
  assert missing == None
}

// ---------------------------------------------------------------------------
// Stats — aggregate endpoints
// ---------------------------------------------------------------------------

pub fn get_book_stats_for_book_with_no_sessions_returns_zero_record_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let response =
    router.handle_request(
      simulate.browser_request(
        http.Get,
        "/api/books/" <> created.book.id <> "/stats",
      ),
      ctx,
    )
  assert response.status == 200
  let decoded = decode_body(response, stats.book_stats_decoder())
  assert decoded == BookStats(0, 0, 0, 0, 0.0)
}

pub fn get_book_stats_for_missing_book_is_404_test() {
  use ctx <- with_context
  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/books/no-such-book/stats"),
      ctx,
    )
  assert response.status == 404
}

/// The library card needs `BookStats.percent_progress` to render the
/// page-based progress percentage without re-deriving from the
/// session counters. The SQL query for `get_book_stats` joins
/// `reading_state` against `reading_sessions` so the field arrives
/// alongside the aggregates; this test pins the seam by writing a
/// reading-state row, recording a session, and asserting both the
/// scalar query (`GET /api/books/:id/stats`) and the bulk listing
/// (`GET /api/stats/books`) surface the persisted percentage.
pub fn book_stats_surfaces_percent_progress_from_reading_state_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let id = created.book.id

  // Stamp `reading_state.percent_progress` to a non-default value.
  let state_body =
    json.object([
      #("mode", json.string("manual")),
      #("sentence_bitset", json.null()),
      #("word_bitset", json.null()),
      #("current_page", json.int(3)),
      #("percent_progress", json.float(73.5)),
      #("updated_at", json.string("2026-05-12T02:00:00Z")),
    ])
  let _ = http_put_reading_state(ctx, id, state_body)

  // One recorded session so the book appears in the bulk listing too
  // (which groups by `reading_sessions.book_id`).
  let _ = http_post_session(ctx, id, "s1", "2026-05-12T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      id,
      "s1",
      end_session_body("2026-05-12T10:30:00Z", 100, 0, 5, 1800),
    )

  // Pin the *whole* `BookStats` record on both the scalar and bulk
  // surfaces. The session-aggregate fields come from
  // `reading_sessions` (the single recorded session above), and
  // `percent_progress` rides in from the `reading_state` join — so
  // the full assertion proves both halves of the JOIN seam at once
  // and catches a silent drop of any other field.
  let expected_stats =
    BookStats(
      total_words_read: 100,
      total_words_skipped: 0,
      total_duration_seconds: 1800,
      session_count: 1,
      percent_progress: 73.5,
    )

  let scalar =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/books/" <> id <> "/stats"),
      ctx,
    )
  assert decode_body(scalar, stats.book_stats_decoder()) == expected_stats

  let listing =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/stats/books"),
      ctx,
    )
  let entries =
    decode_body(listing, decode.list(stats.book_stats_entry_decoder()))
  assert entries == [#(id, expected_stats)]
}

pub fn get_book_stats_aggregates_across_sessions_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)
  let id = created.book.id

  // Two sessions for the same book — the aggregate must SUM their
  // counter fields and report a session_count of 2.
  let _ = http_post_session(ctx, id, "s1", "2026-05-12T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      id,
      "s1",
      end_session_body("2026-05-12T10:30:00Z", 100, 20, 5, 1800),
    )
  let _ = http_post_session(ctx, id, "s2", "2026-05-13T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      id,
      "s2",
      end_session_body("2026-05-13T10:15:00Z", 50, 0, 2, 900),
    )

  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/books/" <> id <> "/stats"),
      ctx,
    )
  assert response.status == 200
  let decoded = decode_body(response, stats.book_stats_decoder())
  // `percent_progress` is `0.0` because no reading-state row has been
  // PUT for this book — sessions alone do not stamp the progress
  // column. The next reader-side save would overwrite the default.
  assert decoded
    == BookStats(
      total_words_read: 150,
      total_words_skipped: 20,
      total_duration_seconds: 2700,
      session_count: 2,
      percent_progress: 0.0,
    )
}

pub fn get_library_stats_aggregates_across_books_test() {
  use ctx <- with_context
  let book_a = http_create_book(ctx, "A", None, sample_text)
  let book_b = http_create_book(ctx, "B", None, sample_text)

  let _ = http_post_session(ctx, book_a.book.id, "a1", "2026-05-12T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      book_a.book.id,
      "a1",
      end_session_body("2026-05-12T10:30:00Z", 5, 0, 2, 1800),
    )
  let _ = http_post_session(ctx, book_b.book.id, "b1", "2026-05-13T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      book_b.book.id,
      "b1",
      end_session_body("2026-05-13T10:15:00Z", 3, 12, 1, 900),
    )

  let response =
    router.handle_request(simulate.browser_request(http.Get, "/api/stats"), ctx)
  assert response.status == 200
  let decoded = decode_body(response, stats.library_stats_decoder())
  // The two books in this test each carry `sample_text` (12 words);
  // book A's session covers 5 reading + 0 skipped (under 12) and
  // book B covers 3 + 12 = 15 (>=12). Books completed is therefore 1.
  // The current_streak_days field is computed against the test
  // environment's wall clock, so we pin every other field and leave
  // the streak loose — a hard-coded value would couple this test to
  // the calendar date the CI machine happens to be running on.
  assert decoded.total_words_read == 8
  assert decoded.total_duration_seconds == 2700
  assert decoded.books_completed == 1
  assert decoded.current_streak_days >= 0
}

pub fn get_library_book_stats_returns_per_book_entries_test() {
  use ctx <- with_context
  let book_a = http_create_book(ctx, "A", None, sample_text)
  let book_b = http_create_book(ctx, "B", None, sample_text)

  let _ = http_post_session(ctx, book_a.book.id, "a1", "2026-05-12T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      book_a.book.id,
      "a1",
      end_session_body("2026-05-12T10:30:00Z", 7, 1, 2, 1800),
    )
  let _ = http_post_session(ctx, book_b.book.id, "b1", "2026-05-13T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      book_b.book.id,
      "b1",
      end_session_body("2026-05-13T10:15:00Z", 3, 0, 1, 900),
    )

  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/stats/books"),
      ctx,
    )
  assert response.status == 200
  let entries =
    decode_body(response, decode.list(stats.book_stats_entry_decoder()))
  // Sort by book_id so the assertion does not depend on rowid order
  // out of SQLite — different schema migrations could shuffle the
  // GROUP BY's natural ordering.
  let sorted = list.sort(entries, fn(a, b) { string.compare(a.0, b.0) })
  let book_a_stats = BookStats(7, 1, 1800, 1, 0.0)
  let book_b_stats = BookStats(3, 0, 900, 1, 0.0)
  let expected = case string.compare(book_a.book.id, book_b.book.id) {
    order.Lt -> [
      #(book_a.book.id, book_a_stats),
      #(book_b.book.id, book_b_stats),
    ]
    _ -> [#(book_b.book.id, book_b_stats), #(book_a.book.id, book_a_stats)]
  }
  assert sorted == expected
}

pub fn get_speed_trend_returns_recent_session_speeds_test() {
  // The endpoint returns the most recent N session speeds with
  // non-zero `words_read` and `duration_seconds`. WPM is computed
  // server-side as `words_read * 60 / duration_seconds` — for the
  // first session below (5 words / 60 seconds = 5 wpm), and for the
  // second (60 words / 60 seconds = 60 wpm). The endpoint returns
  // the most-recent session first.
  use ctx <- with_context
  let book = http_create_book(ctx, "A", None, sample_text)
  let _ = http_post_session(ctx, book.book.id, "s1", "2026-05-12T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      book.book.id,
      "s1",
      end_session_body("2026-05-12T10:01:00Z", 5, 0, 1, 60),
    )
  let _ = http_post_session(ctx, book.book.id, "s2", "2026-05-13T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      book.book.id,
      "s2",
      end_session_body("2026-05-13T10:01:00Z", 60, 0, 1, 60),
    )

  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/stats/speed"),
      ctx,
    )
  assert response.status == 200
  let decoded =
    decode_body(response, decode.list(stats.session_speed_decoder()))
  // Most-recent first — `s2` (60 wpm) leads, `s1` (5 wpm) follows.
  // The dates round-trip through the server's
  // canonicalisation pass and come back with millisecond precision.
  let wpms = list.map(decoded, fn(s) { s.wpm })
  assert wpms == [60, 5]
}

pub fn get_speed_trend_skips_zero_duration_sessions_test() {
  // A session with `duration_seconds == 0` cannot produce a
  // meaningful WPM (division by zero), and a session with
  // `words_read == 0` would always be 0 wpm regardless of duration.
  // Both are filtered out at the SQL level so the rendered sparkline
  // only shows sessions with actual engagement.
  use ctx <- with_context
  let book = http_create_book(ctx, "A", None, sample_text)
  let _ = http_post_session(ctx, book.book.id, "s1", "2026-05-12T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      book.book.id,
      "s1",
      end_session_body("2026-05-12T10:00:00Z", 5, 0, 0, 0),
    )
  let _ = http_post_session(ctx, book.book.id, "s2", "2026-05-13T10:00:00Z")
  let _ =
    http_put_session(
      ctx,
      book.book.id,
      "s2",
      end_session_body("2026-05-13T10:01:00Z", 0, 0, 0, 60),
    )

  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/stats/speed"),
      ctx,
    )
  assert response.status == 200
  let decoded =
    decode_body(response, decode.list(stats.session_speed_decoder()))
  assert decoded == []
}

pub fn get_speed_trend_caps_at_twenty_recent_sessions_test() {
  // The endpoint returns at most 20 entries — the client renders the
  // result as a 200×40 SVG sparkline and cannot resolve more than a
  // few dozen samples anyway, so the handler caps the result set at
  // SQL level via `LIMIT 20`. Inserting 21 sessions with distinct,
  // monotonically-increasing `started_at` and matching wpms lets us
  // assert that the oldest session is the one dropped, not merely
  // that the list was truncated.
  use ctx <- with_context
  let book = http_create_book(ctx, "A", None, sample_text)
  // Each session i in 1..21 has:
  //   * started_at "2026-05-DD<i>T10:00:00Z" — day = pad(i)
  //   * words_read = i, duration_seconds = 60 → wpm = i
  // So the full inserted set spans wpms 1..21; under DESC ordering
  // the top 20 are wpms 21..2 (wpm = 1 is the oldest, dropped).
  //
  // `int.range` runs the reducer for `from` inclusive, `to` exclusive,
  // so `int.range(1, 22, ...)` covers the integers 1..21.
  let session_indices =
    int.range(from: 1, to: 22, with: [], run: list.prepend)
    |> list.reverse
  list.each(session_indices, fn(i) {
    let day = case i < 10 {
      True -> "0" <> int.to_string(i)
      False -> int.to_string(i)
    }
    let session_id = "s" <> int.to_string(i)
    let started_at = "2026-05-" <> day <> "T10:00:00Z"
    let ended_at = "2026-05-" <> day <> "T10:01:00Z"
    let _ = http_post_session(ctx, book.book.id, session_id, started_at)
    let _ =
      http_put_session(
        ctx,
        book.book.id,
        session_id,
        end_session_body(ended_at, i, 0, 1, 60),
      )
    Nil
  })

  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/stats/speed"),
      ctx,
    )
  assert response.status == 200
  let decoded =
    decode_body(response, decode.list(stats.session_speed_decoder()))
  // 21 inserted, 20 returned, ordered most-recent first. Prepending
  // the integers 2..21 yields [21, 20, ..., 2] — the wpms of the
  // newest 20 sessions, in DESC order. Asserting on the whole list
  // (not just `list.length`) pins both the cap and the ordering, so
  // a regression that flipped the LIMIT or the ORDER BY would
  // surface here.
  let wpms = list.map(decoded, fn(s) { s.wpm })
  let expected_wpms = int.range(from: 2, to: 22, with: [], run: list.prepend)
  assert wpms == expected_wpms
}

// The four `compute_current_streak_days_*` tests live in
// `shared/test/stats_test.gleam` — the function under test is pure
// shared logic and its tests now live next to the function rather
// than across the shared / server package boundary.

// ---------------------------------------------------------------------------
// Books — metadata PATCH
// ---------------------------------------------------------------------------

pub fn create_book_with_genre_round_trips_through_wire_test() {
  use ctx <- with_context

  let body =
    json.object([
      #("title", json.string("Dune")),
      #("author", json.string("Frank Herbert")),
      #("genre", json.string("Science Fiction")),
      #("text", json.string(sample_text)),
    ])

  let response =
    simulate.browser_request(http.Post, "/api/books")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 201
  let decoded = decode_body(response, book_create_response_decoder())
  assert decoded.book.author == Some("Frank Herbert")
  assert decoded.book.genre == Some("Science Fiction")

  // Listing endpoint reflects the new field too.
  let listing =
    router.handle_request(simulate.browser_request(http.Get, "/api/books"), ctx)
  let books = decode_body(listing, decode.list(book_meta_wire_decoder()))
  assert books == [decoded.book]
}

pub fn patch_book_metadata_updates_all_three_fields_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Original", None, sample_text)

  let body =
    json.object([
      #("title", json.string("Renamed")),
      #("author", json.string("New Author")),
      #("genre", json.string("Fantasy")),
    ])

  let response =
    simulate.browser_request(http.Patch, "/api/books/" <> created.book.id)
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 200

  // Assert the WHOLE payload. Three individual-field assertions would
  // leave `id`, `word_count`, `sentence_count`, `uploaded_at`, and
  // `last_read_at` unchecked — a silent drift in any of them on the
  // PATCH path would slip through. Following the file's preamble
  // convention.
  let decoded = decode_body(response, book_meta_wire_decoder())
  let expected_meta =
    BookMetaWire(
      id: created.book.id,
      title: "Renamed",
      author: Some("New Author"),
      genre: Some("Fantasy"),
      word_count: created.book.word_count,
      sentence_count: created.book.sentence_count,
      uploaded_at: created.book.uploaded_at,
      last_read_at: None,
    )
  assert decoded == expected_meta

  // Subsequent GET reflects the persisted values — full payload again.
  let after =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/books/" <> created.book.id),
      ctx,
    )
  let after_decoded = decode_body(after, book_full_decoder())
  let expected_full =
    BookFullWire(
      id: created.book.id,
      title: "Renamed",
      author: Some("New Author"),
      genre: Some("Fantasy"),
      raw_text: sample_text,
      word_count: created.book.word_count,
      sentence_count: created.book.sentence_count,
      uploaded_at: created.book.uploaded_at,
      last_read_at: None,
      segments: segmenter.segment(sample_text),
    )
  assert after_decoded == expected_full
}

pub fn patch_book_metadata_preserves_untouched_fields_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", Some("Author"), sample_text)

  // PATCH only `genre` — title and author must remain untouched.
  let body = json.object([#("genre", json.string("Mystery"))])

  let response =
    simulate.browser_request(http.Patch, "/api/books/" <> created.book.id)
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 200
  let decoded = decode_body(response, book_meta_wire_decoder())
  let expected =
    BookMetaWire(
      id: created.book.id,
      title: "Title",
      author: Some("Author"),
      genre: Some("Mystery"),
      word_count: created.book.word_count,
      sentence_count: created.book.sentence_count,
      uploaded_at: created.book.uploaded_at,
      last_read_at: None,
    )
  assert decoded == expected
}

pub fn patch_book_metadata_clears_author_via_null_preserves_genre_test() {
  // Seed the book with BOTH author and genre populated, then PATCH
  // only `author: null`. The full-payload assertion verifies that
  // `genre` survives unchanged — were `resolve_metadata_field` to
  // accidentally apply `Cleared` to the wrong column, this test
  // would catch it (the original R1 version seeded `genre: None`,
  // so a cross-field bug would have been invisible).
  use ctx <- with_context
  let created =
    http_create_book_full(
      ctx,
      "Title",
      Some("Author"),
      Some("Fantasy"),
      sample_text,
    )

  let body = json.object([#("author", json.null())])

  let response =
    simulate.browser_request(http.Patch, "/api/books/" <> created.book.id)
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 200
  let decoded = decode_body(response, book_meta_wire_decoder())
  let expected =
    BookMetaWire(
      id: created.book.id,
      title: "Title",
      author: None,
      genre: Some("Fantasy"),
      word_count: created.book.word_count,
      sentence_count: created.book.sentence_count,
      uploaded_at: created.book.uploaded_at,
      last_read_at: None,
    )
  assert decoded == expected
}

pub fn patch_book_metadata_clears_genre_via_null_preserves_author_test() {
  // Symmetric counterpart — closes the asymmetric coverage R1 named:
  // only author-clear was covered, never genre-clear. Same seed, same
  // shape of assertion, opposite field nulled.
  use ctx <- with_context
  let created =
    http_create_book_full(
      ctx,
      "Title",
      Some("Author"),
      Some("Fantasy"),
      sample_text,
    )

  let body = json.object([#("genre", json.null())])

  let response =
    simulate.browser_request(http.Patch, "/api/books/" <> created.book.id)
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 200
  let decoded = decode_body(response, book_meta_wire_decoder())
  let expected =
    BookMetaWire(
      id: created.book.id,
      title: "Title",
      author: Some("Author"),
      genre: None,
      word_count: created.book.word_count,
      sentence_count: created.book.sentence_count,
      uploaded_at: created.book.uploaded_at,
      last_read_at: None,
    )
  assert decoded == expected
}

pub fn patch_book_metadata_does_not_silently_trim_untouched_title_test() {
  // Regression guard for the silent-trim-on-untouched-title bug: the
  // creation path does NOT trim title (validate_create_input only
  // checks emptiness), so a row can legitimately persist with a
  // trailing space. A PATCH that touches only `genre` must NOT
  // rewrite the title column — `resolve_title` now skips the trim
  // when `input.title` is `None` so the stored value round-trips
  // verbatim.
  use ctx <- with_context
  let created = http_create_book(ctx, "Tale of Two Cities ", None, sample_text)

  // Sanity: confirm the trailing space survived creation. Without
  // this guard the test could silently degenerate into a trim-of-
  // already-trimmed assertion if `validate_create_input` ever picks
  // up a trim step.
  assert created.book.title == "Tale of Two Cities "

  let body = json.object([#("genre", json.string("Fiction"))])

  let response =
    simulate.browser_request(http.Patch, "/api/books/" <> created.book.id)
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 200
  let decoded = decode_body(response, book_meta_wire_decoder())
  let expected =
    BookMetaWire(
      id: created.book.id,
      title: "Tale of Two Cities ",
      author: None,
      genre: Some("Fiction"),
      word_count: created.book.word_count,
      sentence_count: created.book.sentence_count,
      uploaded_at: created.book.uploaded_at,
      last_read_at: None,
    )
  assert decoded == expected
}

pub fn patch_book_metadata_trims_title_only_when_client_sent_one_test() {
  // The other half of the trim contract: when the client DOES send
  // a title, it gets trimmed before persistence. Asserts that the
  // selective trim only fires on the "Set" branch of the title
  // resolver, not on the "Untouched" branch (which is what the
  // sibling test covers).
  use ctx <- with_context
  let created = http_create_book(ctx, "Old Title", None, sample_text)

  let body = json.object([#("title", json.string("  Renamed  "))])

  let response =
    simulate.browser_request(http.Patch, "/api/books/" <> created.book.id)
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 200
  let decoded = decode_body(response, book_meta_wire_decoder())
  let expected =
    BookMetaWire(
      id: created.book.id,
      title: "Renamed",
      author: None,
      genre: None,
      word_count: created.book.word_count,
      sentence_count: created.book.sentence_count,
      uploaded_at: created.book.uploaded_at,
      last_read_at: None,
    )
  assert decoded == expected
}

pub fn patch_book_metadata_rejects_empty_title_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", None, sample_text)

  let body = json.object([#("title", json.string("   "))])

  let response =
    simulate.browser_request(http.Patch, "/api/books/" <> created.book.id)
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  // Empty / whitespace-only title is the only blocking validation —
  // surfaces as a 400 with a field-name hint so the client can fix
  // the form without a second round trip.
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "title")
}

pub fn patch_book_metadata_unknown_id_is_404_test() {
  use ctx <- with_context
  let body = json.object([#("title", json.string("New"))])
  let response =
    simulate.browser_request(http.Patch, "/api/books/no-such-book")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)
  assert response.status == 404
}

// ---------------------------------------------------------------------------
// Migrations
// ---------------------------------------------------------------------------

pub fn ensure_books_genre_column_migrates_pre_genre_schema_test() {
  // `db.initialize` always declares `genre` inline for fresh tables,
  // so the ALTER TABLE ADD COLUMN branch in `ensure_books_genre_column`
  // is only ever exercised against tables created before the genre
  // column landed — which means the entire test suite, on fresh
  // `:memory:` databases, never drives it. Hand-build a pre-genre
  // `books` table here, seed a row, run the migration, and verify
  // both the column appears AND the seeded row's `genre` reads back
  // as NULL — the actual contract callers depend on (a pre-existing
  // row must not vanish, and its new column must default to nullable
  // NULL, not be backfilled with an empty string or error). Idempotency
  // is asserted too: a second call on the already-migrated table must
  // be a no-op (the PRAGMA gate skips the ALTER because `genre` is
  // already present) and must not disturb the seeded row's NULL.
  let assert Ok(conn) = sqlight.open(":memory:")
  let pre_genre_schema =
    "CREATE TABLE books (
       id TEXT PRIMARY KEY,
       title TEXT NOT NULL,
       author TEXT,
       raw_text TEXT NOT NULL,
       segments_json TEXT NOT NULL,
       word_count INTEGER NOT NULL,
       sentence_count INTEGER NOT NULL,
       uploaded_at TEXT NOT NULL,
       last_read_at TEXT
     );"
  let assert Ok(_) = sqlight.exec(pre_genre_schema, conn)

  // Seed one row at the pre-genre schema so the migration is run
  // against non-empty data. The contract under test: after ALTER
  // TABLE ADD COLUMN, this row's `genre` must be readable as NULL.
  let seed_row_sql =
    "INSERT INTO books (id, title, author, raw_text, segments_json,
      word_count, sentence_count, uploaded_at, last_read_at)
     VALUES ('legacy-1', 'Legacy Title', NULL, 'raw', '[]', 0, 0,
       '2026-04-01T12:00:00Z', NULL);"
  let assert Ok(_) = sqlight.exec(seed_row_sql, conn)

  // Sanity: the table starts without `genre`. SELECT genre FROM books
  // must fail with a column-missing error — confirms the seed schema
  // is genuinely pre-genre.
  let assert Error(_) = sqlight.exec("SELECT genre FROM books;", conn)

  // First run: the migration adds the column.
  let assert Ok(Nil) = db.ensure_books_genre_column(conn)
  let assert Ok(_) = sqlight.exec("SELECT genre FROM books;", conn)

  // The pre-existing row's `genre` reads back as NULL — the column
  // default is nullable, no backfill happens, and the seeded row is
  // still there with its original id.
  let row_decoder = {
    use id <- decode.field(0, decode.string)
    use genre <- decode.field(1, decode.optional(decode.string))
    decode.success(#(id, genre))
  }
  let assert Ok([#("legacy-1", None)]) =
    sqlight.query(
      "SELECT id, genre FROM books;",
      on: conn,
      with: [],
      expecting: row_decoder,
    )

  // Second run: the PRAGMA gate sees `genre` already present and
  // skips the ALTER. Still `Ok(Nil)`, still leaves the column intact,
  // and the seeded row's NULL is undisturbed.
  let assert Ok(Nil) = db.ensure_books_genre_column(conn)
  let assert Ok([#("legacy-1", None)]) =
    sqlight.query(
      "SELECT id, genre FROM books;",
      on: conn,
      with: [],
      expecting: row_decoder,
    )

  let assert Ok(_) = sqlight.close(conn)
}

pub fn ensure_reading_state_percent_progress_column_migrates_pre_percent_progress_schema_test() {
  // Mirror the precedent set by `ensure_books_genre_column_migrates_
  // pre_genre_schema_test` (server/test/server_test.gleam:2134). The
  // ALTER TABLE branch of `ensure_reading_state_percent_progress_
  // column` only fires against tables created before the column
  // landed; every test that goes through `db.initialize` on a fresh
  // `:memory:` database picks the column up from the inline
  // `CREATE TABLE IF NOT EXISTS` and never drives the migration. This
  // test hand-builds a pre-percent_progress `reading_state` table,
  // seeds a row, runs the migration, and asserts both the column
  // appears AND the seeded row's `percent_progress` reads back as the
  // schema default `0.0` (not a backfill, not an error). Idempotency
  // is then asserted: a second call leaves the row's `0.0` undisturbed.
  let assert Ok(conn) = sqlight.open(":memory:")
  // The pre-percent_progress schema omits the new column and the FK
  // reference (FK enforcement is off by default, so a hand-built
  // standalone `reading_state` table is sufficient for the migration
  // path under test).
  let pre_percent_progress_schema =
    "CREATE TABLE reading_state (
       book_id TEXT PRIMARY KEY,
       mode TEXT NOT NULL DEFAULT 'manual',
       sentence_bitset BLOB,
       word_bitset BLOB,
       current_page INTEGER NOT NULL DEFAULT 0,
       updated_at TEXT NOT NULL
     );"
  let assert Ok(_) = sqlight.exec(pre_percent_progress_schema, conn)

  // Seed a row at the pre-percent_progress schema so the migration
  // runs against non-empty data. The contract under test: the seeded
  // row's `percent_progress` must default to `0.0` (the column's
  // `NOT NULL DEFAULT 0.0`) after the ALTER TABLE ADD COLUMN.
  let seed_row_sql =
    "INSERT INTO reading_state (book_id, mode, sentence_bitset, word_bitset,
      current_page, updated_at)
     VALUES ('legacy-1', 'manual', NULL, NULL, 3, '2026-04-01T12:00:00Z');"
  let assert Ok(_) = sqlight.exec(seed_row_sql, conn)

  // Sanity: the table starts without `percent_progress`. SELECT must
  // fail with a column-missing error — confirms the seed schema is
  // genuinely pre-percent_progress.
  let assert Error(_) =
    sqlight.exec("SELECT percent_progress FROM reading_state;", conn)

  // First run: the migration adds the column.
  let assert Ok(Nil) = db.ensure_reading_state_percent_progress_column(conn)
  let assert Ok(_) =
    sqlight.exec("SELECT percent_progress FROM reading_state;", conn)

  // The pre-existing row's `percent_progress` reads back as `0.0` —
  // the column default lands the floor on every existing row, and the
  // seeded row is still there with its original `book_id` and
  // `current_page`.
  let row_decoder = {
    use book_id <- decode.field(0, decode.string)
    use current_page <- decode.field(1, decode.int)
    use percent_progress <- decode.field(2, decode.float)
    decode.success(#(book_id, current_page, percent_progress))
  }
  let assert Ok([#("legacy-1", 3, 0.0)]) =
    sqlight.query(
      "SELECT book_id, current_page, percent_progress FROM reading_state;",
      on: conn,
      with: [],
      expecting: row_decoder,
    )

  // Second run: the PRAGMA-style column probe sees `percent_progress`
  // already present and skips the ALTER. Still `Ok(Nil)`, still
  // leaves the column intact, and the seeded row's `0.0` is
  // undisturbed.
  let assert Ok(Nil) = db.ensure_reading_state_percent_progress_column(conn)
  let assert Ok([#("legacy-1", 3, 0.0)]) =
    sqlight.query(
      "SELECT book_id, current_page, percent_progress FROM reading_state;",
      on: conn,
      with: [],
      expecting: row_decoder,
    )

  let assert Ok(_) = sqlight.close(conn)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn http_create_book(
  ctx: web.Context,
  title: String,
  author: Option(String),
  text: String,
) -> BookCreateResponse {
  http_create_book_full(ctx, title, author, None, text)
}

/// Same as `http_create_book` but exposes the `genre` field too. The
/// PATCH-metadata tests need to seed rows with a genre so they can
/// assert cross-field preservation on partial updates (clearing
/// author must NOT clear genre, etc.).
fn http_create_book_full(
  ctx: web.Context,
  title: String,
  author: Option(String),
  genre: Option(String),
  text: String,
) -> BookCreateResponse {
  let body =
    json.object([
      #("title", json.string(title)),
      #("author", json.nullable(author, json.string)),
      #("genre", json.nullable(genre, json.string)),
      #("text", json.string(text)),
    ])
  let response =
    simulate.browser_request(http.Post, "/api/books")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)
  let assert 201 = response.status
  decode_body(response, book_create_response_decoder())
}

fn http_get_reading_state(ctx: web.Context, id: String) -> wisp.Response {
  router.handle_request(
    simulate.browser_request(http.Get, "/api/books/" <> id <> "/state"),
    ctx,
  )
}

fn http_put_reading_state(
  ctx: web.Context,
  id: String,
  body: json.Json,
) -> wisp.Response {
  simulate.browser_request(http.Put, "/api/books/" <> id <> "/state")
  |> simulate.json_body(body)
  |> router.handle_request(ctx)
}

fn put_reading_state_body(
  mode: String,
  current_page: Int,
  updated_at: String,
) -> json.Json {
  json.object([
    #("mode", json.string(mode)),
    #("sentence_bitset", json.null()),
    #("word_bitset", json.null()),
    #("current_page", json.int(current_page)),
    #("updated_at", json.string(updated_at)),
  ])
}

fn http_get_book_settings(ctx: web.Context, id: String) -> wisp.Response {
  router.handle_request(
    simulate.browser_request(http.Get, "/api/books/" <> id <> "/settings"),
    ctx,
  )
}

fn http_put_book_settings(
  ctx: web.Context,
  id: String,
  settings: BookSettings,
) -> wisp.Response {
  simulate.browser_request(http.Put, "/api/books/" <> id <> "/settings")
  |> simulate.json_body(book_settings_to_json(settings))
  |> router.handle_request(ctx)
}

fn book_settings_wire_decoder() -> decode.Decoder(BookSettings) {
  use wpm <- decode.field("wpm", decode.optional(decode.int))
  use paragraph_delay_ms <- decode.field(
    "paragraph_delay_ms",
    decode.optional(decode.int),
  )
  use page_delay_ms <- decode.field(
    "page_delay_ms",
    decode.optional(decode.int),
  )
  use ghost_opacity <- decode.field(
    "ghost_opacity",
    decode.optional(decode.float),
  )
  decode.success(BookSettings(
    wpm: wpm,
    paragraph_delay_ms: paragraph_delay_ms,
    page_delay_ms: page_delay_ms,
    ghost_opacity: ghost_opacity,
  ))
}

fn book_settings_to_json(settings: BookSettings) -> json.Json {
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

fn http_post_session(
  ctx: web.Context,
  book_id: String,
  session_id: String,
  started_at: String,
) -> wisp.Response {
  let body =
    json.object([
      #("id", json.string(session_id)),
      #("started_at", json.string(started_at)),
    ])
  simulate.browser_request(http.Post, "/api/books/" <> book_id <> "/sessions")
  |> simulate.json_body(body)
  |> router.handle_request(ctx)
}

fn http_put_session(
  ctx: web.Context,
  book_id: String,
  session_id: String,
  body: json.Json,
) -> wisp.Response {
  simulate.browser_request(
    http.Put,
    "/api/books/" <> book_id <> "/sessions/" <> session_id,
  )
  |> simulate.json_body(body)
  |> router.handle_request(ctx)
}

/// POST the closing payload to the per-session item endpoint. The
/// dispatcher routes `Post` → `put_session_handler` so the
/// `navigator.sendBeacon` durability path (POST-only) can flush the
/// closing counters; this helper exercises that same wire contract.
fn http_post_session_update(
  ctx: web.Context,
  book_id: String,
  session_id: String,
  body: json.Json,
) -> wisp.Response {
  simulate.browser_request(
    http.Post,
    "/api/books/" <> book_id <> "/sessions/" <> session_id,
  )
  |> simulate.json_body(body)
  |> router.handle_request(ctx)
}

fn end_session_body(
  ended_at: String,
  words_read: Int,
  words_skipped: Int,
  pages_turned: Int,
  duration_seconds: Int,
) -> json.Json {
  json.object([
    #("ended_at", json.string(ended_at)),
    #("words_read", json.int(words_read)),
    #("words_skipped", json.int(words_skipped)),
    #("pages_turned", json.int(pages_turned)),
    #("duration_seconds", json.int(duration_seconds)),
  ])
}

fn reading_session_wire_decoder() -> decode.Decoder(ReadingSession) {
  use id <- decode.field("id", decode.string)
  use book_id <- decode.field("book_id", decode.string)
  use started_at <- decode.field("started_at", decode.string)
  use ended_at <- decode.field("ended_at", decode.optional(decode.string))
  use words_read <- decode.field("words_read", decode.int)
  use words_skipped <- decode.field("words_skipped", decode.int)
  use pages_turned <- decode.field("pages_turned", decode.int)
  use duration_seconds <- decode.field("duration_seconds", decode.int)
  decode.success(ReadingSession(
    id: id,
    book_id: book_id,
    started_at: started_at,
    ended_at: ended_at,
    words_read: words_read,
    words_skipped: words_skipped,
    pages_turned: pages_turned,
    duration_seconds: duration_seconds,
  ))
}

fn user_settings_to_json(settings: UserSettings) -> json.Json {
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
