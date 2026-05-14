# foliate-js (vendored)

Parse-only snapshot of [foliate-js](https://github.com/johnfactotum/foliate-js)
used by the ePub-import feature. Vendored rather than installed via npm
because foliate-js does not publish releases — pinning to a specific
commit is the only durable approach.

## Pinned commit

`78914aef4466eb960965702401634c2cb348e9b1` (May 2026 snapshot from `main`).

## Files

- `epub.js` — EPUB parser. Exports the `EPUB` class which accepts a
  loader (`{ loadText, loadBlob, getSize, sha1 }`) and exposes
  `metadata`, `sections[*].createDocument()`, etc. once `init()`
  resolves.
- `epubcfi.js` — CFI parser. Imported by `epub.js`; not used directly
  here.
- `vendor/zip.js` — `@zip.js/zip.js` minified bundle, sourced from
  foliate-js's own `vendor/`. Provides the `ZipReader` / `BlobReader` /
  `TextWriter` / `BlobWriter` primitives `epub.js` needs to read entries
  out of the .epub container.
- `LICENSE` — MIT, John Factotum.

## Not vendored

The viewer/renderer modules (`view.js`, `paginator.js`, `reader.js`,
`overlayer.js`, …) are intentionally omitted — we only parse, never
render through foliate-js.
