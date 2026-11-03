# Testing

Use this reference when the task involves writing tests, running `riot test`,
reviewing snapshots, suite selection, or repository-shared test policy.

## Mental model

At the top level, `riot test` is a Riot command that:

1. build the needed packages once
2. discover suite binaries
3. run those suite binaries through their machine-readable contracts
4. aggregate the results

That means the right user workflow is usually:

- narrow by package or suite first
- then narrow by query if needed
- use `--json` when tooling needs structured results

## Writing unit tests

Use `Std.Test` for normal package tests. Keep unit tests focused on one behavior
and return `Ok ()` or `Error msg`.

```ocaml
open Std

let test_adds_numbers = fun _ctx ->
  Test.assert_equal ~expected:4 ~actual:(2 + 2);
  Ok ()

let tests = Test.[
  case "adds numbers" test_adds_numbers;
]

let main ~args =
  Test.Cli.main ~name:"math_tests" ~tests ~args ()

let () = Runtime.run ~main ~args:Env.args ()
```

Use `Test.case ~size:Test.Large` for slow or integration-heavy tests. Use
`Test.case ~reliability:Test.(Flaky { retry_attempts = 2 })` only when the
behavior is intentionally flaky and retry policy is part of the contract.

## Writing e2e tests

Use e2e tests for black-box behavior that needs real files, commands, or a
temporary workspace. Mark them large by default:

```ocaml
let test_cli_smoke = fun _ctx ->
  (* Create a temp workspace, run the command, then assert on status, files, and
     key output fragments. *)
  Ok ()

let tests = Test.[
  case ~size:Large "cli smoke" test_cli_smoke;
]
```

Prefer semantic assertions over whole-output snapshots: check exit status,
important output fragments, created files, and follow-up command behavior.

## Snapshot tests

Use snapshots when the output is intentionally large or text-shaped, such as
formatted code, diagnostics, generated files, or serialized JSON.

```ocaml
let test_rendered_output = fun ctx ->
  Test.Snapshot.assert_text ~ctx ~actual:(render ())
```

Use inline snapshots for short expected values that should stay in the test
file:

```ocaml
let test_inline_output = fun ctx ->
  Test.Snapshot.assert_inline_text
    ~ctx
    ~actual:"hello\n"
    ~expected:"hello\n"
```

External snapshots write pending `*.expected.new` files when output changes.
Review them before approving:

```sh
riot snapshots review
riot snapshots approve
riot snapshots reject
```

## Test selection

These are different selectors:

- `riot test`
  Runs the default test set.
- `riot test -p <package>`
  Runs tests from one package. Repeat `-p` to select multiple packages.
- `riot test -f <query>`
  Filters suites and cases by substring.
- `riot test -p <package> -f <query>`
  Filters within the selected package or packages.
- `riot test -f <package:suite>`
  Narrows suite discovery when no `-p` filter is present.
- `riot test --list`
  Lists matched suites and cases without running them.
- `riot test --small`
  Runs only cases marked small.
- `riot test --large`
  Runs only cases marked large.
- `riot test --flaky`
  Runs only cases marked flaky.
- `riot test --release`
  Builds and runs tests with the release profile.

Do not confuse package or suite selection with case-name selection.

## Shared test policy

Repository-shared test policy lives in `.riot/config.toml`:

```toml
[riot.test]
small_test_timeout = "500ms"
flaky_max_retries = 3
```

Use that file for repository-local policy. Do not put this policy in
`riot.toml`, and do not assume every user should store it in
`~/.riot/config.toml`.

## Advanced note: suite binaries

If you are debugging the generated suite binary directly, Riot test suites
typically expose subcommands such as:

- `list-tests`
- `run-tests [query]`

Most user tasks should still go through `riot test` first.

## When to use `--json`

Use `--json` when:

- you need to feed results into tooling
- you need reliable machine-readable timing or status output
- scraping human output would be fragile

Examples:

```sh
riot test --json
riot test -p my-package -f parser --json
```
