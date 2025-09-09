# Definitions: data, calculations, & actions

- data: any artifact that contains no behavior. this category includes strings, numbers, collections, and data classes. it excludes functions and methods.
- calculation: a pure function or method that when given a set of inputs always produces the same output. it is not a calculation if the function produces effects, such as disk IO, network IO, logging, or otherwise accesses external state. if a function calls a function that performs effects in its definition, it is also an impure function.
- action: an impure function that can produces effects, such as disk IO, network IO, logging, or otherwise accesses external state. **important: if a function calls a function that produces effects, it is an action (statefulness is infectious).**

# Generating code

- Unless explicitly directed not to, attempt to match the coding style of existing code
- Prefer data to calculations or actions
- Prefer calculations to actions
- Imperative shell/functional core: place actions at the edge of the application (bottom of call stack)
- Use data classes to represent program values and state
- Keep function implementations at a level of abstraction aligned with its name. e.g., `upload_file_to_sftp` could call `connect_to_server`, `upload_file_to_remote_directory`, and `verify_upload`, rather than including the lower-level implementation logic directly in its body
- Identify problem domain primitives (functions) to maximize re-use and expressiveness
- Separate program description from program execution

# Language-specific Principles

## Python

- blank lines should not have any whitespace (e.g., indent)
- do not use relative imports
