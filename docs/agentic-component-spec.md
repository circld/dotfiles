# Agentic AI Component Specification

Best practices for authoring instructions, skills, commands, agents, and tools.

This document defines rules for creating and composing agentic AI components that are effective, maintainable, correctly orchestrated, and operationally reliable. It is both a human reference and an AI-loadable specification: it can be used as a skill or instruction for AI agents that create or modify agentic components.

The rules are best-practice guidelines derived from vendor documentation (OpenCode, Claude Code, GitHub Copilot, Cursor), system design analysis, and engineering judgment.

## Background

Agentic AI tools share a common set of component types despite differing terminology. Every major tool ecosystem provides passive context injection (rules/instructions), on-demand workflow knowledge (skills/prompt files), user-triggered actions (commands/slash commands), autonomous actors (agents/subagents), and external capability integration (MCP servers/custom tools). This specification abstracts the common patterns into a unified component model with five types.

## Component Model

Every agentic AI component is a configuration artifact that shapes how an AI agent behaves. The five component types form a layered system, ordered by how they enter the agent's context.

**This taxonomy is a design lens, not a file-format specification.** Platform artifacts do not map 1:1 to these types. A single file may combine concerns from multiple types — for example, a Claude Code "skill" that references specific tools and routes to a named agent is functioning as a Command (or even an Agent definition) in this taxonomy, not a Skill. The value of the taxonomy is in making these mixed concerns visible so they can be evaluated and, where appropriate, separated.

### Component Types

**Instruction.** Declarative text injected automatically into the agent's context window. An instruction has no behavior of its own. It constrains or guides the agent's behavior passively. Instructions are scoped by location (global, project, path) and loaded based on proximity (directory traversal). Because they consume context on every session, they must be concise.

**Skill.** A reusable, self-contained knowledge unit for a specific domain or workflow. Unlike an instruction, a skill is loaded on demand -- either by the agent deciding it is relevant, or explicitly by the user or another component. Skills encode how to do something (a process, a checklist, a workflow) rather than a constraint. Skills do not themselves execute -- they are injected into an agent's context, which then acts on them.

**Command.** A user-triggered prompt template. It bridges human intent with agent execution. A command has a name (for invocation), a prompt template (with argument placeholders), and optional routing metadata (which agent runs it, which model to use). Commands make repeatable workflows accessible through a short invocation.

**Agent.** An autonomous actor with its own system prompt, tool access list, model, and permission scope. Agents define the execution boundary: what the AI can see, do, and decide. Agents come in two modes: primary (directly interactive) and subagent (delegated by a primary agent or invoked programmatically). Agents are the sole orchestration layer in the component model.

**Tool.** An external capability that an agent can invoke. Tools are provided by MCP servers, custom tool definitions, or built-in platform capabilities. Tools give agents access to the outside world (APIs, databases, browsers, file systems).

### Shared Properties

| Property | Description |
|---|---|
| Name | Unique identifier within its type. Lowercase, hyphenated. |
| Description | Human-and-AI-readable summary of purpose and when to use it. |
| Scope | Where it applies: global (user), project, or local. |
| Format | Markdown with optional YAML frontmatter. |

### Dependency Graph

Components may only depend on other components in the directions shown below. Skills and instructions are leaf nodes with no outward dependencies.

```
Instruction ──> (nothing)
Skill ────────> (nothing)
Command ──────> Agent
Agent ────────> Tool
Agent ────────> Skill (preloads into context)
Agent ────────> Agent (delegates to subagent)
```

## Instruction Rules

An instruction is pure context. It has no trigger, no behavior, no parameters. It is always-on text that the agent reads at session start. Every word in an instruction costs tokens on every session.

**I-1. Be specific and verifiable.** Write instructions that an observer could check for compliance. "Use 2-space indentation" is verifiable. "Write clean code" is not. If the instruction cannot be violated in an observable way, it is too vague to be useful.

**I-2. Budget context ruthlessly.** Target under 200 lines per instruction file. Every instruction competes for finite context window space. If you find yourself writing extended explanations, the content belongs in a skill (loaded on demand) rather than an instruction (loaded always).

