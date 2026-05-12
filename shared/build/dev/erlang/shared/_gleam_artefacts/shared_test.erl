-module(shared_test).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "test/shared_test.gleam").
-export([main/0, book_id_round_trips_test/0]).

-file("test/shared_test.gleam", 4).
-spec main() -> nil.
main() ->
    gleeunit:main().

-file("test/shared_test.gleam", 8).
-spec book_id_round_trips_test() -> nil.
book_id_round_trips_test() ->
    Id = shared:book_id(<<"the-iliad"/utf8>>),
    _assert_subject = <<"the-iliad"/utf8>>,
    case Id =:= _assert_subject of
        true -> nil;
        false -> erlang:error(#{gleam_error => assert,
                message => <<"Assertion failed."/utf8>>,
                file => <<?FILEPATH/utf8>>,
                module => <<"shared_test"/utf8>>,
                function => <<"book_id_round_trips_test"/utf8>>,
                line => 11,
                kind => binary_operator,
                operator => '==',
                left => #{kind => expression,
                    value => Id,
                    start => 160,
                    'end' => 162
                    },
                right => #{kind => literal,
                    value => _assert_subject,
                    start => 166,
                    'end' => 177
                    },
                start => 153,
                'end' => 177,
                expression_start => 160})
    end.
