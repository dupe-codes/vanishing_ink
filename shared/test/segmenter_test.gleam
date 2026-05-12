//// Target-agnostic tests for the segmenter. Each test exercises one
//// of the segmentation rules called out in the design spec — plain
//// prose, paragraphs, chapters, abbreviations, ellipsis, dialogue,
//// degenerate input — plus determinism and JSON round-trip. The suite
//// runs on whichever target the consumer picks; gleeunit dispatches
//// the same assertions on BEAM here and JavaScript over in
//// `client/test/` once the client wires the segmenter in.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
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

  // "Hello world." segments into ["Hello", "world."].
  let assert [w0, w1] = s0.words
  assert w0 == Word(index: 0, global_index: 0, text: "Hello")
  assert w1 == Word(index: 1, global_index: 1, text: "world.")

  // "This is a test." segments into ["This", "is", "a", "test."].
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

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "First"),
            Word(index: 1, global_index: 1, text: "paragraph"),
            Word(index: 2, global_index: 2, text: "here."),
          ]),
        ]),
        Paragraph(index: 1, sentences: [
          Sentence(index: 0, global_index: 1, words: [
            Word(index: 0, global_index: 3, text: "Second"),
            Word(index: 1, global_index: 4, text: "paragraph"),
            Word(index: 2, global_index: 5, text: "here."),
          ]),
        ]),
      ]),
    ])
}

pub fn empty_paragraphs_are_skipped_test() {
  // Two paragraphs with extra blank space between them. The cluster of
  // blank lines should collapse into a single paragraph break, not an
  // empty paragraph and not a chapter break (that needs >= 2 blanks
  // *and* prior content survives the run — see the chapter-break test).
  let result = segmenter.segment("Alpha.\n\nBeta.")

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Alpha."),
          ]),
        ]),
        Paragraph(index: 1, sentences: [
          Sentence(index: 0, global_index: 1, words: [
            Word(index: 0, global_index: 1, text: "Beta."),
          ]),
        ]),
      ]),
    ])
}

// ---------------------------------------------------------------------------
// 3. Multi-chapter
// ---------------------------------------------------------------------------

pub fn detects_chapter_n_headings_test() {
  let text =
    "Chapter 1\n\nFirst chapter prose here.\n\nChapter 2\n\nSecond chapter prose."
  let result = segmenter.segment(text)

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: Some("Chapter 1"), paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "First"),
            Word(index: 1, global_index: 1, text: "chapter"),
            Word(index: 2, global_index: 2, text: "prose"),
            Word(index: 3, global_index: 3, text: "here."),
          ]),
        ]),
      ]),
      Chapter(index: 1, title: Some("Chapter 2"), paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 1, words: [
            Word(index: 0, global_index: 4, text: "Second"),
            Word(index: 1, global_index: 5, text: "chapter"),
            Word(index: 2, global_index: 6, text: "prose."),
          ]),
        ]),
      ]),
    ])
}

pub fn detects_roman_numeral_chapter_headings_test() {
  let text = "Chapter IV\n\nFour. Roman."
  let result = segmenter.segment(text)

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: Some("Chapter IV"), paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Four."),
          ]),
          Sentence(index: 1, global_index: 1, words: [
            Word(index: 0, global_index: 1, text: "Roman."),
          ]),
        ]),
      ]),
    ])
}

pub fn detects_markdown_headings_test() {
  let text = "# Prologue\n\nIt begins here.\n\n## Part Two\n\nIt ends here."
  let result = segmenter.segment(text)

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: Some("Prologue"), paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "It"),
            Word(index: 1, global_index: 1, text: "begins"),
            Word(index: 2, global_index: 2, text: "here."),
          ]),
        ]),
      ]),
      Chapter(index: 1, title: Some("Part Two"), paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 1, words: [
            Word(index: 0, global_index: 3, text: "It"),
            Word(index: 1, global_index: 4, text: "ends"),
            Word(index: 2, global_index: 5, text: "here."),
          ]),
        ]),
      ]),
    ])
}