**I-3. Scope narrowly.** Use the most specific scope available. Path-scoped instructions (triggered only when the agent reads matching files) consume zero context when irrelevant. Prefer path-scoped rules over project-wide rules, and project-wide rules over global rules.

**I-4. Structure for scanning.** Use markdown headers and bullet lists. Agents process structured text more reliably than prose paragraphs. Group related constraints under descriptive headers.

**I-5. Avoid duplication across scopes.** If a global instruction and a project instruction say the same thing, the project instruction wins and the global one wastes context. Audit across scopes periodically to remove redundancy.

**I-6. State the "what," not the "how."** Instructions declare constraints and standards. If you need to describe a multi-step process, that belongs in a skill. Instructions say "all API endpoints must validate input"; skills say "here is how to implement input validation."

**I-7. No conflicting instructions.** When two instructions contradict each other, agent behavior becomes nondeterministic. If an instruction in scope A conflicts with one in scope B, the conflict must be resolved by the author. Do not rely on the agent to reconcile contradictions.

**I-8. Use imperative mood.** Write "use enums for legal value sets" not "enums should be used for legal value sets." Direct, imperative instructions are shorter and parsed more reliably by both humans and AI.

## Skill Rules

A skill is an on-demand knowledge package. Unlike an instruction, a skill can be longer and more procedural because it only enters context when needed. The challenge with skills is discoverability: the agent must decide when to load one, based solely on its name and description.

**S-1. Single responsibility.** A skill should encode one workflow, one domain, or one procedure. "Test-driven development" is a good skill. "Testing and deployment and release management" is three skills. If the skill's description requires the word "and" between unrelated concerns, split it.

**S-2. Write the description for the router, not the reader.** The description is what the agent (or a human scanning a list) uses to decide whether to load the skill. It must answer: "under what circumstances should this skill be activated?" Descriptions like "helpful utilities" fail because they do not discriminate. Descriptions like "use when encountering test failures or unexpected behavior, before proposing fixes" succeed because they specify a triggering condition.

**S-3. Front-load the decision-relevant information.** Put the most important workflow steps and decision criteria at the top. If the skill is long, critical instructions go first. Supplementary context and edge cases go later.

**S-4. Describe actions at the domain level, not the tool level.** A skill tells the agent *what to do*, not *which tool to do it with*. Describe concrete, actionable steps using domain language. "Search the codebase for all callers of the failing function, then read each call site" is good -- it is specific and actionable. "Gather evidence about the failure" is too abstract -- the agent does not know what actions to take. "Use the Grep tool to run `rg functionName src/`" is too concrete -- it couples the skill to a specific tool the agent may not have. The agent decides which tools fulfill the actions the skill describes.

**S-5. Name matches directory.** The skill name must match its containing directory name exactly. When names drift from directories, discoverability breaks silently.

**S-6. Include "when to use" and "when not to use."** Explicitly state the skill's applicability boundaries. This prevents both false positives (skill loaded when irrelevant, wasting context) and false negatives (skill not loaded when needed). The "when not to use" section is particularly valuable because it prevents the agent from treating a skill as a universal hammer. If the skill's workflow requires specific capabilities (write access, shell execution, network access), state this in the applicability section so agents without those capabilities do not load it.

**S-7. Parameterize rather than duplicate.** If two skills differ only in a small way, consider whether one parameterized skill can serve both purposes. Duplication across skills creates maintenance burden and risks divergence.

**S-8. Skills must not depend on specific platform components.** A skill does not name specific tools, agents, other skills, or commands. It describes actions ("run the test suite," "search for callers," "commit the change") that any suitably-equipped agent can map to its own tool set. This keeps skills portable across agents with different tool configurations and prevents lateral dependencies among leaf-node components.

## Command Rules

A command is a user-triggered prompt template. It translates a short invocation into a structured prompt. Commands are the simplest component type: a name, a description, a template, and optional routing.

**C-1. One command, one intent.** A command should do one thing. The name should be a verb or verb-phrase that communicates the action.

**C-2. Template completeness.** The prompt template must produce a valid, actionable prompt even with no arguments. If the command requires arguments, the zero-argument case should produce a helpful error or a sensible default, not an incoherent prompt.

