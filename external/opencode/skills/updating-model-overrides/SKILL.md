---
name: updating-model-overrides
description: Use when checking configured Octane LLM proxy models for newer releases or reviewing model IDs and prices in work-overrides.json.
---

# Updating Model Overrides

## Overview

Replace a configured model only when catalog evidence proves candidate is newer, compatible with configured capabilities, and no more expensive. Uncertainty means no edit.

## When to Use

- Check or refresh models configured in `external/opencode/work-overrides.json`.
- Don't use for adding providers or changing pricing policy.
- Requires catalog network access and write access to the config.

## Procedure

1. Read `external/opencode/work-overrides.json`: IDs, settings, agent refs (`jq`); find refs/stale IDs with `rg -n -F` in `external/opencode`.
2. Fetch catalog once to file (shell vars die with persistent-shell `exit`; never print/refetch):
   ```
   C=$(mktemp "${TMPDIR:-/tmp}/llm-catalog.XXXXXX.json")
   trap 'rm -f "$C"' EXIT
   curl -fsS --max-time 60 -H "Authorization: Bearer ${OCTANE_API_KEY:?unset}" \
     "https://llm.ai-dev.octane.co/model/info" -o "$C"
   ```
3. Inspect exact IDs + same-family candidates only. Derive family regex from config IDs (e.g. `^(claude-opus|kimi|grok|gpt-6)`), then project — guards avoid jq null-key crashes (`paths(scalars)` breaks here; use `to_entries`):
   ```
   jq '[.data[]
     | select((.model_name // "" | type)=="string"
       and (.model_name | test("REGEX";"i")))
     | {model_name, key:.model_info.key, base:.model_info.base_model,
        backend:.litellm_params.model, direct:.model_info.direct_access,
        reasoning:.model_info.supports_reasoning,
        ctx:.model_info.max_input_tokens,
        max_out:.model_info.max_output_tokens,
        costs:(.model_info|to_entries
               |map(select((.key|test("cost";"i")) and (.value!=null)))
               |from_entries)}]
     | unique_by(.model_name)' "$C"
   ```
   Catalog `max_input_tokens` may read below advertised context (e.g. 922k vs 1M); keep config's published limit unless catalog proves shrink.
4. Swap only if explicitly newer, same family, distinct available backend, and capability-compatible. Same backend = alias; prefer clearest route. Vendor lookup only if catalog cannot order; uncertainty => no swap.
5. Compare current/candidate per currency/unit/context/billing dimension; USD/token x 1e6. Include applicable input/output/cache/batch/duration/query/tier charges. Require input/output; optional charges comparable or confirmed unsupported. Unknown/incomparable => no swap. Never average/zero unknown; candidate <= current per dimension.
6. Qualifying swap: exact `model_name`; refresh name/cost/known limits; update refs; preserve unrelated settings; remove old entry if unused.
7. Validate JSON + search stale refs. Uncertain => no edit; state reason. Briefly report changed/unchanged models; tell user restart OpenCode.

Example: `claude-opus-5.5` input/output rates below `claude-opus-5` do not alone qualify it; cached and applicable tier rates must also pass.
