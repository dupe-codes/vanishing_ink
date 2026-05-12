//// Text segmenter for Vanishing Ink. Turns a raw book string into a
//// structured tree of chapters → paragraphs → sentences → words, with
//// stable local indices at every level and global indices on sentences
//// and words.
////
//// The reading-state bitset addresses words and sentences by global
//// index regardless of where they sit in the chapter/paragraph nesting,
//// so the order in which globals are assigned here is part of the
//// public contract: sentences and words are numbered in document
//// reading order, starting at zero.
////
//// This module is target-agnostic — pure Gleam plus `gleam_stdlib` and
//// `gleam_json` — so the same segmentation runs on the BEAM server at
//// upload time and on the JavaScript client when it re-decodes the
//// stored JSON.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Top-level structured output. Holds the ordered list of chapters
/// produced from a single raw input string.
pub type SegmentedText {
  SegmentedText(chapters: List(Chapter))
}

/// A chapter in the segmented document.
///
/// `index` is the chapter's position in the book (zero-based). `title`
/// is `None` for the implicit chapter that wraps untitled input and for
/// chapters introduced by blank-line breaks rather than an explicit
/// heading.
pub type Chapter {
  Chapter(index: Int, title: Option(String), paragraphs: List(Paragraph))
}

/// A paragraph. `index` is local to the enclosing chapter.
pub type Paragraph {
  Paragraph(index: Int, sentences: List(Sentence))
}

/// A sentence. `index` is local to the enclosing paragraph;
/// `global_index` is the sentence's position across the entire book.
pub type Sentence {
  Sentence(index: Int, global_index: Int, words: List(Word))
}

/// A word with its in-sentence and book-global indices. Punctuation
/// stays attached to the word (`"Hello,"` is one word, not two).
pub type Word {
  Word(index: Int, global_index: Int, text: String)
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Segment a raw text string into the structured `SegmentedText` tree.
///
/// The function is total — every input produces a `SegmentedText`. An
/// empty or whitespace-only input yields a document with no chapters.
/// Re-running the function on the same input is deterministic and
/// produces an equal value.
pub fn segment(raw: String) -> SegmentedText {
  let blocks =
    raw
    |> string.split("\n")
    |> list.map(classify_line)
    |> build_chapter_blocks
  SegmentedText(chapters: build_chapters(blocks))
}

// ---------------------------------------------------------------------------
// Chapter / paragraph detection
// ---------------------------------------------------------------------------

type LineKind {
  BlankLine
  HeadingLine(title: String)
  ContentLine(text: String)
}

type ChapterBlock {
  ChapterBlock(title: Option(String), paragraphs: List(List(String)))
}

type ChapterState {
  ChapterState(
    finalized: List(ChapterBlock),
    current_title: Option(String),
    finalized_paragraphs: List(List(String)),
    current_paragraph: List(String),
    blanks_since_content: Int,
    saw_content_in_chapter: Bool,
  )
}

fn classify_line(line: String) -> LineKind {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> BlankLine
    _ ->
      case parse_heading(trimmed) {
        Some(title) -> HeadingLine(title)
        None -> ContentLine(trimmed)
      }
  }
}

fn parse_heading(line: String) -> Option(String) {
  case markdown_heading(line) {
    Some(title) -> Some(title)
    None ->
      case chapter_n_heading(line) {
        True -> Some(line)
        False -> None
      }
  }
}

fn markdown_heading(line: String) -> Option(String) {
  let graphemes = string.to_graphemes(line)
  consume_hashes(graphemes, 0)
}

fn consume_hashes(graphemes: List(String), count: Int) -> Option(String) {
  case graphemes {
    ["#", ..rest] -> consume_hashes(rest, count + 1)
    [" ", ..rest] ->
      case count {
        0 -> None
        _ ->
          case string.trim(string.concat(rest)) {
            "" -> None
            title -> Some(title)
          }
      }
    _ -> None
  }
}

