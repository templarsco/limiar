# Contributing to Limiar

The active project is Limiar. Start with the root Cargo workspace and the
[development plan](docs/DEVELOPMENT-PLAN.md). The old PVGPU directories below
are historical prototype components, not the current build path.

## Current Development

Use the pinned Rust toolchain and keep the root `Cargo.lock` committed.

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --all-targets --locked
cargo build --release --locked
```

Do not publish raw `.limiar/` reports, VM images, serial numbers, instance paths,
or personal transcripts. Sanitized validation summaries must distinguish native
host tests from guest tests and document unknown/unsupported capabilities.
Never disable or dismount a device as part of a diagnostic command.

The initial CLI uses the existing MIT OR Apache-2.0 terms. Preserve dependency
notices. Proposals for different licenses need a separate review.

## Historical PVGPU Contribution Notes

The remainder documents the previous prototype and is not a list of current
Limiar prerequisites or priorities.

## Areas Where We Need Help

### High Priority
- **D3D11 Implementation** - Completing the command handlers in the Rust backend
- **WDDM Driver Development** - Kernel-mode and user-mode driver implementation
- **Testing** - Testing on various GPU hardware (NVIDIA, AMD, Intel)

### Medium Priority
- **QEMU Integration** - Polishing the QEMU device and upstream contribution
- **Performance Optimization** - Profiling and optimizing the command path
- **Documentation** - Improving docs, tutorials, and examples

### Future
- **DX12 Support** - Extending to DirectX 12
- **Vulkan Support** - Alternative rendering backend
- **Linux Host** - Porting the backend to Linux

## Development Setup

### Prerequisites

- **Windows 11** with Hyper-V/WHPX enabled
- **Visual Studio 2022** with C++ and Windows SDK
- **Windows Driver Kit (WDK)** for driver development
- **Rust** (latest stable) for the backend
- **QEMU source code** for device development

### Building

```powershell
# Backend (Rust)
cd backend
cargo build

# For drivers, see driver/README.md
```

## Code Style

### Rust
- Use `cargo fmt` before committing
- Use `cargo clippy` to catch common issues
- Follow Rust API guidelines

### C/C++
- Use clang-format with the provided .clang-format
- Follow QEMU coding style for qemu-device/
- Follow Windows driver conventions for driver/

## Pull Request Process

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run tests and lints
5. Commit with clear messages
6. Push to your fork
7. Open a Pull Request

## Commit Messages

Follow conventional commits:
- `feat:` New features
- `fix:` Bug fixes
- `docs:` Documentation changes
- `refactor:` Code refactoring
- `test:` Adding tests
- `chore:` Maintenance tasks

Example: `feat(backend): implement CMD_DRAW_INDEXED handler`

## Testing

- Test on Windows 10 and Windows 11 guests
- Test with both NVIDIA and AMD GPUs if possible
- Include test cases for new features

## Questions?

- Open an issue for bugs or feature requests
- Start a discussion for questions or ideas

## License

By contributing, you agree that your contributions will be licensed under the project's MIT/Apache-2.0 dual license (GPL-2.0-or-later for QEMU device code).
