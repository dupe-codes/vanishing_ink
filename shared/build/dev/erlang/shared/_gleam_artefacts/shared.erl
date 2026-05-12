-module(shared).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/shared.gleam").
-export([book_id/1]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

?MODULEDOC(
    " Shared types and helpers used by both the Vanishing Ink server (BEAM)\n"
    " and client (JavaScript). Everything in this module must stay\n"
    " target-agnostic — no Erlang- or JS-only FFI, only pure Gleam and\n"
    " portable stdlib calls — so the same code can be linked into both\n"
    " builds via the local path dependency.\n"
).

-file("src/shared.gleam", 16).
?DOC(
    " Wrap a raw string as a `BookId`. Provided as a named constructor so\n"
    " call sites read intentionally even though the underlying type is a\n"
    " transparent alias.\n"
).
-spec book_id(binary()) -> binary().
book_id(Value) ->
    Value.
