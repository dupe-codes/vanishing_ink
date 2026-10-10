-module(vanishing_ink_auth_ffi).
-export([derive_bounded/3, new_throttle/0, admit/1, now_seconds/0]).

derive(Password, Salt) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, 600000, 32).

new_throttle() ->
    Ref = atomics:new(2, [{signed, true}]),
    atomics:put(Ref, 1, erlang:monotonic_time(millisecond)),
    Ref.

derive_bounded(Password, Salt, Ref) ->
    case atomics:compare_exchange(Ref, 2, 0, 1) of
        ok ->
            try {ok, derive(Password, Salt)}
            after atomics:put(Ref, 2, 0)
            end;
        _ -> {error, nil}
    end.

admit(Ref) ->
    Now = erlang:monotonic_time(millisecond),
    Previous = atomics:get(Ref, 1),
    case Now >= Previous of
        true -> atomics:compare_exchange(Ref, 1, Previous, Now + 2000) =:= ok;
        false -> false
    end.

now_seconds() -> erlang:system_time(second).