pub fn triple_newlines_create_untitled_chapter_break_test() {
  let text = "Some text here.\n\n\nMore text here."
  let result = segmenter.segment(text)

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Some"),
            Word(index: 1, global_index: 1, text: "text"),
            Word(index: 2, global_index: 2, text: "here."),
          ]),
        ]),
      ]),
      Chapter(index: 1, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 1, words: [
            Word(index: 0, global_index: 3, text: "More"),
            Word(index: 1, global_index: 4, text: "text"),
            Word(index: 2, global_index: 5, text: "here."),
          ]),
        ]),
      ]),
    ])
}

pub fn no_chapter_patterns_wraps_in_single_implicit_chapter_test() {
  let result = segmenter.segment("Just some prose without any structure.")

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Just"),
            Word(index: 1, global_index: 1, text: "some"),
            Word(index: 2, global_index: 2, text: "prose"),
            Word(index: 3, global_index: 3, text: "without"),
            Word(index: 4, global_index: 4, text: "any"),
            Word(index: 5, global_index: 5, text: "structure."),
          ]),
        ]),
      ]),
    ])
}

pub fn line_starting_with_chapter_but_not_heading_is_prose_test() {
  // "Chapter is over" is regular prose — the word after "Chapter " is
  // neither a digit run nor a valid roman numeral, so the segmenter
  // must not treat it as a heading.
  let result = segmenter.segment("Chapter is over for me, I think.")

  let assert [chapter] = result.chapters
  assert chapter.title == None
  let assert [paragraph] = chapter.paragraphs
  let assert [sentence] = paragraph.sentences

  let texts = list.map(sentence.words, fn(w) { w.text })
  assert texts == ["Chapter", "is", "over", "for", "me,", "I", "think."]
}

pub fn chapter_followed_by_lowercase_roman_word_is_prose_test() {
  // Regression: the Roman-numeral chapter heuristic must not admit
  // English words whose letters all happen to live in the Roman set
  // (i, v, x, l, c, d, m). Words like "mid", "civil", "lid", "mix"
  // are all-lowercase prose, not chapter labels. Without this guard
  // the entire first line is swallowed as a chapter title and the
  // prose after the first period gets dropped from the body.
  let result =
    segmenter.segment("Chapter mid is bright. We continue.\n\nMore text.")

  let assert [chapter] = result.chapters
  assert chapter.title == None

  let assert [p0, p1] = chapter.paragraphs
  let assert [s0, s1] = p0.sentences
  let texts_s0 = list.map(s0.words, fn(w) { w.text })
  let texts_s1 = list.map(s1.words, fn(w) { w.text })
  assert texts_s0 == ["Chapter", "mid", "is", "bright."]
  assert texts_s1 == ["We", "continue."]

  let assert [s2] = p1.sentences
  let texts_s2 = list.map(s2.words, fn(w) { w.text })
  assert texts_s2 == ["More", "text."]
}

pub fn chapter_followed_by_non_canonical_uppercase_token_is_prose_test() {
  // "MID" passes the uppercase + character-set check but is not a
  // canonical Roman numeral (the value 1499 canonicalises to MCDXCIX).
  // The structural validator must reject it, otherwise all-uppercase
  // prose words sneak through.
  let result = segmenter.segment("Chapter MID is loud. We continue.")

  let assert [chapter] = result.chapters
  assert chapter.title == None
  let assert [paragraph] = chapter.paragraphs
  let assert [s0, s1] = paragraph.sentences

  let texts_s0 = list.map(s0.words, fn(w) { w.text })
  let texts_s1 = list.map(s1.words, fn(w) { w.text })
  assert texts_s0 == ["Chapter", "MID", "is", "loud."]
  assert texts_s1 == ["We", "continue."]
}

pub fn adjacent_headings_preserve_first_title_test() {
  // Regression: two heading lines in a row (no content between them)
  // used to clobber the first title. The first chapter must survive
  // as a titled-but-empty chapter so the heading is not silently lost.
  let text = "Chapter 1\n# Prologue\n\nText here."
  let result = segmenter.segment(text)

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: Some("Chapter 1"), paragraphs: []),
      Chapter(index: 1, title: Some("Prologue"), paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "Text"),
            Word(index: 1, global_index: 1, text: "here."),
          ]),
        ]),
      ]),
    ])
}

