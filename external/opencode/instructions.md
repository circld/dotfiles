**Don't validate me — challenge me.**

# Reading and writing code

> The instructions in this section apply when generating, modifying, or reviewing code.

## Definitions: data, calculations, & actions

- data: any artifact that contains no behavior. this category includes strings, numbers, collections, and data classes. it excludes functions and methods.
- calculation: a pure function or method that when given a set of inputs always produces the same output. it is not a calculation if the function produces effects, such as disk IO, network IO, logging, or otherwise accesses external state. if a function calls a function that performs effects in its definition, it is also an impure function.
- action: an impure function that can produces effects, such as disk IO, network IO, logging, or otherwise accesses external state. **important: if a function calls a function that produces effects, it is an action (statefulness is infectious).**

## Generating code

- Unless explicitly directed not to, attempt to match the coding style of existing code
- Prefer data to calculations or actions
- Prefer calculations to actions
- Imperative shell/functional core: place actions at the edge of the application (bottom of call stack)
- Use data classes to represent program values and state
- Classes should not contain behavior (methods) unless it's part of a framework (e.g., Pydantic)
- Keep function implementations at a level of abstraction aligned with its name. e.g., `upload_file_to_sftp` could call `connect_to_server`, `upload_file_to_remote_directory`, and `verify_upload`, rather than including the lower-level implementation logic directly in its body
- Identify problem domain primitives (functions) to maximize re-use and expressiveness
- Separate program description from program execution
- Prefer enums for sets of legal values to minimize magic values and maximize clarity

## Testing

> These rules apply whenever writing, modifying, or reviewing test code.

- A test should cover a single behavior
- Patches violate encapsulation boundaries; treat them as a last resort, not a default
- Many patches in one test signal coupling or cohesion problems in the production code — refactor the production code first
- Prefer the least powerful double that satisfies the test
- Mocks assert on *interactions* (side effects); don't use them when asserting on return values or state — use stubs or fakes instead
- Don't mock code you don't own
- Prefer dependency injection over patching: pass collaborators as arguments rather than monkeypatching them at import time
- Mocks target *roles* (interfaces/protocols), not concrete objects

### Test double reference

| name  | behavior                               |
|-------|----------------------------------------|
| mock  | records calls; asserts on side effects |
| stub  | returns canned data, no logic          |
| fake  | lightweight working implementation     |
| dummy | placeholder; never called              |
| spy   | records calls and delegates to real    |

## Language-specific Principles

### Python

- blank lines should not have any whitespace (e.g., indent)
- do not use relative imports
- use bash and pbcopy when asked to copy to clipboard

# CLI utilities

CLI utilities for system-wide use are located in ~/.nix-profile. Project CLI utilities may be available via nix shell.
