---
name: deciding-one-at-a-time
description: Use when the user asks to decide one at a time, or multiple unresolved choices need human judgment about scope, priorities, preferences, or material trade-offs. Skip routine details, settled choices, isolated questions, and mere multi-step tasks.
---

# Decide one at a time

Protect human bandwidth: one open decision. Collect choices before implementation; independent AI work may then run concurrently.

## Use when

- User explicitly requests one-at-a-time decisions, or multiple unresolved choices genuinely need their judgment.
- Do not invent choices. Skip routine implementation details, settled requirements, authorized work, isolated questions, and merely multi-step tasks. This governs dialogue, not task scope or permission.

## Process

1. Queue necessary decisions, prerequisites first. Count decisions, not tasks. Keep future items offstage: no later titles, options, questions, or previews—even in status updates.
2. Show current item as `i/n — Title`; `n` includes settled/deferred decisions. Clarification keeps `i`: answer, update `n` for any new decision, then repeat current choice. Defer/skip advances `i`, not `n`. Add/remove only genuine decisions; explain count changes without previewing later items. Count decisions, not clarifications.
3. State briefly what needs deciding and why. Offer 2–3 genuine options; recommend first, tie to user's goal or state assumption. For each, give gains/losses vs a named alternative and biggest risk. Ask one question; stop.
4. Clarify current item before asking again. Accept option labels, clear prose, custom options, or explicit delegation. Recommendation is not consent. Any doubt about meaning or commitment? Ask approval/confirmation; stay on item. Clear commitment needs no redundant confirmation.
5. Acknowledge outcome, then advance. Deferral stays unresolved; assume no default. Allow revisions; mark superseded decisions, reopen affected dependencies, and explain count changes.
6. Recap decisions/deferrals before starting already-authorized implementation. Deferred choices block dependent work only; independent work may run concurrently. Keep existing chat-status conventions; create no status files.

## Example

**1/3 — Storage**

Reports need a home. You work solo and value simple setup.

- **Local (recommended)** — vs cloud: gains simplicity; loses sharing; risk: device loss takes reports with it.
- **Cloud** — vs local: gains sharing; loses simplicity; risk: access misconfiguration exposes reports.

**Choose local or cloud?**

User: “Cloud might work. Is it public?”

Assistant: “Cloud can be private. Do you approve private cloud?” Stay on 1/3; tentative interest isn’t consent.
