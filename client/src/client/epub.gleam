//// ePub import boundary. Provides a typed Gleam interface around the
//// vendored foliate-js parser (`client/src/client/vendor/foliate-js/`)
//// so the reducer and effect layers can speak in `EpubExtract` /
//// `EpubError` values rather than raw `Dynamic`. The companion
//// `epub.ffi.mjs` does the JavaScript work — unzipping the file,
//// walking the spine, and rendering each section into the segmenter's
//// expected plain-text shape (`# Heading` lines, blank-line paragraph
//// breaks).
////
//// The wire from user → segmenter is:
////
////   1. View renders a `<input type="file">`. On change, the FFI-side
////      `file_change_attribute` reads `target.files[0]`, wraps it in a
////      `Dynamic` payload, and emits an `EpubFileSelected(file)` Msg.
////   2. The reducer dispatches the `parse_epub` effect, which calls
////      `parse_epub_file` here. The FFI hands the raw `File` to
////      foliate-js, awaits the parse, and invokes the callback with
////      `Ok(EpubExtract(title, author, text))` or `Error(epub_error)`.
////   3. The reducer pre-fills the paste form with the extracted title
////      and text. The reader still chooses when to submit — the import
////      is "load into the form", not "skip the form".
////
//// The `Dynamic` payload on `EpubFileSelected` is deliberate: a
//// browser `File` object does not round-trip through Gleam's typed
//// runtime, so we keep the reference opaque on the Gleam side and
//// only pass it through to the FFI parser.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import lustre/attribute.{type Attribute}
import lustre/event

/// Plain-text projection of an ePub ready to feed into the segmenter.
///
/// `text` is segmented-format text: `# Title` lines start chapters,
/// blank lines (`\n\n`) separate paragraphs, and a single newline is a
/// hard break within a paragraph. The FFI emits this shape so the
/// existing `shared/segmenter.segment/1` runs unchanged on the
/// server's `POST /api/books` path.
///
/// `title` comes from the ePub package metadata (the OPF's
/// `<dc:title>` element via foliate-js) and defaults to an empty
/// string when the metadata is missing — the reducer treats empty as
/// "ask the reader to fill in the title." Author / creator metadata
/// is not surfaced because the create-book wire (`POST /api/books`)
/// only carries `{ title, text }`; threading a `_author` field
/// through the reducer to drop it on the floor would be dead code.
///
/// `sections_skipped` is the count of spine sections the FFI could
/// not parse (malformed XHTML, `createDocument` threw). The reducer
/// surfaces a soft warning in the add-book sheet when the count is
/// non-zero so the reader can distinguish "imported every chapter"
/// from "imported but some chapters silently fell off the wire."
pub type EpubExtract {
  EpubExtract(title: String, text: String, sections_skipped: Int)
}

/// Failure modes the import surface can produce. Each variant maps to
/// one user-visible message in the add-book sheet.
///
/// * `UnsupportedFormat` — the file is not a ZIP at all (e.g. a `.pdf`
///   renamed to `.epub`), or the ZIP has no `META-INF/container.xml`,
///   or the OPF rootfile is missing. Surface as "This file does not
///   look like a valid ePub."
/// * `DrmEncrypted` — foliate-js's `<encryption>` parser reports
///   protected resources we cannot decrypt. Surface as "This ePub is
///   DRM-protected and cannot be imported."
/// * `EmptyText` — the parser succeeded but produced no readable
///   prose (every spine item was a cover image, a nav document, or a
///   blank XHTML stub). Surface as "We could not extract any readable
///   text from this ePub."
/// * `ParseFailed(detail)` — anything else the parser threw. `detail`
///   is the JS-side error message so the reader sees a specific
///   explanation rather than a generic failure.
pub type EpubError {
  UnsupportedFormat
  DrmEncrypted
  EmptyText
  ParseFailed(detail: String)
}

/// Parse an ePub `File` (passed as `Dynamic` because the browser
/// `File` object does not round-trip through Gleam's typed runtime)
/// and invoke `on_complete` with either an `EpubExtract` or an
/// `EpubError`. The FFI runs the parse asynchronously — foliate-js
/// awaits the underlying `arrayBuffer()` Promise and walks the spine
/// in turn — so the callback fires on a microtask, not synchronously.
///
/// Only fired once per call.
@external(javascript, "./epub.ffi.mjs", "parse_epub_file")
pub fn parse_epub_file(
  file: Dynamic,
  on_complete: fn(Result(EpubExtract, EpubError)) -> Nil,
) -> Nil

// ---------------------------------------------------------------------------
// File-input event helper
// ---------------------------------------------------------------------------

/// Listen for `change` on a `<input type="file">` and dispatch
/// `to_msg(file_dynamic)` when the user picks a file. The dynamic
/// payload is the raw browser `File` object — keep it opaque and
/// thread it straight back through to `parse_epub_file`.
///
/// Lustre v5's built-in `event.on_change` only surfaces
/// `event.target.value` (an empty string for file inputs) so it
/// cannot carry a file payload at all. The custom decoder here calls
/// into the FFI to extract `event.target.files[0]` and routes it
/// through the same `event.on` / `decode.then` pipeline the touch
/// gestures use. When the input changes with no file selected (rare
/// — the browser only emits `change` after a successful pick) the
/// decoder fails so no Msg is dispatched at all.
pub fn on_file_picked(to_msg: fn(Dynamic) -> msg) -> Attribute(msg) {
  event.on("change", file_picker_decoder(to_msg))
}

fn file_picker_decoder(to_msg: fn(Dynamic) -> msg) -> decode.Decoder(msg) {
  // `decode.dynamic` passes the raw event through unchanged; we read
  // `target.files[0]` off it via FFI rather than walking the path
  // with `decode.field` because `FileList` is array-like, not a Gleam
  // `List`, and a `decode.list` on it would only work after a
  // platform-specific coercion that the runtime cannot guarantee.
  use raw_event <- decode.then(decode.dynamic)
  case read_picked_file(raw_event) {
    Ok(file) -> decode.success(to_msg(file))
    // A `change` event with no `files[0]` (e.g. the picker dialog
    // was dismissed) cannot produce a useful Msg. `decode.failure`
    // signals Lustre to drop the event rather than dispatch a
    // half-formed message; the `to_msg(dynamic.nil())` placeholder
    // only exists to pin the decoder's `msg` type — it is never
    // actually dispatched on the failure branch.
    Error(_) -> decode.failure(to_msg(dynamic.nil()), "no file picked")
  }
}

@external(javascript, "./epub.ffi.mjs", "read_picked_file")
fn read_picked_file(event: Dynamic) -> Result(Dynamic, Nil)

/// Reset the `.value` of every ePub-import file input in the DOM.
/// Called from an effect after `EpubFileSelected` so that a
/// subsequent pick of the same file path still fires a `change`
/// event — without the reset, the browser short-circuits because the
/// input's value did not change. Kept as a side-effecting FFI rather
/// than mutating from the event decoder so the decoder stays a pure
/// projection of the event payload.
@external(javascript, "./epub.ffi.mjs", "reset_picker_inputs")
pub fn reset_picker_inputs() -> Nil
