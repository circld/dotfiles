---
name: explaining-unfamiliar-material
description: Use when user learning unfamiliar concepts, codebases, systems, or documentation; asks how something works, requests walkthrough, or signals confusion about newly built behavior. Not status-only requests, routine execution, or isolated fact lookups.
---

# Explaining unfamiliar material

Build usable mental model, not glossary. Shape content/structure; preserve user's prose style. Keep causal links explicit. Walkthroughs belong in chat, not bloated code comments.

## When to use

Use for learning, unfamiliar material, lost mental model. Skip status-only updates, routine execution, isolated facts; don't force lessons into delegated work.

## Pattern

1. Anchor explanation to user's goal and known prerequisites. Infer from chat; ask one question only if gap blocks useful explanation. No intake interview.
2. Lead with one-sentence model. Chunk by causal/conceptual steps, not file inventory. Define new terms before use; keep names stable. Work one concrete example: input, behavior, outcome, relevant failure/boundary. Brevity shrinks example, doesn't remove it.
3. Code/system walkthrough: inspect sources; trace actual input/state/output/failure path. Cite locations. Separate observed, inferred, unknown. Conformance question? Map requirements to behavior and verification evidence/gaps; explanation alone proves nothing.
4. Choose representation by content: example for procedure, diagram for relationships/flow, table for comparison. Put labels/explanation beside relevant parts. Skip decoration; never assign learning styles.
5. Explicit learning goal: finish teaching with one optional recall/application question targeting key causal link. “No up-front quiz” means teach first; “no quizzes/questions” means omit check. Pretest only if useful and welcome. Respond to answers with specific correction/explanation; adapt next chunk. Never gate task progress or infer mastery from “got it.”
6. End with key model and unresolved gap. Fade guidance as user demonstrates knowledge. Long learning session: revisit prior concept when later relevant; no repetitive recaps or arbitrary review schedule.

## Example

Transaction groups database writes: all commit, or none. Transfer $5: debit sender, credit recipient, then commit. Failure before commit leaves neither change. Boundary: external email doesn't roll back with database writes.

Optional check: credit fails before commit—what should happen to debit?

## Common mistakes

- “Short means omit why” — compress prose, preserve causal chain.
- “Looks clear means understood” — optional application reveals more than acknowledgment.
- “Tests pass means spec met” — name covered requirements and unverified gaps.

## Evidence

Education/multimedia evidence; chat workflow remains design inference.

- [Mayer 2021: coherence, signaling, relevant visuals](https://doi.org/10.1017/9781316941355); [Rey 2019: segmenting](https://doi.org/10.1007/s10648-018-9456-4).
- [Rowland 2014: retrieval](https://doi.org/10.1037/a0037559); [Richland 2009: pretesting](https://doi.org/10.1037/a0016496); [Bisra 2018: self-explanation](https://doi.org/10.1007/s10648-018-9434-x).
- [Kalyuga 2003: expertise reversal](https://doi.org/10.1207/S15326985EP3801_4); [Pashler 2008: learning-style matching unsupported](https://doi.org/10.1111/j.1539-6053.2009.01038.x).
