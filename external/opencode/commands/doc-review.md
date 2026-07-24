---
name: doc-review
description: Run the document review loop on a document before saving it or
  proceeding. Accepts a file path. Iterates until no critical findings remain
  or the user declines to extend past the round cap.
arguments:
  - name: target
    description: Path to the document to review, optionally followed by
      --rounds N (default 3) and/or --critics M (default 1)
    required: true
---

Run the doc-review workflow on: $ARGUMENTS

Parse the document path and any --rounds/--critics flags from the argument
above. Load the run-doc-review skill and follow its complete protocol:
dispatch critique and update rounds, apply the stop condition, handle the
round-cap extend checkpoint, and issue the final report.