**C-3. Specify the agent when the task demands specific capabilities.** If a command requires file writes, route it to an agent with write access. If a command is read-only analysis, route it to a read-only agent. Explicit agent routing prevents silent capability mismatches.

**C-4. Keep templates declarative.** The template describes what the agent should accomplish, not the step-by-step tool calls it should make. "Run the test suite and report failures with suggested fixes" is better than "execute `npm test`, parse stdout, find lines with FAIL, then use the edit tool on each file." The agent should decide the execution strategy.

**C-5. Document argument semantics.** If a command accepts positional arguments, the description or template must explain what each argument means. Unnamed positional parameters are a maintenance hazard. Include a usage example in the description.

**C-6. Prefer subtask mode for heavy commands.** Commands that produce verbose output or require significant context (test runs, large-scale reviews) should use subtask mode to avoid polluting the primary conversation context.

## Agent Rules

An agent is the most complex component type. It defines an execution boundary: its own system prompt, model, tool access, and permissions. The key tension in agent design is between power (giving the agent enough capability to complete tasks) and constraint (limiting scope to prevent misuse and reduce error surface).

**A-1. Write the description as a delegation contract.** The description tells the orchestrating agent (or the user) when and why to invoke this agent. It must answer: "What does this agent do that the primary agent should not do itself?" If you cannot articulate a clear delegation boundary, the agent probably should not exist as a separate entity.

**A-2. Principle of least privilege for tools.** Grant only the tools the agent needs to fulfill its described purpose. A code reviewer does not need write access. A debugger does not need web fetch. Excess tool access increases the blast radius of mistakes and makes the agent's behavior harder to predict.

**A-3. Match model to task complexity.** Use faster, cheaper models for simple tasks (exploration, search) and more capable models for complex tasks (architecture decisions, nuanced code review). The model should match the cognitive demands of the agent's specific role.

**A-4. System prompts should constrain, not narrate.** An agent's system prompt defines its identity and boundaries. Write it as a set of operating constraints and priorities, not a creative writing exercise. Focus on what the agent should do, how it should prioritize, and what it should avoid.

**A-5. Design agents to function from the invocation contract alone.** An agent must produce correct results given only the context explicitly provided in the task description. If the coordination mechanism provides inherited parent context (e.g., shared conversation thread), agents may use it to improve quality, but must not require it for correctness. This keeps agents portable across systems that do and do not preserve parent state.

**A-6. Use permission modes intentionally.** If an agent should only analyze (not modify), enforce this with permissions, not just prompt instructions. Prompts are guidance; permissions are enforcement. A read-only agent with `edit: deny` cannot modify files, regardless of what the prompt says.

**A-7. One primary purpose per agent.** An agent named "debugger" should debug. If it is also reviewing code, writing docs, and deploying, it is doing too much. Focused agents produce more predictable results because the system prompt and tool set can be tightly aligned to a single domain.

## Tool Rules

Tools are external capabilities (MCP servers, custom tool definitions). They are the integration boundary between the AI and the outside world.

**T-1. Tool descriptions are prompts.** The tool's name, description, and parameter schema are what the agent uses to decide when and how to invoke the tool. Write descriptions that explain when to use the tool, not just what it does.

**T-2. Idempotent where possible.** Tools that can be called multiple times without side effects (reads, searches) are safer and easier for agents to use. When a tool has side effects, document them clearly in the description. Destructive tools should require explicit confirmation.

**T-3. Return structured, parseable, size-bounded output.** Tool output should be structured enough for the agent to process programmatically and compact enough for the caller to retain only what matters. Prefer summaries, identifiers, counts, and relevant snippets over walls of raw text unless the raw output is itself the artifact under review.

**T-4. Scope tool access per agent.** Do not give all tools to all agents. A tool that is available to every agent is a tool that every agent might misuse. MCP servers should be scoped to the agents that need them, not globally registered.

**T-5. Validate tool inputs at the boundary.** Tools should validate their inputs before executing. An agent may pass malformed parameters. The tool should fail gracefully with a clear error message, not silently corrupt state.

## Orchestration Rules

