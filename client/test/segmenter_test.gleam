//// JavaScript-target tests for the cross-target segmenter. The
//// segmenter joins `shared/` and runs on both Erlang and V8 — the
//// runtime-sensitive surface is `string.to_graphemes`, the sentence
//// terminator/whitespace heuristics that walk those graphemes, and
//// the `gleam_json` round trip. If either implementation drifts on
//// the JS side these tests will fail in CI before client code starts
//// consuming server payloads.
////
//// This file mirrors `shared/test/segmenter_test.gleam` for the two
//// invariants the BEAM↔JS dual-test pattern is most useful for: a
//// segmentation that exercises grapheme classification, and a JSON
//// round trip.

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import shared/segmenter.{Chapter, Paragraph, SegmentedText, Sentence, Word}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn segmenter_segments_basic_prose_on_js_target_test() {
  // Exercises grapheme classification (sentence terminators, whitespace,
  // word boundaries) on the V8 side. If `string.to_graphemes` behaves
  // differently from the BEAM target this assertion will catch it.
  let result = segmenter.segment("Hello world. This is a test.")

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Hello"),
            Word(index: 1, global_index: 1, text: "world."),
          ]),
          Sentence(index: 1, global_index: 1, words: [
            Word(index: 0, global_index: 2, text: "This"),
            Word(index: 1, global_index: 3, text: "is"),
            Word(index: 2, global_index: 4, text: "a"),
            Word(index: 3, global_index: 5, text: "test."),
          ]),
        ]),
      ]),
    ])
}

pub fn segmenter_round_trip_on_js_target_test() {
  // The `gleam_json` encoder and decoder must agree under
  // `JSON.stringify` / `JSON.parse` semantics on V8 — a property the
  // type system cannot establish. The BEAM side gets the same
  // assertion over in `shared/test/`; if either target drifts one of
  // the two test pairs will fail in CI.
  let original =
    segmenter.segment(
      "Chapter 1\n\nDr. Smith went home. He was tired.\n\nChapter 2\n\nThe end.",
    )

  let encoded = original |> segmenter.to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, segmenter.decoder())

  assert decoded == original

  // Spot-check structural fields on the decoded value to make sure
  // we are actually exercising the segmenter and not just a no-op.
  let assert [c0, c1] = decoded.chapters
  assert c0.title == Some("Chapter 1")
  assert c1.title == Some("Chapter 2")
  let assert [p0] = c0.paragraphs
  let s_texts =
    list.flat_map(p0.sentences, fn(s) { list.map(s.words, fn(w) { w.text }) })
  assert s_texts == ["Dr.", "Smith", "went", "home.", "He", "was", "tired."]
}
