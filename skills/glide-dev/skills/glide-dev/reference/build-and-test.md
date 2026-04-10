# Build and Test

Use when setting up a development environment, running tests, or debugging build issues.

## Prerequisites

- Rust toolchain (rustup)
- Node.js 16+ (for Node.js wrapper)
- Python 3.9+ (for Python wrapper)
- Java 11+ (for Java wrapper)
- Go 1.21+ (for Go wrapper)
- Docker (for integration tests - cluster setup)
- protoc (protobuf compiler)

## Build

### Rust Core
```bash
cd glide-core
cargo build
cargo test
```

### Node.js
```bash
cd node
npm install
npm run build       # Builds Rust NAPI binding + TypeScript
npm run build:release  # Release build
npm test
```

### Python
```bash
cd python
pip install -e .    # Editable install
python -m pytest tests/
```

### Java
```bash
cd java
./gradlew build
./gradlew test
```

### Go
```bash
cd go
make build
make test
```

## Integration Tests

Integration tests require a running Valkey cluster. Use the utility scripts:

```bash
# Start a standalone Valkey instance
python utils/cluster_manager.py start --cluster-mode false

# Start a 3-primary + 3-replica cluster
python utils/cluster_manager.py start --cluster-mode true

# Run Node.js integration tests
cd node && npm run test:integration

# Stop cluster
python utils/cluster_manager.py stop
```

## Common Issues

- **NAPI build fails**: ensure `node-gyp` dependencies are installed (Python, C++ compiler)
- **PyO3 build fails**: ensure `maturin` is installed (`pip install maturin`)
- **Protobuf mismatch**: regenerate with `protoc` if proto files changed
- **Socket permission errors**: Unix sockets created in temp dir, check permissions