Components do not exist in isolation. Instructions shape agents. Skills get loaded into agents. Commands route to agents. Agents invoke tools and delegate to other agents. These rules govern how components reference, depend on, and compose with each other.

The core orchestration principle is: **agents own orchestration.** Skills, instructions, and tools are composable units that agents assemble. Commands are invocation shortcuts that route to agents. No component type other than agents encodes workflow sequencing or delegates to other components. Orchestration includes both sequential and concurrent dispatch; the principles below are written to hold under either model.

Context economy also applies to orchestration. The coordinating agent should preserve its context for planning, synthesis, and decision-making. Broad exploration, noisy searches, and high-volume intermediate output should be pushed to bounded tools or subagents that return distilled, decision-relevant results.

**O-1. Agents are the only component that references other components by name.** Agent configurations declare their tools, skills, and subagents. Commands declare which agent they route to. No other component references another by name. If you find a skill or instruction referencing a specific agent, skill, or tool, that reference belongs in the agent that loads the skill, not in the skill itself.

**O-2. Agent prompts define workflow sequences.** When a task requires multiple phases (brainstorm, plan, implement), the sequencing logic lives in the agent's system prompt or is determined dynamically by the agent based on conversation context. This centralizes workflow knowledge in a component that has full context to make adaptive decisions.

**O-3. Skills are pure, composable knowledge units.** A skill encodes domain expertise for one concern. It does not reference other skills, agents, or tools. It provides the "what to do" and "how to think about it." The agent decides when to apply it, in what order, and alongside which other skills.

**O-4. Delegation is a bounded work contract.** Every delegated task must define: (1) the required input context, (2) assumptions about inherited versus explicitly-provided state, (3) the expected output shape, and (4) completion criteria. The delegating agent must not assume the subagent shares conversation history, loaded skills, or tool state unless the coordination mechanism guarantees it and the contract documents the dependency. Design delegations as self-contained work units by default.

**O-5. Prefer shallow delegation with explicit join points.** A primary agent that dispatches to subagents directly is easier to debug and reason about than a chain where agent A delegates to agent B, which delegates to agent C. Whether subagents run sequentially or concurrently, keep delegation depth shallow and define clear ownership of the merge point where results are combined.

**O-6. Scope tool and skill access per agent, not globally.** Each agent should declare exactly which tools and skills it needs. Global tool or skill registration makes it impossible to reason about what any single agent will do. Explicit, per-agent declarations are the configuration equivalent of principle of least privilege.

**O-7. Combined context must be conflict-free.** When an agent loads multiple skills and operates under project instructions, the combined context must not contain contradictions. The agent author is responsible for testing that their agent's loaded skills are compatible with each other and with the instructions in scope.

**O-8. Design delegated outputs to be merge-safe when tasks may run concurrently.** When the coordination mechanism allows parallel subagent execution, structure outputs to be attributable (clear which subtask produced them), non-overlapping (subtasks should not modify the same artifacts without explicit conflict resolution), and independently verifiable. This is optional for strictly sequential delegation but required when parallelism is possible.

**O-9. Isolate exploratory work from the coordinator.** When a task requires broad search, codebase exploration, or high-volume tool output, delegate that work to a specialized subagent or use a bounded retrieval mechanism. The coordinating agent should receive distilled, attributable, decision-relevant results rather than raw exploration traces.

## Verification Rules

Agentic AI components shape the behavior of a nondeterministic system. The "output" of a component is the agent's behavior across many varied sessions, and that behavior is probabilistic. Verification requires different strategies than traditional software testing.

A component is "correct" when the agent that uses it consistently behaves as the component's author intended. There are three failure modes: non-activation (the component exists but the agent never loads it when it should), misinterpretation (the component is loaded but the agent interprets it differently than intended), and capability mismatch (the component assumes capabilities the agent does not have).

**V-1. Test activation, not just content.** After creating a skill or agent, verify that it actually gets loaded or invoked under the intended conditions. Ask the AI to describe which components it has loaded. A component that never activates is dead code.

**V-2. Test with representative prompts.** For each component, identify 2-3 prompts that should trigger it and 2-3 that should not. Run them. Verify the component activates for the positive cases and stays dormant for the negative cases.

