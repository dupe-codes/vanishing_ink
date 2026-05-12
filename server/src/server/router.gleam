//// HTTP request router and handlers for the Vanishing Ink API.
////
//// Routing is plain `case` pattern-matching on path segments; handlers
//// live alongside the routing table because the surface is small
//// enough that a per-feature split would add ceremony without
//// clarifying anything. Each handler reads the request, talks to
//// `server/db`, and either returns JSON or maps a precise error to a
//// 4xx/5xx response.
////
//// JSON bodies are decoded with `gleam/dynamic/decode`; on a decode
//// failure we return 400 with the first error's message so clients can
//// see exactly which field was wrong.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{Get, Post, Put}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import server/clock
import server/db
import server/types.{
  type ReadingState, type UserSettings, BookMeta, ReadingState, UserSettings,
}
import server/web.{type Context}
import shared
import shared/segmenter
import wisp.{type Request, type Response}

/// Top-level dispatcher. Wisp matches paths as a list of segments, so
/// the routing table is just a literal nested `case`.
pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req)

  case wisp.path_segments(req) {
    [] -> status(req)
    ["api", "books"] -> books_collection(req, ctx)
    ["api", "books", id] -> books_item(req, ctx, id)
    ["api", "books", id, "state"] -> reading_state(req, ctx, id)
    ["api", "settings"] -> settings(req, ctx)
    _ -> wisp.not_found()
  }
}

// ---------------------------------------------------------------------------
// Liveness
// ---------------------------------------------------------------------------

