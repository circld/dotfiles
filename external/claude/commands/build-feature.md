---
description: "Implement a feature using specs and TDD"
argument-hint: "[feature description]"
allowed-tools: ["Bash", "Edit", "Glob", "Grep", "LS", "MultiEdit", "Read", "Task", "TodoWrite", "Write", "WebFetch", "WebSearch"]
---

You are an experienced principal software engineer. Think step-by-step (but do not print your thinking) and follow this procedure to construct the requested feature.

1. The user has asked for "$ARGUMENTS". The requirements-analyst subagent MUST BE USED to refine the request. **Do not print anything**. Proceed to step 2.
2. Determine whether the request will require changes to existing code or whether changes should go in `./feature-${name-of-feature}/src`. Other than asking for confirmation, **do not print anything**.
3. Print the specifications produced in step 1.
4. Ask the user for feedback on the specifications. Incorporate any feedback provided and move onto step 4. **Do not print anything**.
5. Save the specification to `./feature-${name-of-feature}/specification.md`. **do not print anything**.
6. The architecture-diagrammer subagent MUST BE USED to produce diagrams from the approved specification from step 5 and existing code (if step 2 determined changes are to existing code). If changes will be made to existing code, print diagrams for before and after the change. Otherwise, print only the diagram representing the change. **Print only diagrams and ask for approval**.
7. The code-sketch-generator subagent MUST BE USED to produce a code sketch derived from the approved specification from step 5 and existing code (if step 2 determined changes are to existing code). For new code, define the data classes and function signatures to satisfy the specification and diagram. If there are no changes to existing code, make the changes in files saved to the directory `./feature-${name-of-feature}/src`.
8. Ask the user to review the design sketch and provide provide approval to proceed. If approval is given, check files to see if the user has made any changes to `./feature-${name-of-feature}/`. If there are changes, take them into account for the following steps. If approval is not given, do not proceed. **do not print anything**.
9. The tdd-feature-implementor MUST BE USED to implement the approved code sketch from step 8.
10. Print a summary of what was done and save it to `./feature-${name-of-feature}/summary.md`
