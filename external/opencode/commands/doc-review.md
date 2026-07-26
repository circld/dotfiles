---
name: doc-review
description: Run the iterative document review loop on a file. Iterates until no
  critical findings remain or the user declines to extend past the round cap.
arguments:
  - name: target
    description: Path to the document, optionally followed by --rounds N
      (default 3) and/or --critics M (default 1)
    required: true
---

Run doc-review on: $ARGUMENTS

Parse the document path + optional --rounds/--critics flags. Load the
run-doc-review skill and follow its protocol: dispatch critique/update rounds,
apply the stop condition, handle the round-cap extend checkpoint, issue the
final report.
