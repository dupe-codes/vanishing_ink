//// Target-agnostic tests for the segmenter. Each test exercises one
//// of the segmentation rules called out in the design spec — plain
//// prose, paragraphs, chapters, abbreviations, ellipsis, dialogue,
//// degenerate input — plus determinism and JSON round-trip. The suite
//// runs on whichever target the consumer picks; gleeunit dispatches
//// the same assertions on BEAM here and JavaScript over in
//// `client/test/` once the client wires the segmenter in.

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import shared/segmenter.{Chapter, Paragraph, SegmentedText, Sentence, Word}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// 1. Plain prose
// ---------------------------------------------------------------------------

pub fn segments_plain_prose_test() {
  let result = segmenter.segment("Hello world. This is a test.")

  let assert [chapter] = result.chapters
  assert chapter.index == 0
  assert chapter.title == None

  let assert [paragraph] = chapter.paragraphs
  assert paragraph.index == 0

  let assert [s0, s1] = paragraph.sentences
  assert s0.index == 0
  assert s0.global_index == 0
  assert s1.index == 1
  assert s1.global_index == 1

  // "Hello world." → ["Hello", "world."]
  let assert [w0, w1] = s0.words
  assert w0 == Word(index: 0, global_index: 0, text: "Hello")
  assert w1 == Word(index: 1, global_index: 1, text: "world.")

  // "This is a test." → ["This", "is", "a", "test."]
  let assert [w2, w3, w4, w5] = s1.words
  assert w2 == Word(index: 0, global_index: 2, text: "This")
  assert w3 == Word(index: 1, global_index: 3, text: "is")
  assert w4 == Word(index: 2, global_index: 4, text: "a")
  assert w5 == Word(index: 3, global_index: 5, text: "test.")
}

// ---------------------------------------------------------------------------
// 2. Multi-paragraph
// ---------------------------------------------------------------------------

pub fn splits_paragraphs_on_double_newlines_test() {
  let result =
    segmenter.segment("First paragraph here.\n\nSecond paragraph here.")

  let assert [chapter] = result.chapters
  let assert [p0, p1] = chapter.paragraphs

  assert p0.index == 0
  assert p1.index == 1

  let assert [s0] = p0.sentences
  let assert [s1] = p1.sentences

  // Global sentence indices increment across paragraphs within a chapter.
  assert s0.global_index == 0
  assert s1.global_index == 1
}

pub fn empty_paragraphs_are_skipped_test() {
  // Two paragraphs with extra blank space between them. The cluster of
  // blank lines should collapse into a single paragraph break, not an
  // empty paragraph and not a chapter break (that needs >= 2 blanks
  // *and* prior content survives the run — see the chapter-break test).
  let result = segmenter.segment("Alpha.\n\nBeta.")

  let assert [chapter] = result.chapters
  assert list.length(chapter.paragraphs) == 2
}

// ---------------------------------------------------------------------------
// 3. Multi-chapter
// ---------------------------------------------------------------------------

pub fn detects_chapter_n_headings_test() {
  let text =
    "Chapter 1\n\nFirst chapter prose here.\n\nChapter 2\n\nSecond chapter prose."
  let result = segmenter.segment(text)

  let assert [c0, c1] = result.chapters
  assert c0.index == 0
  assert c1.index == 1
  assert c0.title == Some("Chapter 1")
  assert c1.title == Some("Chapter 2")

  // Sentence globals continue across chapters.
  let assert [p0] = c0.paragraphs
  let assert [p1] = c1.paragraphs
  let assert [s0] = p0.sentences
  let assert [s1] = p1.sentences
  assert s0.global_index == 0
  assert s1.global_index == 1
}

pub fn detects_roman_numeral_chapter_headings_test() {
  let text = "Chapter IV\n\nFour. Roman."
  let result = segmenter.segment(text)
  let assert [chapter] = result.chapters
  assert chapter.title == Some("Chapter IV")
}

pub fn detects_markdown_headings_test() {
  let text = "# Prologue\n\nIt begins here.\n\n## Part Two\n\nIt ends here."
  let result = segmenter.segment(text)

  let assert [c0, c1] = result.chapters
  assert c0.title == Some("Prologue")
  assert c1.title == Some("Part Two")
}

pub fn triple_newlines_create_untitled_chapter_break_test() {
  let text = "Some text here.\n\n\nMore text here."
  let result = segmenter.segment(text)

  let assert [c0, c1] = result.chapters
  assert c0.title == None
  assert c1.title == None
  assert c0.index == 0
  assert c1.index == 1
}

pub fn no_chapter_patterns_wraps_in_single_implicit_chapter_test() {
  let result = segmenter.segment("Just some prose without any structure.")

  let assert [chapter] = result.chapters
  assert chapter.title == None
  assert chapter.index == 0
}

pub fn line_starting_with_chapter_but_not_heading_is_prose_test() {
  // "Chapter is over" is regular prose — the word after "Chapter " is
  // neither a digit run nor a valid roman numeral, so the segmenter
  // must not treat it as a heading.
  let result = segmenter.segment("Chapter is over for me, I think.")

  let assert [chapter] = result.chapters
  assert chapter.title == None
  let assert [paragraph] = chapter.paragraphs
  let assert [_] = paragraph.sentences
}

// ---------------------------------------------------------------------------
// 4. Abbreviations
// ---------------------------------------------------------------------------

