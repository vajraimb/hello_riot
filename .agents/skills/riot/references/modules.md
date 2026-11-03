# Module system and dependency boundaries

Use this reference when a build fails because a module is unavailable, when you
are changing package dependencies, or when source files cross package or target
boundaries.

## Mental model

Riot plans builds from a module graph. Each source file may depend on:

- modules from the same package
- public top-level modules from direct dependencies
- regular dependencies plus dev-dependencies when planning test or benchmark
  targets

Riot does not expose transitive dependencies. If package `app` depends on
`std`, and `std` depends on `kernel`, `app` may use `Std` but may not use
`Kernel` unless `app` declares `kernel` as a direct dependency. Prefer the
public API of the direct dependency when that is the intended abstraction.

## Direct dependency examples

Allowed:

```ocaml
let path = Std.Path.v "riot.toml"
```

Not allowed when the package only depends on `std`:

```ocaml
let path = Kernel.Path.v "riot.toml"
```

Allowed for tests when `std` is in `[dependencies]`:

```ocaml
let test_path = Std.Path.v "fixtures/input.txt"
```

Dev-dependencies add extra modules for test and benchmark planning, but they do
not replace regular dependencies. Tests inherit normal package dependencies and
can also use modules from `[dev-dependencies]`.

## Public package modules

Use the top-level module exposed by the dependency package. For example, a
package that depends on `serde-json` should normally reach JSON APIs through
`Serde_json`. It should not import modules from packages that `serde-json`
happens to depend on unless those packages are also direct dependencies.

If a package should expose a helper from one of its dependencies, add that
helper to the package's public module instead of having downstream packages
reach through to the transitive dependency.

## Package-local modules

Modules in the same package can depend on each other directly. Keep reusable
code in package library modules instead of in binary, test, or benchmark
entrypoints.

When a target needs shared code from the package, import it through the package
library's public module. If the shared code only lives in another target
entrypoint, move it into a library or helper module first.

## Fixing module availability errors

When Riot reports that a module is not available:

1. Check whether the source is importing a transitive dependency directly.
2. Prefer using the direct dependency's public module if it exports the API.
3. Add a direct dependency only when the package really owns that dependency.
4. For tests or benchmarks, put test-only packages in `[dev-dependencies]`.
5. Move target-shared code into the package library rather than importing one
   target entrypoint from another.

Do not work around these errors by guessing build paths or manually invoking the
compiler. The module graph is Riot's source of truth for what the package is
allowed to use.