pub fn trailing_heading_without_body_preserves_title_test() {
  // A trailing heading with no body still produces an empty titled
  // chapter — symmetric with the adjacent-heading rule. Without this
  // the trailing title would be silently dropped at document close.
  let text = "First chapter prose.\n\n# Epilogue"
  let result = segmenter.segment(text)

  assert result
    == SegmentedText(chapters: [
      Chapter(index: 0, title: None, paragraphs: [
        Paragraph(index: 0, sentences: [
          Sentence(index: 0, global_index: 0, words: [
            Word(index: 0, global_index: 0, text: "First"),
            Word(index: 1, global_index: 1, text: "chapter"),
            Word(index: 2, global_index: 2, text: "prose."),
          ]),
        ]),
      ]),
      Chapter(index: 1, title: Some("Epilogue"), paragraphs: []),
    ])
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
  let assert [sentence] = paragraph.sentences

  let texts = list.map(sentence.words, fn(w) { w.text })
  assert texts == ["The", "U.S.A.", "is", "a", "country."]
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
  let assert [sentence] = paragraph.sentences

  let texts = list.map(sentence.words, fn(w) { w.text })
  assert texts == ["He", "waited...", "Then", "left."]
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
// 11. Long input
// ---------------------------------------------------------------------------

pub fn segments_very_long_input_test() {
  // The done-when criterion for this quest names a very long text path
  // explicitly. Synthesise a multi-chapter, multi-thousand-word book
  // and assert the global-index contract holds end to end — the first
  // sentence/word are at zero, the chapter count matches, and the
  // final sentence/word globals equal (total - 1).
  let chapter_count = 10
  let sentences_per_chapter = 50
  let words_per_sentence = 10
  let total_sentences = chapter_count * sentences_per_chapter
  let total_words = total_sentences * words_per_sentence

  let text =
    build_synthetic_book(
      chapter_count,
      sentences_per_chapter,
      words_per_sentence,
    )
  let result = segmenter.segment(text)

  assert list.length(result.chapters) == chapter_count

  let assert [first_chapter, ..] = result.chapters
  let assert [first_paragraph, ..] = first_chapter.paragraphs
  let assert [first_sentence, ..] = first_paragraph.sentences
  let assert [first_word, ..] = first_sentence.words
  assert first_chapter.index == 0
  assert first_chapter.title == Some("Chapter 1")
  assert first_sentence.index == 0
  assert first_sentence.global_index == 0
  assert first_word == Word(index: 0, global_index: 0, text: "Word")

  let assert Ok(last_chapter) = list.last(result.chapters)
  let assert Ok(last_paragraph) = list.last(last_chapter.paragraphs)
  let assert Ok(last_sentence) = list.last(last_paragraph.sentences)
  let assert Ok(last_word) = list.last(last_sentence.words)
  assert last_chapter.index == chapter_count - 1
  assert last_chapter.title == Some("Chapter 10")
  assert last_sentence.global_index == total_sentences - 1
  assert last_word.global_index == total_words - 1
}

fn build_synthetic_book(
  chapters: Int,
  sentences: Int,
  words_per_sentence: Int,
) -> String {
  // `int.range` is exclusive of its `to` argument, so the upper bounds
  // are `+ 1` to make the ranges inclusive of the natural chapter and
  // sentence counts.
  let chapter_parts_rev =
    int.range(1, chapters + 1, [], fn(acc, c) {
      let header = "Chapter " <> int.to_string(c)
      // Sentences must start with an uppercase letter so the
      // sentence-boundary heuristic actually splits them; otherwise
      // the body collapses into one long sentence and the long-input
      // path is never exercised.
      let sentence_parts_rev =
        int.range(1, sentences + 1, [], fn(s_acc, _) {
          let assert [first, ..rest] = list.repeat("word", words_per_sentence)
          let word_list = [string.capitalise(first), ..rest]
          [string.join(word_list, " ") <> ".", ..s_acc]
        })
      let body = sentence_parts_rev |> list.reverse |> string.join(" ")
      [header <> "\n\n" <> body, ..acc]
    })
  chapter_parts_rev |> list.reverse |> string.join("\n\n")
}

// ---------------------------------------------------------------------------
// 12. JSON round-trip
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