fn status(req: Request) -> Response {
  use <- wisp.require_method(req, Get)
  // The shared `BookId` type is touched here so the cross-target path
  // dependency keeps getting exercised on every build. Drop this once
  // a real handler covers it.
  let _: shared.BookId = shared.book_id("placeholder")
  let body =
    json.object([#("status", json.string("ok"))])
    |> json.to_string
  wisp.json_response(body, 200)
}

// ---------------------------------------------------------------------------
// Books collection
// ---------------------------------------------------------------------------

fn books_collection(req: Request, ctx: Context) -> Response {
  case req.method {
    Get -> list_books_handler(ctx)
    Post -> create_book_handler(req, ctx)
    _ -> wisp.method_not_allowed([Get, Post])
  }
}

fn list_books_handler(ctx: Context) -> Response {
  case db.list_books(ctx.db) {
    Ok(books) -> {
      let body =
        json.array(books, types.book_meta_to_json)
        |> json.to_string
      wisp.json_response(body, 200)
    }
    Error(_) -> wisp.internal_server_error()
  }
}

type CreateBookInput {
  CreateBookInput(title: String, text: String, author: Option(String))
}

fn create_book_decoder() -> decode.Decoder(CreateBookInput) {
  use title <- decode.field("title", decode.string)
  use text <- decode.field("text", decode.string)
  use author <- decode.optional_field(
    "author",
    None,
    decode.optional(decode.string),
  )
  decode.success(CreateBookInput(title: title, text: text, author: author))
}

fn create_book_handler(req: Request, ctx: Context) -> Response {
  use body <- wisp.require_json(req)

  case decode.run(body, create_book_decoder()) {
    Error(errors) -> wisp.bad_request(describe_decode_errors(errors))
    Ok(input) -> {
      case validate_create_input(input) {
        Error(detail) -> wisp.bad_request(detail)
        Ok(input) -> persist_new_book(ctx, input)
      }
    }
  }
}

fn validate_create_input(
  input: CreateBookInput,
) -> Result(CreateBookInput, String) {
  case input.title, input.text {
    "", _ -> Error("title must not be empty")
    _, "" -> Error("text must not be empty")
    _, _ -> Ok(input)
  }
}

fn persist_new_book(ctx: Context, input: CreateBookInput) -> Response {
  // Segment + count happen before any DB write so a malformed input
  // (caught upstream) never leaves a half-written row.
  let segmented = segmenter.segment(input.text)
  let #(word_count, sentence_count) = count_segments(segmented)
  let segments_json =
    segmented
    |> segmenter.to_json
    |> json.to_string
  let id = shared.book_id(wisp.random_string(32))
  let uploaded_at = clock.now_iso8601()

  case
    db.create_book(
      ctx.db,
      id: id,
      title: input.title,
      author: input.author,
      raw_text: input.text,
      segments_json: segments_json,
      word_count: word_count,
      sentence_count: sentence_count,
      uploaded_at: uploaded_at,
    )
  {
    Error(_) -> wisp.internal_server_error()
    Ok(Nil) -> {
      let meta =
        BookMeta(
          id: id,
          title: input.title,
          author: input.author,
          word_count: word_count,
          sentence_count: sentence_count,
          uploaded_at: uploaded_at,
          last_read_at: None,
        )
      // The response carries both the metadata (so the client can drop
      // it into its library list immediately) and the parsed segments
      // (so the reader view can render without an extra GET).
      let body =
        json.object([
          #("book", types.book_meta_to_json(meta)),
          #("segments", segmenter.to_json(segmented)),
        ])
        |> json.to_string
      wisp.json_response(body, 201)
    }
  }
}

// ---------------------------------------------------------------------------
// Books item
// ---------------------------------------------------------------------------

fn books_item(req: Request, ctx: Context, id: String) -> Response {
  case req.method {
    Get -> get_book_handler(ctx, id)
    _ -> wisp.method_not_allowed([Get])
  }
}

fn get_book_handler(ctx: Context, id: String) -> Response {
  case db.get_book(ctx.db, id) {
    Error(_) -> wisp.internal_server_error()
    Ok(None) -> wisp.not_found()
    Ok(Some(book)) -> {
      // The stored `segments_json` is parsed and re-embedded as
      // structured JSON in the response. Round-tripping through the
      // segmenter's own decoder keeps the wire shape canonical even if
      // the on-disk encoding ever changes (different key ordering,
      // whitespace, etc).
      case json.parse(book.segments_json, segmenter.decoder()) {
        Error(_) -> wisp.internal_server_error()
        Ok(segments) -> {
          let body =
            types.book_to_json(book, segmenter.to_json(segments))
            |> json.to_string
          wisp.json_response(body, 200)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Reading state
// ---------------------------------------------------------------------------

fn reading_state(req: Request, ctx: Context, id: String) -> Response {
  case req.method {
    Put -> put_reading_state_handler(req, ctx, id)
    Get -> get_reading_state_handler(ctx, id)
    _ -> wisp.method_not_allowed([Get, Put])
  }
}

fn put_reading_state_handler(
  req: Request,
  ctx: Context,
  id: String,
) -> Response {
  use body <- wisp.require_json(req)

  case decode.run(body, reading_state_input_decoder()) {
    Error(errors) -> wisp.bad_request(describe_decode_errors(errors))
    Ok(input) ->
      case decode_bitsets(input) {
        Error(detail) -> wisp.bad_request(detail)
        Ok(#(sentence_bitset, word_bitset)) ->
          persist_reading_state(
            ctx,
            id,
            input.mode,
            sentence_bitset,
            word_bitset,
            input.current_page,
            input.updated_at,
          )
      }
  }
}

fn persist_reading_state(
  ctx: Context,
  id: String,
  mode: String,
  sentence_bitset: Option(BitArray),
  word_bitset: Option(BitArray),
  current_page: Int,
  updated_at: String,
) -> Response {
  // Existence-check the book first so the FK violation never reaches
  // the SQLite layer — and so a missing book maps to a clean 404
  // instead of an opaque 500.
  case db.get_book(ctx.db, id) {
    Error(_) -> wisp.internal_server_error()
    Ok(None) -> wisp.not_found()
    Ok(Some(_)) ->
      case
        db.update_reading_state(
          ctx.db,
          book_id: id,
          mode: mode,
          sentence_bitset: sentence_bitset,
          word_bitset: word_bitset,
          current_page: current_page,
          updated_at: updated_at,
        )
      {
        Error(_) -> wisp.internal_server_error()
        Ok(Nil) ->
          // Re-read so the client sees the authoritative state — if
          // the last-write-wins guard rejected the write, the
          // response still reflects whatever's on disk.
          case db.get_reading_state(ctx.db, id) {
            Error(_) -> wisp.internal_server_error()
            Ok(None) -> wisp.internal_server_error()
            Ok(Some(state)) -> {
              let body =
                types.reading_state_to_json(state)
                |> json.to_string
              wisp.json_response(body, 200)
            }
          }
      }
  }
}

fn get_reading_state_handler(ctx: Context, id: String) -> Response {
  case db.get_book(ctx.db, id) {
    Error(_) -> wisp.internal_server_error()
    Ok(None) -> wisp.not_found()
    Ok(Some(_)) ->
      case db.get_reading_state(ctx.db, id) {
        Error(_) -> wisp.internal_server_error()
        // A book with no recorded reading state surfaces as an empty
        // default; that's simpler for the client than a 404 because
        // every book starts with no reading progress.
        Ok(None) -> {
          let body =
            types.reading_state_to_json(empty_reading_state(id))
            |> json.to_string
          wisp.json_response(body, 200)
        }
        Ok(Some(state)) -> {
          let body =
            types.reading_state_to_json(state)
            |> json.to_string
          wisp.json_response(body, 200)
        }
      }
  }
}

fn empty_reading_state(book_id: shared.BookId) -> ReadingState {
  ReadingState(
    book_id: book_id,
    mode: "manual",
    sentence_bitset: None,
    word_bitset: None,
    current_page: 0,
    updated_at: "1970-01-01T00:00:00Z",
  )
}

type ReadingStateInput {
  ReadingStateInput(
    mode: String,
    sentence_bitset: Option(String),
    word_bitset: Option(String),
    current_page: Int,
    updated_at: String,
  )
}

fn reading_state_input_decoder() -> decode.Decoder(ReadingStateInput) {
  use mode <- decode.field("mode", decode.string)
  use sentence_bitset <- decode.optional_field(
    "sentence_bitset",
    None,
    decode.optional(decode.string),
  )
  use word_bitset <- decode.optional_field(
    "word_bitset",
    None,
    decode.optional(decode.string),
  )
  use current_page <- decode.field("current_page", decode.int)
  use updated_at <- decode.field("updated_at", decode.string)
  decode.success(ReadingStateInput(
    mode: mode,
    sentence_bitset: sentence_bitset,
    word_bitset: word_bitset,
    current_page: current_page,
    updated_at: updated_at,
  ))
}

fn decode_bitsets(
  input: ReadingStateInput,
) -> Result(#(Option(BitArray), Option(BitArray)), String) {
  use sentence_bitset <- result.try(decode_optional_base64(
    "sentence_bitset",
    input.sentence_bitset,
  ))
  use word_bitset <- result.try(decode_optional_base64(
    "word_bitset",
    input.word_bitset,
  ))
  Ok(#(sentence_bitset, word_bitset))
}

fn decode_optional_base64(
  field_name: String,
  value: Option(String),
) -> Result(Option(BitArray), String) {
  case value {
    None -> Ok(None)
    Some(encoded) ->
      case bit_array.base64_decode(encoded) {
        Ok(bytes) -> Ok(Some(bytes))
        Error(_) -> Error(field_name <> " is not valid base64")
      }
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

fn settings(req: Request, ctx: Context) -> Response {
  case req.method {
    Get -> get_settings_handler(ctx)
    Put -> put_settings_handler(req, ctx)
    _ -> wisp.method_not_allowed([Get, Put])
  }
}

fn get_settings_handler(ctx: Context) -> Response {
  case db.get_settings(ctx.db) {
    Error(_) -> wisp.internal_server_error()
    Ok(settings) -> {
      let body =
        types.user_settings_to_json(settings)
        |> json.to_string
      wisp.json_response(body, 200)
    }
  }
}

fn put_settings_handler(req: Request, ctx: Context) -> Response {
  use body <- wisp.require_json(req)

  case decode.run(body, user_settings_decoder()) {
    Error(errors) -> wisp.bad_request(describe_decode_errors(errors))
    Ok(settings) ->
      case db.update_settings(ctx.db, settings) {
        Error(_) -> wisp.internal_server_error()
        Ok(Nil) -> {
          let body =
            types.user_settings_to_json(settings)
            |> json.to_string
          wisp.json_response(body, 200)
        }
      }
  }
}

fn user_settings_decoder() -> decode.Decoder(UserSettings) {
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
  decode.success(UserSettings(
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn describe_decode_errors(errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> "invalid JSON body"
    [decode.DecodeError(expected, found, path), ..] -> {
      let path_str = case path {
        [] -> "<root>"
        _ -> string_join_dot(path)
      }
      "expected " <> expected <> " at " <> path_str <> " but found " <> found
    }
  }
}

fn string_join_dot(path: List(String)) -> String {
  list.fold(path, "", fn(acc, segment) {
    case acc {
      "" -> segment
      _ -> acc <> "." <> segment
    }
  })
}

/// Walk the segmented tree once to compute the word and sentence
/// counts that get stored on the `books` row. Done here rather than
/// inside `segmenter` so the segmenter stays focused on segmentation —
/// counting is a server-only concern (the client uses the same
/// numbers it receives in the upload response).
fn count_segments(segmented: segmenter.SegmentedText) -> #(Int, Int) {
  list.fold(segmented.chapters, #(0, 0), fn(outer, chapter) {
    list.fold(chapter.paragraphs, outer, fn(mid, paragraph) {
      list.fold(paragraph.sentences, mid, fn(inner, sentence) {
        let #(words, sentences) = inner
        #(words + list.length(sentence.words), sentences + 1)
      })
    })
  })
}
