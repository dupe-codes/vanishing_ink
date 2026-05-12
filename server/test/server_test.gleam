//// Integration tests for the Vanishing Ink server. Each test boots a
//// fresh in-memory SQLite database, builds a `web.Context`, and drives
//// the router through `wisp/simulate`. The tests deliberately exercise
//// the public HTTP surface end to end — they would catch any drift
//// between the SQL layer, the router, and the JSON encoders.

import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import server/db
import server/router
import server/types
import server/web
import shared/segmenter
import sqlight
import wisp/simulate

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_context(f: fn(web.Context) -> Nil) -> Nil {
  // ":memory:" gives every test an isolated database that disappears
  // when the connection closes — perfect for hermetic testing.
  let assert Ok(conn) = db.initialize(":memory:")
  f(web.Context(db: conn))
  let assert Ok(_) = sqlight.close(conn)
  Nil
}

// ---------------------------------------------------------------------------
// Liveness
// ---------------------------------------------------------------------------

pub fn status_route_returns_ok_json_test() {
  use ctx <- with_context
  let response =
    router.handle_request(simulate.browser_request(http.Get, "/"), ctx)
  assert response.status == 200
  assert simulate.read_body(response) == "{\"status\":\"ok\"}"
}

pub fn unknown_route_returns_404_test() {
  use ctx <- with_context
  let response =
    router.handle_request(simulate.browser_request(http.Get, "/nope"), ctx)
  assert response.status == 404
}

// ---------------------------------------------------------------------------
// Books
// ---------------------------------------------------------------------------

pub fn create_book_persists_and_segments_test() {
  use ctx <- with_context

  let body =
    json.object([
      #("title", json.string("Tale of Two Cities")),
      #("author", json.string("Dickens")),
      #(
        "text",
        json.string("It was the best of times. It was the worst of times."),
      ),
    ])

  let response =
    simulate.browser_request(http.Post, "/api/books")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)

  assert response.status == 201

  // The 201 payload carries the book metadata; the listing endpoint
  // should now find the same row.
  let listing =
    router.handle_request(simulate.browser_request(http.Get, "/api/books"), ctx)
  assert listing.status == 200

  let assert Ok(books) = db.list_books(ctx.db)
  assert list.length(books) == 1
  let assert [book, ..] = books
  assert book.title == "Tale of Two Cities"
  assert book.author == Some("Dickens")
  // Two sentences in the input → sentence_count is 2.
  assert book.sentence_count == 2

  // Round-trip: pull the full book and verify the segments JSON
  // re-decodes into the same structure the segmenter produces from
  // the raw text. This is the end-to-end segmenter integration check.
  let assert Ok(option.Some(full)) = db.get_book(ctx.db, book.id)
  let assert Ok(segments) = json.parse(full.segments_json, segmenter.decoder())
  let expected =
    segmenter.segment("It was the best of times. It was the worst of times.")
  assert segments == expected
}

pub fn create_book_missing_title_is_400_test() {
  use ctx <- with_context
  let body =
    json.object([
      #("text", json.string("some text")),
    ])
  let response =
    simulate.browser_request(http.Post, "/api/books")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)
  assert response.status == 400
}

pub fn create_book_empty_text_is_400_test() {
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
}

pub fn get_missing_book_is_404_test() {
  use ctx <- with_context
  let response =
    router.handle_request(
      simulate.browser_request(http.Get, "/api/books/nope"),
      ctx,
    )
  assert response.status == 404
}

// ---------------------------------------------------------------------------
// Reading state
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

  let assert Ok(Some(state)) = db.get_reading_state(ctx.db, "book-1")
  // The newer write at 02:00 should still be visible — mode/page
  // from the stale write must not have overwritten it.
  assert state.mode == "manual"
  assert state.current_page == 3
  assert state.updated_at == Some("2026-05-12T02:00:00Z")

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
  assert state.mode == "ghost"
  assert state.current_page == 7
  assert state.sentence_bitset == Some(<<1, 2, 3>>)
  assert state.word_bitset == Some(<<4, 5, 6>>)
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

pub fn settings_default_row_exists_test() {
  use ctx <- with_context
  let assert Ok(settings) = db.get_settings(ctx.db)
  // These match the schema defaults in db.gleam.
  assert settings.font_size == 18
  assert settings.line_spacing == 1.6
  assert settings.dark_mode == True
  assert settings.ghost_mode == False
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

pub fn settings_put_endpoint_round_trips_test() {
  use ctx <- with_context
  let body =
    json.object([
      #("font_size", json.int(20)),
      #("line_spacing", json.float(1.8)),
      #("dark_mode", json.bool(False)),
      #("ghost_mode", json.bool(True)),
      #("ghost_opacity", json.float(0.1)),
      #("default_wpm", json.int(250)),
      #("default_paragraph_delay_ms", json.int(800)),
      #("default_page_delay_ms", json.int(1700)),
    ])
  let response =
    simulate.browser_request(http.Put, "/api/settings")
    |> simulate.json_body(body)
    |> router.handle_request(ctx)
  assert response.status == 200

  let response_body = simulate.read_body(response)
  let assert Ok(font_size) =
    json.parse(response_body, decode.at(["font_size"], decode.int))
  assert font_size == 20
}
