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
  raw
  |> string.split("\n")
  |> list.map(classify_line)
  |> build_chapter_blocks
  |> list.index_map(build_chapter)
  |> assign_global_indices
  |> SegmentedText
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
  let lower = string.lowercase(line)
  case string.starts_with(lower, "chapter ") {
    False -> False
    True -> {
      let rest = string.trim_start(string.drop_start(lower, 8))
      let token = take_chapter_token(string.to_graphemes(rest), [])
      case token {
        [] -> False
        _ -> is_all_digits(token) || is_all_roman(token)
      }
    }
  }
}

fn take_chapter_token(
  graphemes: List(String),
  acc: List(String),
) -> List(String) {
  case graphemes {
    [] -> list.reverse(acc)
    [g, ..rest] ->
      case is_alphanumeric(g) {
        True -> take_chapter_token(rest, [g, ..acc])
        False -> list.reverse(acc)
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

fn is_all_roman(token: List(String)) -> Bool {
  list.all(token, fn(g) {
    case g {
      "i" | "v" | "x" | "l" | "c" | "d" | "m" -> True
      _ -> False
    }
  })
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
      // A heading always starts a new chapter. If the current chapter
      // already has any content, close it and push it onto `finalized`;
      // otherwise just overwrite the (empty) chapter's title.
      let with_para_closed = close_current_paragraph(state)
      let next_finalized = case with_para_closed.saw_content_in_chapter {
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
  let with_para_closed = close_current_paragraph(state)
  case with_para_closed.saw_content_in_chapter {
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

fn build_chapter(block: ChapterBlock, index: Int) -> Chapter {
  let paragraphs =
    block.paragraphs
    |> list.index_map(build_paragraph)
  Chapter(index: index, title: block.title, paragraphs: paragraphs)
}

fn build_paragraph(lines: List(String), index: Int) -> Paragraph {
  let joined = string.trim(join_lines(lines))
  let sentences =
    joined
    |> split_sentences
    |> list.index_map(build_sentence_skeleton)
  Paragraph(index: index, sentences: sentences)
}

fn join_lines(lines: List(String)) -> String {
  lines
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" })
  |> string.join(" ")
}

fn build_sentence_skeleton(text: String, index: Int) -> Sentence {
  let words =
    text
    |> split_words
    |> list.index_map(fn(word_text, word_index) {
      Word(index: word_index, global_index: 0, text: word_text)
    })
  Sentence(index: index, global_index: 0, words: words)
}

// ---------------------------------------------------------------------------
// Global index assignment
// ---------------------------------------------------------------------------

fn assign_global_indices(chapters: List(Chapter)) -> List(Chapter) {
  let #(_, _, reversed) =
    list.fold(chapters, #(0, 0, []), fn(acc, chapter) {
      let #(word_counter, sentence_counter, chapters_acc) = acc
      let #(new_word_counter, new_sentence_counter, paragraphs_rev) =
        list.fold(
          chapter.paragraphs,
          #(word_counter, sentence_counter, []),
          fn(p_acc, paragraph) {
            let #(p_word_counter, p_sentence_counter, paragraphs_acc) = p_acc
            let #(s_word_counter, s_sentence_counter, sentences_rev) =
              list.fold(
                paragraph.sentences,
                #(p_word_counter, p_sentence_counter, []),
                fn(s_acc, sentence) {
                  let #(w_word_counter, w_sentence_counter, sentences_acc) =
                    s_acc
                  let #(next_word_counter, words_rev) =
                    list.fold(
                      sentence.words,
                      #(w_word_counter, []),
                      fn(word_acc, word) {
                        let #(word_counter_now, words_so_far) = word_acc
                        let stamped =
                          Word(..word, global_index: word_counter_now)
                        #(word_counter_now + 1, [stamped, ..words_so_far])
                      },
                    )
                  let words = list.reverse(words_rev)
                  let stamped_sentence =
                    Sentence(
                      ..sentence,
                      global_index: w_sentence_counter,
                      words: words,
                    )
                  #(next_word_counter, w_sentence_counter + 1, [
                    stamped_sentence,
                    ..sentences_acc
                  ])
                },
              )
            let sentences = list.reverse(sentences_rev)
            let stamped_paragraph = Paragraph(..paragraph, sentences: sentences)
            #(s_word_counter, s_sentence_counter, [
              stamped_paragraph,
              ..paragraphs_acc
            ])
          },
        )
      let paragraphs = list.reverse(paragraphs_rev)
      let stamped_chapter = Chapter(..chapter, paragraphs: paragraphs)
      #(new_word_counter, new_sentence_counter, [
        stamped_chapter,
        ..chapters_acc
      ])
    })
  list.reverse(reversed)
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
          case
            is_whitespace(q),
            is_uppercase_letter_after_whitespace([next, ..rest])
          {
            True, True -> Boundary([], graphemes)
            _, _ -> NotBoundary
          }
      }
    [g] ->
      case is_whitespace(g) {
        True -> NotBoundary
        False -> NotBoundary
      }
    [] -> NotBoundary
  }
}

fn is_uppercase_letter_after_whitespace(graphemes: List(String)) -> Bool {
  case graphemes {
    [g, ..] -> is_uppercase_letter(g)
    [] -> False
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
