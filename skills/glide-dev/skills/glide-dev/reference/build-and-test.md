# Build and Test

Use when setting up a development environment, running tests, or debugging build issues.

## Prerequisites

- Rust toolchain (rustup)
- Node.js 16+ (for Node.js wrapper)
- Python 3.9+ (for Python wrappers)
- Java 11+ (for Java wrapper)
- Go 1.21+ (for Go wrapper)
- Docker (for integration tests - cluster setup)
- protoc (protobuf compiler)

## Preferred: top-level `Makefile`

The repo root `Makefile` is the canonical way to build and test. It wires each language to its own toolchain.

```bash
make all          # java + python + node + go + all tests + lint
make java         # release build
make python       # python async + sync, release
make node         # release build
make go           # build

make java-test    # integration tests
make python-test
make node-test
make go-test

make java-lint    # spotlessApply
make python-lint
make node-lint
make go-lint
```

Tests that need a server use the `check-valkey-server` Make target which spins up a Valkey process.

## Raw per-stack equivalents

### Rust core

```bash
cd glide-core
cargo build --release
cargo test
cargo clippy
cargo fmt
cargo bench
```

### Node.js

```bash
cd node
npm install
npm run build:release
npm test
```

### Python (async + sync)

Python uses `python3 dev.py` as the canonical build/test/lint driver:

```bash
cd python
python3 dev.py build --mode release
python3 dev.py test
python3 dev.py lint
```

Raw pytest against the installed package also works once `dev.py build` has produced the wheels.

### Java

```bash
cd java
./gradlew :client:buildAllRelease
./gradlew :integTest:test
./gradlew :spotlessApply
```

### Go

```bash
cd go
make build
make test
make lint
```

## Integration tests - cluster setup

`utils/cluster_manager.py` manages the test topology:

```bash
# Standalone Valkey
python3 utils/cluster_manager.py start --cluster-mode false

# 3 primaries + 3 replicas
python3 utils/cluster_manager.py start --cluster-mode true

# Stop
python3 utils/cluster_manager.py stop
```

## Common issues

- **NAPI build fails**: ensure `node-gyp` deps are installed (Python, C++ toolchain)
- **PyO3 build fails**: `maturin` required - `pip install maturin` or let `dev.py` manage the `.env/` virtualenv
- **Protobuf mismatch**: proto files are regenerated at build time; force rebuild if out of sync
- **Socket permission errors**: UDS sockets created in temp dir - name includes `{pid}-{uuid}` to avoid collision. Check temp dir permissions and existing stale socket files if reuse is suspected.
- **Cross-language change**: if you modify `glide-core/` or `ffi/`, rebuild AND test **every** language binding - the core is shared across all wrappers and both FFI modes (UDS and direct FFI).
