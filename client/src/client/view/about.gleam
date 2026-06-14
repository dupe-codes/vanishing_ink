//// About view: a static explainer for Vanishing Ink — what the app is
//// and a walk through its features. Reached from the library appbar's
//// "About" affordance (`GoToAbout`) and returned from via the same
//// `GoToLibrary` the reader uses.
////
//// Structurally this mirrors `view/library`: a fixed appbar chrome row
//// (here: a back glyph + the page title) over a flex-grow scroll
//// container holding the prose body. The page carries no model-derived
//// state — every word is static copy — so `view` takes the `Model`
//// only to satisfy the uniform `Model -> Element(Msg)` shape the
//// top-level dispatcher hands every view; it reads nothing off it.
////
//// The copy is deliberately grounded in what the code actually does
//// (the two reading modes, Jump Ahead's preview/lock-in flow, the
//// random-deletion granularity/intensity axes, the once-per-book full
//// sweep). Overstating the feature set here would be the one place a
//// reader goes to *learn* the app, so the claims stay honest to the
//// reducer.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

import client/msg.{type Msg, GoToLibrary}
import client/state.{type Model}

/// Render the About view: appbar (back + title) over a scrollable
/// body of explainer sections. Takes the `Model` for shape-uniformity
/// with the other top-level views but reads nothing from it — the page
/// is fully static.
pub fn view(_model: Model) -> Element(Msg) {
  html.div([attribute.class("view-about")], [
    view_about_appbar(),
    html.div([attribute.class("about-scroll")], [view_about_body()]),
  ])
}

/// Appbar chrome: a back glyph on the left (dispatching `GoToLibrary`,
/// the shared return path) and the page title centred. Reuses the
/// library appbar's structural classes so the chrome reads identically
/// across views; the back button reuses `btn-icon` like the reader
/// header and library actions do.
fn view_about_appbar() -> Element(Msg) {
  html.div([attribute.class("lib-appbar")], [
    html.div([attribute.class("lib-appbar-inner about-appbar-inner")], [
      html.button(
        [
          attribute.class("btn-icon"),
          attribute.aria_label("Back to library"),
          attribute.type_("button"),
          event.on_click(GoToLibrary),
        ],
        [html.text("←")],
      ),
      html.div([attribute.class("about-appbar-title")], [html.text("About")]),
    ]),
  ])
}

/// The scrollable prose body. Lead block (wordmark + tagline + the
/// "why permanence" framing) followed by one section per feature
/// cluster, closing with the project note. Each section is a
/// `section-label` header (reusing the library's uppercase label
/// treatment) over body copy.
fn view_about_body() -> Element(Msg) {
  html.div([attribute.class("about-body")], [
    view_lead(),
    view_section("Reading is permanent", [
      paragraph(
        "Every word you read disappears, and there is no undo — not as a "
          <> "per-mode warning but as a system-wide rule. That is the whole "
          <> "point. Vanishing Ink is built for OCD ERP (Exposure Response "
          <> "Prevention): re-reading is the compulsive safety behaviour, so "
          <> "the app makes going back physically impossible. You read "
          <> "forward, the text vanishes behind you, and the urge to check "
          <> "what you just read has nothing to grab onto.",
      ),
    ]),
    view_section("Two ways to read", [
      paragraph(
        "Manual mode puts the erasing in your hands: tap (or click) a "
          <> "sentence once you have finished it and it fades away. On "
          <> "desktop, vim-style keys move the cursor sentence by sentence "
          <> "and paragraph by paragraph, and erase-and-advance in one "
          <> "keystroke.",
      ),
      paragraph(
        "Real-time mode hands the pace to a ghost-fade engine: words fade "
          <> "on their own at a words-per-minute speed you set, with a beat "
          <> "of pause between paragraphs. Play and pause whenever you need "
          <> "to — but what has already faded stays gone.",
      ),
    ]),
    view_section("Jump Ahead", [
      paragraph(
        "Navigation is forward-only, but you are never stuck. Jump Ahead "
          <> "lets you skip to a later chapter or page, or search the text "
          <> "ahead of you for a phrase. You get a preview of the target "
          <> "first: lock it in and every page you skipped vanishes in one "
          <> "go, or back out and stay where you were.",
      ),
    ]),
    view_section("Random destructive deletion", [
      paragraph(
        "For a sharper exposure, the app can vanish part of the text "
          <> "before you ever reach it. A page-per-page toggle thins each "
          <> "page as it loads, and a one-shot full sweep takes a bite out "
          <> "of the entire book at once — available once per book, ever.",
      ),
      paragraph(
        "Tune what disappears: granularity picks the unit (a word, a "
          <> "phrase, or a whole sentence) and intensity sets how much goes "
          <> "(low, medium, or high). The deletion is deterministic per "
          <> "book, so the same book always vanishes the same way.",
      ),
    ]),
    view_section("Your library", [
      paragraph(
        "Paste in your own text to build a library of books. Each book "
          <> "keeps its own reading stats and sessions — words read, words "
          <> "skipped, pages turned, time spent, and how your reading speed "
          <> "is trending. Your position is saved as you go, so closing the "
          <> "tab and coming back lands you exactly where you left off. "
          <> "Reader settings (speed, spacing, dark mode, and more) live a "
          <> "tap away.",
      ),
    ]),
    view_closing_note(),
  ])
}

/// Lead block: the wordmark (reusing the library appbar's dot +
/// serif wordmark treatment) over the one-line tagline.
fn view_lead() -> Element(Msg) {
  html.div([attribute.class("about-lead")], [
    html.div([attribute.class("app-wordmark about-wordmark")], [
      html.div(
        [
          attribute.class("wordmark-dot"),
          attribute.attribute("aria-hidden", "true"),
        ],
        [],
      ),
      html.span([], [html.text("Vanishing Ink")]),
    ]),
    html.div([attribute.class("about-tagline")], [
      html.text("A mobile-first eReader where the text disappears as you read."),
    ]),
  ])
}

/// Closing project note — small print on the why-it-exists. Distinct
/// muted treatment so it reads as a footer rather than another feature
/// section.
fn view_closing_note() -> Element(Msg) {
  html.div([attribute.class("about-note")], [
    html.text(
      "Vanishing Ink is a personal project, built end to end in Gleam as a "
      <> "way to learn the language.",
    ),
  ])
}

/// One titled section: a `section-label` header over its body
/// elements. Reuses the library's uppercase label class so the About
/// page speaks the same visual vocabulary as the rest of the chrome.
fn view_section(label: String, body: List(Element(Msg))) -> Element(Msg) {
  html.div([attribute.class("about-section")], [
    html.div([attribute.class("section-label")], [html.text(label)]),
    ..body
  ])
}

/// A single body paragraph in the reading-serif treatment the prose
/// sections share.
fn paragraph(content: String) -> Element(Msg) {
  html.p([attribute.class("about-paragraph")], [html.text(content)])
}
