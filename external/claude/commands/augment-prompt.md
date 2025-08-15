---
description: "Produce a thorough response to a prompt"
argument-hint: "[prompt]"
allowed-tools: ["WebFetch", "WebSearch", "TodoWrite", "ExitPlanMode"]
model: "us.anthropic.claude-sonnet-4-20250514-v1:0"
---

Think step-by-step and follow this procedure:

1. Generate a comprehensive prompt for AI comsumption that maximizes the quality of the response.
2. Print the augmented prompt generated in step 1.
3. Ask the user whether to proceed with remaining steps.
4. Create a plan to answer the prompt in step 1.
5. Run through the plan generated in step 3.
6. Summarize the output concisely.

Step 1 should be based off of the following: "$ARGUMENTS"