fn chapter_n_heading(line: String) -> Bool {
  case string.starts_with(string.lowercase(line), "chapter ") {
    False -> False
    True -> {
      // Take the chapter token from the *original* line so case-sensitive
      // structural checks — uppercase-only Roman numerals — can run. The
      // "chapter " prefix is pure ASCII, so dropping eight graphemes from
      // the original is safe regardless of how the original was cased.
      let rest = string.trim_start(string.drop_start(line, 8))
      let #(token, tail) = take_chapter_token(string.to_graphemes(rest), [])
      case token {
        [] -> False
        _ ->
          case is_all_digits(token) || is_valid_roman_numeral(token) {
            False -> False
            // Heading must occupy the whole line — no trailing prose
            // after the token. Without this guard, English prose that
            // starts "Chapter II is..." / "Chapter 1 was..." passes the
            // structural checks on the leading token and the entire line
            // is swallowed as a title, dropping the prose body.
            True -> list.all(tail, is_whitespace)
          }
      }
    }
  }
}

fn take_chapter_token(
  graphemes: List(String),
  acc: List(String),
) -> #(List(String), List(String)) {
  case graphemes {
    [] -> #(list.reverse(acc), [])
    [g, ..rest] ->
      case is_alphanumeric(g) {
        True -> take_chapter_token(rest, [g, ..acc])
        False -> #(list.reverse(acc), graphemes)
      }
  }
}

fn is_alphanumeric(g: String) -> Bool {
  case g {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> {
      let lower = string.lowercase(g)
      case string.to_graphemes(lower) {
        [c] -> is_lowercase_ascii_letter(c)
        _ -> False
      }
    }
  }
}

fn is_lowercase_ascii_letter(g: String) -> Bool {
  case g {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z" -> True
    _ -> False
  }
}

fn is_all_digits(token: List(String)) -> Bool {
  list.all(token, fn(g) {
    case g {
      "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
      _ -> False
    }
  })
}

// ---------------------------------------------------------------------------
// Roman numerals
// ---------------------------------------------------------------------------
//
// The earlier heuristic accepted any token composed of {i,v,x,l,c,d,m}
// after lowercasing, which let English words like "mid", "civil", "lid"
// and "mix" pose as chapter numbers and swallow the rest of the line.
// The replacement requires uppercase letters in the original input and
// verifies that re-encoding the decoded value yields the same token.
// That rejects lowercase prose, malformed structures like "MID" or
// "IIII", and out-of-range values; only the standard 1..3999 forms pass.

fn is_valid_roman_numeral(token: List(String)) -> Bool {
  case list.all(token, is_uppercase_roman_char) {
    False -> False
    True -> {
      let value = decode_roman_numeral(token)
      case value >= 1 && value <= 3999 {
        False -> False
        True -> encode_roman_numeral(value) == token
      }
    }
  }
}

fn is_uppercase_roman_char(g: String) -> Bool {
  case g {
    "I" | "V" | "X" | "L" | "C" | "D" | "M" -> True
    _ -> False
  }
}

fn roman_char_value(g: String) -> Int {
  case g {
    "I" -> 1
    "V" -> 5
    "X" -> 10
    "L" -> 50
    "C" -> 100
    "D" -> 500
    "M" -> 1000
    _ -> 0
  }
}

fn decode_roman_numeral(graphemes: List(String)) -> Int {
  decode_roman_loop(graphemes, 0)
}

fn decode_roman_loop(graphemes: List(String), acc: Int) -> Int {
  case graphemes {
    [] -> acc
    [a, b, ..rest] -> {
      let va = roman_char_value(a)
      let vb = roman_char_value(b)
      case va < vb {
        True -> decode_roman_loop(rest, acc + vb - va)
        False -> decode_roman_loop([b, ..rest], acc + va)
      }
    }
    [a] -> acc + roman_char_value(a)
  }
}

fn encode_roman_numeral(value: Int) -> List(String) {
  encode_roman_loop(value, [])
  |> list.reverse
}

fn encode_roman_loop(value: Int, acc: List(String)) -> List(String) {
  case value {
    v if v >= 1000 -> encode_roman_loop(v - 1000, ["M", ..acc])
    v if v >= 900 -> encode_roman_loop(v - 900, ["M", "C", ..acc])
    v if v >= 500 -> encode_roman_loop(v - 500, ["D", ..acc])
    v if v >= 400 -> encode_roman_loop(v - 400, ["D", "C", ..acc])
    v if v >= 100 -> encode_roman_loop(v - 100, ["C", ..acc])
    v if v >= 90 -> encode_roman_loop(v - 90, ["C", "X", ..acc])
    v if v >= 50 -> encode_roman_loop(v - 50, ["L", ..acc])
    v if v >= 40 -> encode_roman_loop(v - 40, ["L", "X", ..acc])
    v if v >= 10 -> encode_roman_loop(v - 10, ["X", ..acc])
    v if v >= 9 -> encode_roman_loop(v - 9, ["X", "I", ..acc])
    v if v >= 5 -> encode_roman_loop(v - 5, ["V", ..acc])
    v if v >= 4 -> encode_roman_loop(v - 4, ["V", "I", ..acc])
    v if v >= 1 -> encode_roman_loop(v - 1, ["I", ..acc])
    _ -> acc
  }
}