**V-3. Verify capability alignment.** For every skill, check that the agents likely to load it have the tools and permissions the skill's workflow requires. If a skill describes a debugging workflow that requires running bash commands, and the agent loading it has bash denied, the skill will produce instructions the agent cannot follow.

**V-4. Check for context conflicts before deployment.** When adding a new component, review the full context it will coexist with. Load the agent, list its skills and active instructions, and read through them looking for contradictions.

**V-5. Verify subagent delegation round-trips.** When an agent delegates to a subagent, test that the subagent receives enough context to complete the task and that the result returned to the parent is usable. Run a delegation scenario end-to-end.

**V-6. Monitor for silent degradation.** Components can break without errors. A renamed skill that nothing loads anymore still exists on disk but does nothing. An instruction that contradicts a newly added skill causes inconsistent behavior without any error message. Periodically audit which components are actually being activated in practice.

**V-7. Version control all components.** Instructions, skills, commands, and agent configs must be in version control. This enables diffing when behavior changes and enables code review of component changes before they affect team workflows.

**V-8. Test compositions, not just individual components.** The most subtle bugs occur at composition boundaries. A skill that works in isolation may conflict with another skill when both are loaded into the same agent. Test the agent with its full skill and instruction set loaded, not each component individually.

**V-9. Test under both serial and concurrent execution when the platform supports parallel delegation.** A delegation that works correctly when subagents run one at a time may fail when they run concurrently (resource contention, output conflicts, ordering assumptions). If the target platform supports parallel dispatch, verify delegation round-trips under both modes.

## Quick Reference

| ID | Rule |
|---|---|
| I-1 | Be specific and verifiable |
| I-2 | Budget context ruthlessly (under 200 lines) |
| I-3 | Scope narrowly (prefer path-scoped over project-wide over global) |
| I-4 | Structure for scanning (headers and bullets) |
| I-5 | Avoid duplication across scopes |
| I-6 | State the "what," not the "how" |
| I-7 | No conflicting instructions |
| I-8 | Use imperative mood |
| S-1 | Single responsibility |
| S-2 | Write the description for the router, not the reader |
| S-3 | Front-load the decision-relevant information |
| S-4 | Describe actions at the domain level, not the tool level |
| S-5 | Name matches directory |
| S-6 | Include "when to use" and "when not to use" |
| S-7 | Parameterize rather than duplicate |
| S-8 | Skills must not depend on specific platform components |
| C-1 | One command, one intent |
| C-2 | Template completeness (valid with zero arguments) |
| C-3 | Specify the agent when the task demands specific capabilities |
| C-4 | Keep templates declarative |
| C-5 | Document argument semantics |
| C-6 | Prefer subtask mode for heavy commands |
| A-1 | Write the description as a delegation contract |
| A-2 | Principle of least privilege for tools |
| A-3 | Match model to task complexity |
| A-4 | System prompts should constrain, not narrate |
| A-5 | Design agents to function from the invocation contract alone |
| A-6 | Use permission modes intentionally |
| A-7 | One primary purpose per agent |
| T-1 | Tool descriptions are prompts |
| T-2 | Idempotent where possible |
| T-3 | Return structured, parseable, size-bounded output |
| T-4 | Scope tool access per agent |
| T-5 | Validate tool inputs at the boundary |
| O-1 | Agents are the only component that references other components by name |
| O-2 | Agent prompts define workflow sequences |
| O-3 | Skills are pure, composable knowledge units |
| O-4 | Delegation is a bounded work contract |
| O-5 | Prefer shallow delegation with explicit join points |
| O-6 | Scope tool and skill access per agent, not globally |
| O-7 | Combined context must be conflict-free |
| O-8 | Design delegated outputs to be merge-safe when concurrent |
| O-9 | Isolate exploratory work from the coordinator |
| V-1 | Test activation, not just content |
| V-2 | Test with representative prompts |
| V-3 | Verify capability alignment |
| V-4 | Check for context conflicts before deployment |
| V-5 | Verify subagent delegation round-trips |
| V-6 | Monitor for silent degradation |
| V-7 | Version control all components |
| V-8 | Test compositions, not just individual components |
| V-9 | Test under both serial and concurrent execution |
