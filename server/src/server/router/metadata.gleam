//// PATCH `/api/books/:id` — metadata-update machinery.
////
//// Accepts an object whose three editable fields — `title`, `author`,
//// `genre` — are independently optional. An omitted field means
//// "leave the on-disk value alone"; an explicit `null` for `author`
//// or `genre` clears that column. The router reads the existing row
//// first so the SQL UPDATE writes a full triple back; the schema's
//// `title NOT NULL` constraint is preserved by validation rejecting
//// an empty trimmed title.
////
//// The handler returns the updated `BookMeta` on the wire so the
//// client can drop the response into its library list without a
//// follow-up GET — same shape as `POST /api/books` returning the
//// freshly-minted metadata.
////
//// Lives in its own module so the top-level `router.gleam` can shrink
//// — same per-feature split the client uses for its reducer arms.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import server/db
import server/router/helpers.{db_error_response, describe_decode_errors}
import server/types.{type Book, BookMeta}
import server/web.{type Context}
import wisp.{type Request, type Response}

/// Top-level handler — decode the body, then resolve the partial
/// update against the on-disk row.
pub fn handle_patch(req: Request, ctx: Context, id: String) -> Response {
  use body <- wisp.require_json(req)

  case decode.run(body, metadata_update_decoder()) {
    Error(errors) -> wisp.bad_request(describe_decode_errors(errors))
    Ok(input) -> apply_metadata_update(ctx, id, input)
  }
}

type MetadataUpdateInput {
  MetadataUpdateInput(
    title: Option(String),
    author: MetadataField(String),
    genre: MetadataField(String),
  )
}

/// Three-way state for a partial-update field. `Untouched` means the
/// client did not include the field at all — the existing value
/// stays. `Cleared` means the client sent `null` — the column gets
/// nulled out. `Set(value)` means the client sent a non-null value —
/// the column takes that value. `decode.optional` collapses the
/// `null` vs missing distinction the first two states need, so the
/// decoder reads the field via `decode.field` with a custom
/// branching decoder that surfaces the three cases.
type MetadataField(a) {
  Untouched
  Cleared
  Set(value: a)
}

fn metadata_update_decoder() -> decode.Decoder(MetadataUpdateInput) {
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use author <- metadata_field_decoder("author")
  use genre <- metadata_field_decoder("genre")
  decode.success(MetadataUpdateInput(title: title, author: author, genre: genre))
}

fn metadata_field_decoder(
  field: String,
  next: fn(MetadataField(String)) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.optional_field(
    field,
    Untouched,
    decode.map(decode.optional(decode.string), fn(value) {
      case value {
        None -> Cleared
        Some(text) -> Set(text)
      }
    }),
    next,
  )
}

fn apply_metadata_update(
  ctx: Context,
  id: String,
  input: MetadataUpdateInput,
) -> Response {
  case db.get_book(ctx.db, id) {
    Error(error) -> db_error_response("db.get_book", error)
    Ok(None) -> wisp.not_found()
    Ok(Some(book)) -> persist_metadata_update(ctx, id, book, input)
  }
}

fn persist_metadata_update(
  ctx: Context,
  id: String,
  book: Book,
  input: MetadataUpdateInput,
) -> Response {
  // Resolve the three fields against the on-disk row before writing.
  // Title gets trimmed + validated ONLY when the client sent a new
  // value — an untouched title round-trips the stored value verbatim
  // so a PATCH that touches only the author/genre cannot silently
  // rewrite the title column (e.g. stripping trailing whitespace
  // from a row that `validate_create_input` accepted as-is).
  case resolve_title(input.title, book.title) {
    Error(detail) -> wisp.bad_request(detail)
    Ok(title) -> {
      let author = resolve_metadata_field(input.author, book.author)
      let genre = resolve_metadata_field(input.genre, book.genre)
      case
        db.update_book_metadata(
          ctx.db,
          id: id,
          title: title,
          author: author,
          genre: genre,
        )
      {
        Error(error) -> db_error_response("db.update_book_metadata", error)
        Ok(False) -> wisp.not_found()
        Ok(True) -> {
          let meta =
            BookMeta(
              id: id,
              title: title,
              author: author,
              genre: genre,
              word_count: book.word_count,
              sentence_count: book.sentence_count,
              uploaded_at: book.uploaded_at,
              last_read_at: book.last_read_at,
            )
          let body =
            types.book_meta_to_json(meta)
            |> json.to_string
          wisp.json_response(body, 200)
        }
      }
    }
  }
}

fn resolve_title(
  input_title: Option(String),
  book_title: String,
) -> Result(String, String) {
  case input_title {
    None -> Ok(book_title)
    Some(value) -> validate_new_title(value)
  }
}

fn validate_new_title(title: String) -> Result(String, String) {
  let trimmed = string.trim(title)
  case trimmed {
    "" -> Error("title must not be empty")
    _ -> Ok(trimmed)
  }
}

fn resolve_metadata_field(
  field: MetadataField(String),
  existing: Option(String),
) -> Option(String) {
  case field {
    Untouched -> existing
    Cleared -> None
    Set(value) -> Some(value)
  }
}