fn build_chapter_blocks(lines: List(LineKind)) -> List(ChapterBlock) {
  let initial =
    ChapterState(
      finalized: [],
      current_title: None,
      finalized_paragraphs: [],
      current_paragraph: [],
      blanks_since_content: 0,
      saw_content_in_chapter: False,
    )
  let final_state = list.fold(lines, initial, fold_line)
  let closed = close_current_chapter(final_state)
  list.reverse(closed.finalized)
}

fn fold_line(state: ChapterState, kind: LineKind) -> ChapterState {
  case kind {
    BlankLine ->
      ChapterState(
        ..close_current_paragraph(state),
        blanks_since_content: state.blanks_since_content + 1,
      )

    HeadingLine(title) -> {
      // A heading always starts a new chapter. Push the current chapter
      // to `finalized` if it carries either content or a title — a
      // titled-but-empty chapter is a legitimate outcome of two
      // headings in a row, and dropping it would silently lose the
      // first title.
      let with_para_closed = close_current_paragraph(state)
      let has_title_only = case with_para_closed.current_title {
        Some(_) -> True
        None -> False
      }
      let next_finalized = case
        with_para_closed.saw_content_in_chapter || has_title_only
      {
        True -> [
          ChapterBlock(
            with_para_closed.current_title,
            list.reverse(with_para_closed.finalized_paragraphs),
          ),
          ..with_para_closed.finalized
        ]
        False -> with_para_closed.finalized
      }
      ChapterState(
        finalized: next_finalized,
        current_title: Some(title),
        finalized_paragraphs: [],
        current_paragraph: [],
        blanks_since_content: 0,
        saw_content_in_chapter: False,
      )
    }

    ContentLine(text) -> {
      // Resolve any pending blank run before appending the line.
      // - 2+ blanks inside a chapter that already saw content → implicit
      //   chapter break (no title).
      // - 1+ blank → paragraph break only.
      // - 0 blanks → continuation of the current paragraph.
      let staged = case
        state.blanks_since_content >= 2 && state.saw_content_in_chapter
      {
        True -> {
          let closed = close_current_paragraph(state)
          let pushed =
            ChapterState(
              finalized: [
                ChapterBlock(
                  closed.current_title,
                  list.reverse(closed.finalized_paragraphs),
                ),
                ..closed.finalized
              ],
              current_title: None,
              finalized_paragraphs: [],
              current_paragraph: [],
              blanks_since_content: 0,
              saw_content_in_chapter: False,
            )
          pushed
        }
        False ->
          case state.blanks_since_content {
            0 -> state
            _ -> close_current_paragraph(state)
          }
      }
      ChapterState(
        ..staged,
        current_paragraph: [text, ..staged.current_paragraph],
        blanks_since_content: 0,
        saw_content_in_chapter: True,
      )
    }
  }
}

fn close_current_paragraph(state: ChapterState) -> ChapterState {
  case state.current_paragraph {
    [] -> state
    lines -> {
      let paragraph_lines = list.reverse(lines)
      ChapterState(
        ..state,
        finalized_paragraphs: [paragraph_lines, ..state.finalized_paragraphs],
        current_paragraph: [],
      )
    }
  }
}

fn close_current_chapter(state: ChapterState) -> ChapterState {
  // Push a final chapter if it has content or a title. The
  // title-only branch keeps the close-of-document rule symmetric with
  // the adjacent-heading handling in `fold_line`: a trailing heading
  // produces a titled-but-empty chapter rather than disappearing.
  let with_para_closed = close_current_paragraph(state)
  let has_title_only = case with_para_closed.current_title {
    Some(_) -> True
    None -> False
  }
  case with_para_closed.saw_content_in_chapter || has_title_only {
    False -> with_para_closed
    True ->
      ChapterState(
        ..with_para_closed,
        finalized: [
          ChapterBlock(
            with_para_closed.current_title,
            list.reverse(with_para_closed.finalized_paragraphs),
          ),
          ..with_para_closed.finalized
        ],
        current_title: None,
        finalized_paragraphs: [],
        saw_content_in_chapter: False,
      )
  }
}

