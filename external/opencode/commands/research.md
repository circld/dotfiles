---
name: research
description: "Research a topic. Usage: /research <topic> [url...]"
agent: researcher
---

Research the following: $ARGUMENTS

If no topic was provided, respond with a usage hint:
  /research <topic>
  /research <topic> https://example.com  (optional URL to seed research)

Otherwise, research the topic. If URLs were included, use them as primary sources.
