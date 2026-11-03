# Benchmarking

Use this reference when the task involves writing benchmarks, running
`riot bench`, recording benchmark history, or comparing performance over time.

## Writing benchmarks

Use `Std.Bench` for benchmark suites. Keep each benchmark body focused on the
operation being measured, and prepare large fixtures outside the measured
function when possible.

```ocaml
open Std

let bench_push () =
  let values = Collections.Vector.create () in
  Collections.Vector.push values 42

let benchmarks = Bench.[
  case "vector push" bench_push;
  with_config
    ~config:{ iterations = 1_000; warmup = 50 }
    "vector push configured"
    bench_push;
]

let main ~args =
  Bench.Cli.main ~name:"vector_bench" ~benchmarks ~args

let () = Runtime.run ~main ~args:Env.args ()
```

Use comparison benchmarks when several implementations answer the same question:

```ocaml
let benchmarks = Bench.[
  compare_with_config
    ~config:{ iterations = 100; warmup = 10 }
    "lookup"
    [
      make_case "HashMap" bench_hashmap_lookup;
      make_case "Vector scan" bench_vector_scan;
    ];
]
```

## Running benchmarks

Start narrow and use package filters when possible:

```sh
riot bench
riot bench -p my-package
riot bench -p my-package -f lookup
riot bench --list
```

Without `-p`, a filter shaped like `package:suite` narrows suite discovery:

```sh
riot bench -f my-package:vector_bench
```

## Iterations and warmup

Benchmark cases can set their own `iterations` and `warmup` counts. CLI flags
override those counts for the matched run:

```sh
riot bench -p my-package -f lookup --iterations 200 --warmup 20
```

Use warmup to let caches, JIT-like runtime paths, and one-time setup noise settle
before measurement. Increase iterations when measurements are too noisy or when
comparing small operations.

## Recording and comparing history

Benchmark history is opt-in. Use `--record` when a run should be persisted under
`.riot/bench` for future comparison:

```sh
riot bench -p my-package -f lookup --record
```

Use `--compare <n>` to show up to `n` previous comparable suite runs alongside
the current result:

```sh
riot bench -p my-package -f lookup --compare 5
```

Comparable runs match by package, suite, profile, target, and benchmark case
name. Use stable benchmark names so history can line up across runs.

## JSON and direct suite debugging

Use `--json` for tooling:

```sh
riot bench -p my-package -f lookup --json
```

If you are debugging the generated benchmark binary directly, benchmark suites
typically expose:

- `list-benchmarks`
- `run-benchmarks [query]`

Most user tasks should still go through `riot bench` first so Riot can build the
workspace once and pass the right context to each suite.