// ---------------------------------------------------------------------------
// Chapter / paragraph / sentence / word construction
// ---------------------------------------------------------------------------
//
// Global indices are assigned on first emit by threading two counters —
// `word_counter` and `sentence_counter` — through the recursive build.
// The earlier implementation stamped `global_index: 0` placeholders into
// the records and patched them afterwards, which left an invalid zero
// reachable to any caller who skipped the patching pass. Threading the
// counters removes that failure mode entirely.

fn build_chapters(blocks: List(ChapterBlock)) -> List(Chapter) {
  let initial = #(0, 0, 0, [])
  let #(_, _, _, chapters_rev) =
    list.fold(blocks, initial, fn(acc, block) {
      let #(chapter_index, word_counter, sentence_counter, chapters_acc) = acc
      let #(next_word, next_sentence, paragraphs) =
        build_paragraphs(block.paragraphs, word_counter, sentence_counter)
      let chapter =
        Chapter(
          index: chapter_index,
          title: block.title,
          paragraphs: paragraphs,
        )
      #(chapter_index + 1, next_word, next_sentence, [chapter, ..chapters_acc])
    })
  list.reverse(chapters_rev)
}

fn build_paragraphs(
  paragraph_lines_list: List(List(String)),
  word_counter: Int,
  sentence_counter: Int,
) -> #(Int, Int, List(Paragraph)) {
  let initial = #(0, word_counter, sentence_counter, [])
  let #(_, final_word, final_sentence, paragraphs_rev) =
    list.fold(paragraph_lines_list, initial, fn(acc, lines) {
      let #(idx, word_in, sentence_in, paragraphs_acc) = acc
      let #(word_out, sentence_out, paragraph) =
        build_paragraph(lines, idx, word_in, sentence_in)
      #(idx + 1, word_out, sentence_out, [paragraph, ..paragraphs_acc])
    })
  #(final_word, final_sentence, list.reverse(paragraphs_rev))
}

fn build_paragraph(
  lines: List(String),
  index: Int,
  word_counter: Int,
  sentence_counter: Int,
) -> #(Int, Int, Paragraph) {
  let joined = string.trim(join_lines(lines))
  let sentence_texts = split_sentences(joined)
  let #(next_word, next_sentence, sentences) =
    build_sentences(sentence_texts, word_counter, sentence_counter)
  #(next_word, next_sentence, Paragraph(index: index, sentences: sentences))
}

fn build_sentences(
  sentence_texts: List(String),
  word_counter: Int,
  sentence_counter: Int,
) -> #(Int, Int, List(Sentence)) {
  let initial = #(0, word_counter, sentence_counter, [])
  let #(_, final_word, final_sentence, sentences_rev) =
    list.fold(sentence_texts, initial, fn(acc, text) {
      let #(idx, word_in, sentence_global, sentences_acc) = acc
      let #(word_out, sentence) =
        build_sentence(text, idx, sentence_global, word_in)
      #(idx + 1, word_out, sentence_global + 1, [sentence, ..sentences_acc])
    })
  #(final_word, final_sentence, list.reverse(sentences_rev))
}

fn build_sentence(
  text: String,
  index: Int,
  global_index: Int,
  word_counter: Int,
) -> #(Int, Sentence) {
  let word_texts = split_words(text)
  let #(_, next_word, words_rev) =
    list.fold(word_texts, #(0, word_counter, []), fn(acc, word_text) {
      let #(idx, word_global, words_acc) = acc
      let word = Word(index: idx, global_index: word_global, text: word_text)
      #(idx + 1, word_global + 1, [word, ..words_acc])
    })
  let words = list.reverse(words_rev)
  #(next_word, Sentence(index: index, global_index: global_index, words: words))
}

fn join_lines(lines: List(String)) -> String {
  lines
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" })
  |> string.join(" ")
}

