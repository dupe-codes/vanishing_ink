%% Vanishing Ink time helper. Wraps calendar:system_time_to_rfc3339/2 so
%% the Gleam side can ask for the current wall-clock time as an ISO 8601
%% UTC string without binding to Erlang atoms from Gleam call sites.
-module(vanishing_ink_time_ffi).

-export([now_iso8601/0]).

now_iso8601() ->
    Seconds = erlang:system_time(second),
    erlang:list_to_binary(
        calendar:system_time_to_rfc3339(Seconds, [{offset, "Z"}])
    ).
