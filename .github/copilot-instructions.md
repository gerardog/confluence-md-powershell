# GitHub Copilot Instructions

## Workflow

### 1. Initialize the submodule environment first

Before writing any code, ensure the upstream reference implementation is available locally:

```bash
git submodule update --init --recursive
```

This populates `upstream/confluence-md/` with the full source of the reference implementation. All subsequent work must be informed by that codebase.

### 2. Port from the submodule — do not implement from scratch

This repository is a PowerShell port of the upstream Go implementation at `upstream/confluence-md/`. When implementing or extending any feature:

- **Read the upstream source first.** Locate the relevant logic in `upstream/confluence-md/` before writing a single line of PowerShell.
- **Adapt, don't invent.** Translate the upstream logic, data structures, and algorithm steps into idiomatic PowerShell. The goal is behavioral equivalence with the reference implementation.
- **Reuse the upstream's structure.** Follow the same processing pipeline, transformation steps, and edge-case handling found in the reference code.
- **Never create a brand-new implementation** when a submodule-based port is expected. If the upstream already handles a case, your PowerShell code must handle it the same way.

### 3. Reference path

The upstream reference implementation lives at:

```
upstream/confluence-md/
```

Use this directory as the canonical source of truth for conversion behaviour, HTML-to-Markdown rules, and any other feature logic.
