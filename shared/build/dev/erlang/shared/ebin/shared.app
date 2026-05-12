{application, shared, [
    {vsn, "0.1.0"},
    {applications, [gleam_json,
                    gleam_stdlib,
                    gleeunit]},
    {description, "Shared types and serialisation used by the Vanishing Ink server and client. Compiles to both Erlang and JavaScript targets — keep dependencies target-agnostic."},
    {modules, [shared,
               shared@@main,
               shared_test]},
    {registered, []}
]}.
