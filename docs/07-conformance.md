# Conformance against `xd/examples/`

Decision 9 of `xd/docs/10-lua-lifetime-decisions.md`: the conformance
suite is the contract. The programs in `xd/examples/` are run, transpiled,
under real Lua, and their output is compared with the `.expected` files.
Any example lua-lifetime cannot honour is a documented deviation here, not
a changed expectation in `xd`.

## The rule

An `xd` example is ported into `examples/` of this repository as
`NAME.lt` with `NAME.lt.expected`, under one of three headings:

1. **Ported unchanged.** The program uses no feature the decisions
   removed (the `all` and `any` constructors, the scope functions,
   nil-on-death, `remaining`) and pins no reachable death to a statement.
   Only the spelling changes: the scope function after `@` becomes
   `scope`, an `all` over `a` and `b` becomes `(a, b)`. The `.expected`
   file is `xd`'s, byte for byte. `defer f @ a` becomes `f !@ a`, and a bare `defer f` becomes `f !@ scope`.
2. **Rewritten around `collectgarbage`.** The program pins a death by
   `reachable` to a statement. The port inserts `collectgarbage("collect")`
   at that statement, and the `.expected` file is the one `xd` adopts for
   the rewritten example under its `/spec-change` pass (decision 9: both
   targets run the same file).
3. **Deviation.** The program depends on behaviour the decisions reverse
   in a way no rewrite preserves (a hook that decodes `remaining`,
   dependents destroyed before their anchor, a dead reference reading
   `nil`). The port shows the lua-lifetime behaviour, its `.expected` file
   differs from `xd`'s, and this page records what differs and which
   decision causes it.

Every ported example must pass under every interpreter the runner finds.
There is no expected-failure marker. The porting is task 008; this page
holds the headings and is filled in as each example is classified.

## Ported unchanged

| Example | Note |
| --- | --- |

## Rewritten around `collectgarbage`

| Example | Where the collect goes | Note |
| --- | --- | --- |

## Deviations

| Example | What differs | Decision |
| --- | --- | --- |

## Examples to classify (task 008)

`binding`, `block_exits`, `cache_drop`, `caller`, `cascade`, `compose`,
`connection`, `control_tree`, `coroutines`, `dead_cache`,
`dead_reference`, `defer`, `destroy_errors`, `explicit_destroy`,
`generation`, `hand_off`, `hooks`, `listeners`, `move`, `period`,
`pinned_parent`, `release_chain`, `scope_passing`, `shared_channel`,
`timers`, `uncaught_error`, `weak_tables`, `workers`.