// ---------------------------------------------------------------------------
// Sentence splitting
// ---------------------------------------------------------------------------

const abbreviations = [
  "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "rev", "gen", "sgt", "cpl",
  "lt", "col", "maj", "capt", "cmdr", "adm", "gov", "pres", "sen", "rep", "u.s",
  "u.s.a", "u.k", "u.n", "a.m", "p.m", "e.g", "i.e", "vs", "etc", "al", "approx",
  "dept", "est", "inc", "govt", "assn", "bros", "corp",
]

fn is_abbreviation(word: String) -> Bool {
  list.contains(abbreviations, string.lowercase(word))
}

fn split_sentences(text: String) -> List(String) {
  let trimmed = string.trim(text)
  case trimmed {
    "" -> []
    _ -> {
      let graphemes = string.to_graphemes(trimmed)
      walk_sentences(graphemes, [], [], [])
      |> list.reverse
    }
  }
}

type BoundaryCheck {
  Boundary(consumed_extra: List(String), remaining: List(String))
  NotBoundary
}

fn walk_sentences(
  graphemes: List(String),
  sent_rev: List(String),
  word_rev: List(String),
  done_rev: List(String),
) -> List(String) {
  case graphemes {
    [] -> push_trimmed(sent_rev, done_rev)

    [".", ".", ..rest] -> {
      let #(extra, after) = consume_extra_dots(rest, 0)
      let dot_run = list.repeat(".", 2 + extra)
      let sent2 = prepend_reverse(dot_run, sent_rev)
      let word2 = prepend_reverse(dot_run, word_rev)
      walk_sentences(after, sent2, word2, done_rev)
    }

    [".", ..rest] -> {
      let word_str = word_rev |> list.reverse |> string.concat
      case is_abbreviation(word_str) {
        True ->
          walk_sentences(rest, [".", ..sent_rev], [".", ..word_rev], done_rev)
        False ->
          case check_sentence_boundary(rest) {
            Boundary(consumed_extra, after_boundary) -> {
              let sent_with_punct =
                prepend_reverse(consumed_extra, [".", ..sent_rev])
              let done2 = push_trimmed(sent_with_punct, done_rev)
              walk_sentences(after_boundary, [], [], done2)
            }
            NotBoundary ->
              walk_sentences(
                rest,
                [".", ..sent_rev],
                [".", ..word_rev],
                done_rev,
              )
          }
      }
    }

    ["!", ..rest] -> handle_terminator("!", rest, sent_rev, word_rev, done_rev)
    ["?", ..rest] -> handle_terminator("?", rest, sent_rev, word_rev, done_rev)

    [g, ..rest] ->
      case is_whitespace(g) {
        True -> walk_sentences(rest, [g, ..sent_rev], [], done_rev)
        False ->
          walk_sentences(rest, [g, ..sent_rev], [g, ..word_rev], done_rev)
      }
  }
}

fn handle_terminator(
  punct: String,
  rest: List(String),
  sent_rev: List(String),
  word_rev: List(String),
  done_rev: List(String),
) -> List(String) {
  case check_sentence_boundary(rest) {
    Boundary(consumed_extra, after_boundary) -> {
      let sent_with_punct = prepend_reverse(consumed_extra, [punct, ..sent_rev])
      let done2 = push_trimmed(sent_with_punct, done_rev)
      walk_sentences(after_boundary, [], [], done2)
    }
    NotBoundary ->
      walk_sentences(rest, [punct, ..sent_rev], [punct, ..word_rev], done_rev)
  }
}

fn consume_extra_dots(
  graphemes: List(String),
  acc: Int,
) -> #(Int, List(String)) {
  case graphemes {
    [".", ..rest] -> consume_extra_dots(rest, acc + 1)
    _ -> #(acc, graphemes)
  }
}

fn check_sentence_boundary(graphemes: List(String)) -> BoundaryCheck {
  case graphemes {
    [q, next, ..rest] ->
      case is_closing_quote(q), is_whitespace(next), peek_uppercase(rest) {
        True, True, True -> Boundary([q], [next, ..rest])
        _, _, _ ->
          case is_whitespace(q), peek_uppercase([next, ..rest]) {
            True, True -> Boundary([], graphemes)
            _, _ -> NotBoundary
          }
      }
    _ -> NotBoundary
  }
}