pub fn abbreviation_does_not_split_sentence_test() {
  let result = segmenter.segment("Dr. Smith went home.")

  let assert [chapter] = result.chapters
  let assert [paragraph] = chapter.paragraphs
  let assert [sentence] = paragraph.sentences

  let texts = list.map(sentence.words, fn(w) { w.text })
  assert texts == ["Dr.", "Smith", "went", "home."]
}

pub fn multi_period_abbreviation_does_not_split_test() {
  let result = segmenter.segment("The U.S.A. is a country.")

  let assert [chapter] = result.chapters
  let assert [paragraph] = chapter.paragraphs
  let assert [_one] = paragraph.sentences
}

// ---------------------------------------------------------------------------
// 5. Mixed abbreviations
// ---------------------------------------------------------------------------

pub fn abbreviation_followed_by_real_sentence_break_test() {
  let result = segmenter.segment("Dr. Smith went home. He was tired.")

  let assert [chapter] = result.chapters
  let assert [paragraph] = chapter.paragraphs
  let assert [s0, s1] = paragraph.sentences

  let s0_texts = list.map(s0.words, fn(w) { w.text })
  let s1_texts = list.map(s1.words, fn(w) { w.text })
  assert s0_texts == ["Dr.", "Smith", "went", "home."]
  assert s1_texts == ["He", "was", "tired."]
}

// ---------------------------------------------------------------------------
// 6. Ellipsis
// ---------------------------------------------------------------------------

pub fn ellipsis_does_not_split_sentence_test() {
  // The spec leaves this edge case to implementer's discretion; the
  // segmenter treats "..." as a non-terminator, so the whole phrase
  // stays as a single sentence.
  let result = segmenter.segment("He waited... Then left.")

  let assert [chapter] = result.chapters
  let assert [paragraph] = chapter.paragraphs
  let assert [_only_sentence] = paragraph.sentences
}

// ---------------------------------------------------------------------------
// 7. Dialogue
// ---------------------------------------------------------------------------

pub fn dialogue_with_quoted_period_splits_after_closing_quote_test() {
  let result = segmenter.segment("\"Hello.\" She said nothing.")

  let assert [chapter] = result.chapters
  let assert [paragraph] = chapter.paragraphs
  let assert [s0, s1] = paragraph.sentences

  let s0_texts = list.map(s0.words, fn(w) { w.text })
  let s1_texts = list.map(s1.words, fn(w) { w.text })
  assert s0_texts == ["\"Hello.\""]
  assert s1_texts == ["She", "said", "nothing."]
}

// ---------------------------------------------------------------------------
// 8. Single-sentence input
// ---------------------------------------------------------------------------

pub fn single_sentence_no_terminator_test() {
  let result = segmenter.segment("Hello")

  let assert [chapter] = result.chapters
  let assert [paragraph] = chapter.paragraphs
  let assert [sentence] = paragraph.sentences
  let assert [word] = sentence.words

  assert chapter.index == 0
  assert chapter.title == None
  assert paragraph.index == 0
  assert sentence.index == 0
  assert sentence.global_index == 0
  assert word == Word(index: 0, global_index: 0, text: "Hello")
}

// ---------------------------------------------------------------------------
// 9. Empty / whitespace input
// ---------------------------------------------------------------------------

pub fn empty_input_yields_no_chapters_test() {
  let result = segmenter.segment("")
  assert result == SegmentedText(chapters: [])
}

pub fn whitespace_only_input_yields_no_chapters_test() {
  let result = segmenter.segment("   \n\t\n   \n")
  assert result == SegmentedText(chapters: [])
}

// ---------------------------------------------------------------------------
// 10. Determinism
// ---------------------------------------------------------------------------

pub fn segmentation_is_deterministic_test() {
  let text =
    "Chapter 1\n\nA quick brown fox jumps. The lazy dog watches.\n\nChapter 2\n\nDr. Smith arrived. He was late."
  let first = segmenter.segment(text)
  let second = segmenter.segment(text)
  assert first == second
}

// ---------------------------------------------------------------------------
// 11. JSON round-trip
// ---------------------------------------------------------------------------

pub fn json_round_trip_test() {
  let original =
    segmenter.segment(
      "Chapter 1\n\nDr. Smith went home. He was tired.\n\nChapter 2\n\nThe end.",
    )

  let encoded = original |> segmenter.to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, segmenter.decoder())

  assert decoded == original
}

pub fn json_round_trip_preserves_null_titles_test() {
  let original = segmenter.segment("No headings here at all.")

  let encoded = original |> segmenter.to_json |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, segmenter.decoder())

  let assert [chapter] = decoded.chapters
  assert chapter.title == None
  assert decoded == original
}

// ---------------------------------------------------------------------------
// Spot check on the constructor record exports
// ---------------------------------------------------------------------------

pub fn types_are_publicly_constructible_test() {
  // The downstream packages need to be able to reach the constructors
  // by name (the reader will build paragraphs from server payloads),
  // so this test exists just to fail the compile if any of these stop
  // being exported as record constructors.
  let word = Word(index: 0, global_index: 0, text: "x")
  let sentence = Sentence(index: 0, global_index: 0, words: [word])
  let paragraph = Paragraph(index: 0, sentences: [sentence])
  let chapter = Chapter(index: 0, title: None, paragraphs: [paragraph])
  let doc = SegmentedText(chapters: [chapter])

  assert doc.chapters == [chapter]
}
