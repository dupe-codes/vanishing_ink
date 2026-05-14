%% Vanishing Ink time helpers. Wraps calendar:system_time_to_rfc3339/2 and
%% calendar:rfc3339_to_system_time/2 so the Gleam side can both stamp the
%% current wall-clock time and validate client-supplied timestamps without
%% binding to Erlang atoms from Gleam call sites.
-module(vanishing_ink_time_ffi).

-export([now_iso8601/0, parse_iso8601/1, today_iso8601_date/0, is_next_day/2]).

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
%% Wall-clock today as a YYYY-MM-DD UTC string. Used by the stats
%% handler so the streak computation can compare each session's day
%% prefix against "is this today or yesterday?". The streak math is
%% in shared/stats.gleam, so this helper only has to return the date
%% prefix — the comparator below answers consecutive-day questions.
today_iso8601_date() ->
    {Date, _Time} = calendar:universal_time(),
    {Y, M, D} = Date,
    erlang:list_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D])).

%% Is `B` the calendar day immediately after `A`? Both arguments are
%% YYYY-MM-DD UTC strings; an unparseable input returns `false` so a
%% malformed row in `reading_sessions` cannot wedge the streak count.
is_next_day(A, B) when is_binary(A), is_binary(B) ->
    case {parse_date(A), parse_date(B)} of
        {{ok, Da}, {ok, Db}} ->
            calendar:date_to_gregorian_days(Db)
                - calendar:date_to_gregorian_days(Da) =:= 1;
        _ -> false
    end;
is_next_day(_, _) ->
    false.

parse_date(Binary) ->
    case erlang:binary_to_list(Binary) of
        [Y1, Y2, Y3, Y4, $-, M1, M2, $-, D1, D2] ->
            try
                Year = erlang:list_to_integer([Y1, Y2, Y3, Y4]),
                Month = erlang:list_to_integer([M1, M2]),
                Day = erlang:list_to_integer([D1, D2]),
                case calendar:valid_date(Year, Month, Day) of
                    true -> {ok, {Year, Month, Day}};
                    false -> error
                end
            catch
                _:_ -> error
            end;
        _ -> error
    end.

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