fn peek_uppercase(graphemes: List(String)) -> Bool {
  case graphemes {
    [g, ..] -> is_uppercase_letter(g)
    [] -> False
  }
}

fn is_closing_quote(g: String) -> Bool {
  case g {
    "\"" | "'" | "”" | "’" -> True
    _ -> False
  }
}

fn is_whitespace(g: String) -> Bool {
  case g {
    " " | "\t" | "\n" | "\r" -> True
    _ -> False
  }
}

fn is_uppercase_letter(g: String) -> Bool {
  case g {
    "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z" -> True
    _ -> string.lowercase(g) != g && string.uppercase(g) == g
  }
}

fn prepend_reverse(extra: List(String), acc: List(String)) -> List(String) {
  list.fold(extra, acc, fn(a, item) { [item, ..a] })
}

fn push_trimmed(sent_rev: List(String), done: List(String)) -> List(String) {
  let s = sent_rev |> list.reverse |> string.concat |> string.trim
  case s {
    "" -> done
    _ -> [s, ..done]
  }
}

// ---------------------------------------------------------------------------
// Word splitting
// ---------------------------------------------------------------------------

fn split_words(sentence: String) -> List(String) {
  sentence
  |> string.replace("\t", " ")
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
  |> string.split(" ")
  |> list.map(string.trim)
  |> list.filter(fn(word) { word != "" })
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

/// Encode a `SegmentedText` to a `json.Json` value. The shape mirrors
/// the structured types literally — chapters carry their title as a
/// nullable string and every nested level is an object with its index
/// fields and a list of children.
pub fn to_json(segmented: SegmentedText) -> json.Json {
  json.object([#("chapters", json.array(segmented.chapters, chapter_to_json))])
}

fn chapter_to_json(chapter: Chapter) -> json.Json {
  json.object([
    #("index", json.int(chapter.index)),
    #("title", json.nullable(chapter.title, json.string)),
    #("paragraphs", json.array(chapter.paragraphs, paragraph_to_json)),
  ])
}

fn paragraph_to_json(paragraph: Paragraph) -> json.Json {
  json.object([
    #("index", json.int(paragraph.index)),
    #("sentences", json.array(paragraph.sentences, sentence_to_json)),
  ])
}

fn sentence_to_json(sentence: Sentence) -> json.Json {
  json.object([
    #("index", json.int(sentence.index)),
    #("global_index", json.int(sentence.global_index)),
    #("words", json.array(sentence.words, word_to_json)),
  ])
}

fn word_to_json(word: Word) -> json.Json {
  json.object([
    #("index", json.int(word.index)),
    #("global_index", json.int(word.global_index)),
    #("text", json.string(word.text)),
  ])
}

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

/// Decoder for a JSON-encoded `SegmentedText`. Pairs with
/// `to_json` for a faithful round trip on both Erlang and JavaScript
/// targets.
pub fn decoder() -> decode.Decoder(SegmentedText) {
  use chapters <- decode.field("chapters", decode.list(chapter_decoder()))
  decode.success(SegmentedText(chapters: chapters))
}

fn chapter_decoder() -> decode.Decoder(Chapter) {
  use index <- decode.field("index", decode.int)
  use title <- decode.field("title", decode.optional(decode.string))
  use paragraphs <- decode.field("paragraphs", decode.list(paragraph_decoder()))
  decode.success(Chapter(index: index, title: title, paragraphs: paragraphs))
}

fn paragraph_decoder() -> decode.Decoder(Paragraph) {
  use index <- decode.field("index", decode.int)
  use sentences <- decode.field("sentences", decode.list(sentence_decoder()))
  decode.success(Paragraph(index: index, sentences: sentences))
}

fn sentence_decoder() -> decode.Decoder(Sentence) {
  use index <- decode.field("index", decode.int)
  use global_index <- decode.field("global_index", decode.int)
  use words <- decode.field("words", decode.list(word_decoder()))
  decode.success(Sentence(
    index: index,
    global_index: global_index,
    words: words,
  ))
}

fn word_decoder() -> decode.Decoder(Word) {
  use index <- decode.field("index", decode.int)
  use global_index <- decode.field("global_index", decode.int)
  use text <- decode.field("text", decode.string)
  decode.success(Word(index: index, global_index: global_index, text: text))
}
