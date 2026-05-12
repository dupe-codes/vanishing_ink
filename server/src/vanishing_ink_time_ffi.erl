%% Vanishing Ink time helpers. Wraps calendar:system_time_to_rfc3339/2 and
%% calendar:rfc3339_to_system_time/2 so the Gleam side can both stamp the
%% current wall-clock time and validate client-supplied timestamps without
%% binding to Erlang atoms from Gleam call sites.
-module(vanishing_ink_time_ffi).

-export([now_iso8601/0, parse_iso8601/1]).

%% Emits millisecond precision (`YYYY-MM-DDTHH:MM:SS.sssZ`) to match
%% `parse_iso8601/1`'s canonical form — both server-stamped and
%% client-canonicalised timestamps must share width and zero-padding
%% so the SQL-side lexicographic comparison stays a faithful
%% chronological ordering.
now_iso8601() ->
    Milliseconds = erlang:system_time(millisecond),
    erlang:list_to_binary(
        calendar:system_time_to_rfc3339(
            Milliseconds,
            [{offset, "Z"}, {unit, millisecond}]
        )
    ).

%% Parse a client-supplied ISO 8601 / RFC 3339 timestamp and return a
%% canonical UTC representation `YYYY-MM-DDTHH:MM:SS.sssZ` (millisecond
%% precision). Canonicalising removes any timezone-offset or
%% lower-case-`t` variation so the SQL-side lexicographic comparison
%% stays a faithful chronological ordering, while preserving
%% sub-second precision so two writes that differ only in milliseconds
%% remain distinguishable to a client expecting strict monotonicity of
%% `updated_at`. Returns `{error, nil}` on any malformed input —
%% including the obvious wedge attempts like the literal `"ZZZZ"` —
%% so the router can refuse the write at the boundary.
%%
%% Millisecond precision is the canonical width: every emitted string
%% has the same `.sss` suffix (zero-padded), so the lexicographic
%% comparison stays well-defined across inputs that supplied seconds,
%% milliseconds, or fractional seconds at any precision.
parse_iso8601(Binary) when is_binary(Binary) ->
    try
        Milliseconds = calendar:rfc3339_to_system_time(
            erlang:binary_to_list(Binary),
            [{unit, millisecond}]
        ),
        Canonical = erlang:list_to_binary(
            calendar:system_time_to_rfc3339(
                Milliseconds,
                [{offset, "Z"}, {unit, millisecond}]
            )
        ),
        {ok, Canonical}
    catch
        _:_ -> {error, nil}
    end;
parse_iso8601(_) ->
    {error, nil}.
