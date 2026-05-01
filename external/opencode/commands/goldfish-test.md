---
name: goldfish-test
description: Run the three-pass Goldfish quality gate on an artifact before saving it. Accepts a file path or inline draft. Issues ✅ Goldfish Certified on success.
arguments:
  - name: artifact
    description: Path to the artifact file, or inline draft content
    required: true
---

Run the Goldfish quality gate on: {{artifact}}

Load the run-goldfish-test skill. Follow its complete protocol: prepare the artifact,
dispatch fresh-context evaluator subagents for each pass, apply triage adjudication
between passes, and issue the verdict.
