# hello_riot

A Riot workspace for OCaml development.

## Getting Started

### Building

Build all packages:
```bash
riot build
```


### Testing

Run tests:
```bash
riot test
```

### Containers

Verify the workspace in Docker:
```bash
docker build -t hello_riot .
```


### Continuous Integration

The generated `.github/workflows/ci.yml` runs `riot build` and `riot test` on
pushes and pull requests.

### Adding New Packages

Create a new library package:
```bash
riot new --lib ./packages/my-new-library
```

Create a new binary package:
```bash
riot new --bin ./packages/my-new-binary
```

Then add the new package path to `riot.toml` workspace members.

## Structure

- `packages/` - Workspace packages
- `riot.toml` - Workspace configuration
- `ocaml-toolchain.toml` - OCaml toolchain version
- `Dockerfile` - Container build template
- `.github/workflows/ci.yml` - GitHub Actions starter workflow

## 文档

- [Oasis 规格与初衷](docs/oasis-spec.md) — 为什么做、架构规格、接口、已知限制
- [规划与战报](docs/ai-portal-plan.md) — M0-M3 里程碑与 16.1~16.25 战报
