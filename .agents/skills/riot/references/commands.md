# Command patterns

Use this reference when you know the task and need the right Riot command
shape.

## Scaffold

Create a new workspace:

```sh
riot init
```

Create a new package inside an existing workspace:

```sh
riot new packages/my-package
```

## Dependencies

Add a runtime dependency to the current package:

```sh
riot add std
```

Add to a specific manifest or scope:

```sh
riot add -p my-package serde-json
riot add --workspace std
riot add --dev propane
riot add --build codegen-tool
```

Remove a dependency from the current package:

```sh
riot rm std
```

Remove from a specific manifest or scope:

```sh
riot rm -p my-package serde-json
riot rm --workspace std
riot rm --dev propane
```

Refresh dependencies:

```sh
riot update
```

## Build and typecheck

Build the whole workspace:

```sh
riot build
```

Build one package:

```sh
riot build -p my-package
```

Build several packages:

```sh
riot build -p app -p worker
```

Compile development artifacts:

```sh
riot build --tests
riot build --examples
riot build --benches
riot build --all
```

Build for another target or all configured targets:

```sh
riot build -x linux
riot build -x aarch64-apple-darwin
riot build --all-targets
```

Use release profile or limit parallelism:

```sh
riot build --release
riot build -j 4
```

Typecheck the workspace or a package:

```sh
riot check
riot check -p my-package
riot check --json
riot check --explain TYP2001
```

When the task is narrow, prefer package-scoped commands before workspace-wide
ones.

## Run binaries

Run a local binary:

```sh
riot run my-binary
```

Disambiguate by package:

```sh
riot run -p my-package my-binary
```

List runnable binaries:

```sh
riot run --list
riot run --list --json
```

Forward args after `--`:

```sh
riot run -p my-package my-binary -- --port 8080
```

Riot can also run remote sources:

```sh
riot run leostera/create-riot-app
riot run --update leostera/create-riot-app
```

## Tests and benchmarks

Run all tests:

```sh
riot test
```

Filter by test-case name:

```sh
riot test -f parser
```

Narrow by package or repeat the package flag:

```sh
riot test -p my-package
riot test -p app -p worker
```

Filter within a package:

```sh
riot test -p my-package -f parser
```

Narrow by suite without a package flag:

```sh
riot test -f my-package:parser_tests
```

List matched suites and cases without running them:

```sh
riot test --list
riot test -p my-package -f parser --list
```

Run only small, large, or flaky cases:

```sh
riot test --small
riot test --large
riot test --flaky
```

Run benchmarks:

```sh
riot bench
riot bench -p my-package
riot bench -p my-package -f hashmap
riot bench --list
```

Benchmark run controls:

```sh
riot bench --iterations 100 --warmup 10
riot bench --record
riot bench --compare 5
```

Read [benchmarking.md](benchmarking.md) before recording or comparing benchmark
history.

## Formatting and fixes

Check formatting:

```sh
riot fmt --check
riot fmt --check --json
riot fmt --verify
```

Apply or inspect fixes:

```sh
riot fix --check .
riot fix --apply .
riot fix --list-rules
riot fix --list-diagnostics
```

## Docs, cleanup, and publishing

Generate docs:

```sh
riot doc -p my-package
riot doc --all
riot doc --release
riot doc --output docs
```

Clean build outputs:

```sh
riot clean
riot clean --force
```

Publish packages:

```sh
riot publish --dry-run
riot publish -p my-package
riot publish --workspace
riot publish --skip-check
```

## Machine-readable output

Use `--json` when a machine-readable stream is better than scraping human
output:

```sh
riot build --json
riot test --json
riot bench --json
riot fmt --check --json
riot fix --check --json .
riot doc --json
riot clean --json
riot info --json
```
