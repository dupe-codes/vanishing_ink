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
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import server/db
import server/router
import server/types.{
  type BookSettings, type ReadingState, type UserSettings, BookSettings,
  ReadingState,
}
import server/web
import shared/segmenter
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
  let decoded = decode_body(response, book_meta_wire_decoder())
  assert decoded.title == "Renamed"
  assert decoded.author == Some("New Author")
  assert decoded.genre == Some("Fantasy")

  // Subsequent GET reflects the persisted values.
  let after =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/books/" <> created.book.id),
      ctx,
    )
  let after_decoded = decode_body(after, book_full_decoder())
  assert after_decoded.title == "Renamed"
  assert after_decoded.author == Some("New Author")
  assert after_decoded.genre == Some("Fantasy")
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
  assert decoded.title == "Title"
  assert decoded.author == Some("Author")
  assert decoded.genre == Some("Mystery")
}

pub fn patch_book_metadata_clears_field_on_explicit_null_test() {
  use ctx <- with_context
  let created = http_create_book(ctx, "Title", Some("Author"), sample_text)

  // Explicit `null` for `author` must clear the column; `title` is
  // omitted entirely so it stays as "Title".
  let body = json.object([#("author", json.null())])

  let response =
    simulate.browser_request(http.Patch, "/api/books/" <> created.book.id)
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 200
  let decoded = decode_body(response, book_meta_wire_decoder())
  assert decoded.title == "Title"
  assert decoded.author == None
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
// Helpers
// ---------------------------------------------------------------------------

fn http_create_book(
  ctx: web.Context,
  title: String,
  author: Option(String),
  text: String,
) -> BookCreateResponse {
  let author_field = case author {
    None -> json.null()
    Some(value) -> json.string(value)
  }
  let body =
    json.object([
      #("title", json.string(title)),
      #("author", author_field),
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
