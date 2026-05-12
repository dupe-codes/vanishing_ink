%% Vanishing Ink time helpers. Wraps calendar:system_time_to_rfc3339/2 and
%% calendar:rfc3339_to_system_time/2 so the Gleam side can both stamp the
%% current wall-clock time and validate client-supplied timestamps without
%% binding to Erlang atoms from Gleam call sites.
-module(vanishing_ink_time_ffi).

-export([now_iso8601/0, parse_iso8601/1]).

now_iso8601() ->
    Seconds = erlang:system_time(second),
    erlang:list_to_binary(
        calendar:system_time_to_rfc3339(Seconds, [{offset, "Z"}])
    ).

%% Parse a client-supplied ISO 8601 / RFC 3339 timestamp and return a
%% canonical UTC representation `YYYY-MM-DDTHH:MM:SSZ`. Canonicalising
%% removes any timezone-offset, fractional-second, or lower-case-`t`
%% variation so the SQL-side lexicographic comparison stays a faithful
%% chronological ordering. Returns `{error, nil}` on any malformed input
%% — including the obvious wedge attempts like the literal `"ZZZZ"` —
%% so the router can refuse the write at the boundary.
parse_iso8601(Binary) when is_binary(Binary) ->
    try
        Seconds = calendar:rfc3339_to_system_time(
            erlang:binary_to_list(Binary),
            [{unit, second}]
        ),
        Canonical = erlang:list_to_binary(
            calendar:system_time_to_rfc3339(Seconds, [{offset, "Z"}])
        ),
        {ok, Canonical}
    catch
        _:_ -> {error, nil}
    end;
parse_iso8601(_) ->
    {error, nil}.
