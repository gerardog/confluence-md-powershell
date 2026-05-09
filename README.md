# confluence-md-powershell

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A PowerShell port of [jackchuka/confluence-md](https://github.com/jackchuka/confluence-md) — designed for restricted environments where only source-code tools are available and compiled binaries cannot be run.

## Overview

This repository provides two focused PowerShell scripts that replicate the core workflow of `confluence-md`:

| Script | Purpose |
|---|---|
| `Download-ConfluencePage.ps1` | Authenticates with the Confluence API, downloads page content and images, then calls the conversion script |
| `Convert-ConfluenceHtml.ps1` | Converts a locally-available Confluence HTML file to clean Markdown (works independently, no API required) |

The **conversion script** works standalone — point it at any exported Confluence HTML file and it produces Markdown output.

The **downloader script** handles authentication, downloads the raw HTML and attached images from a Confluence Cloud instance, and then delegates to the conversion script.

## Why PowerShell?

Many enterprise and air-gapped environments have PowerShell available but do not allow installing Go toolchains or running pre-compiled binaries. This project makes the same Confluence → Markdown workflow available in those settings using only built-in or readily-available scripting tools.

## Git Submodule

This repository includes `jackchuka/confluence-md` as a Git submodule at `./upstream/confluence-md/`. The submodule:

- Keeps the upstream project cleanly separated from the local PowerShell scripts
- Locks this repository to a known, reviewed version of the upstream code
- Makes it easy to inspect the reference implementation when porting new behaviour
- Lets AI agents and source-code-only tools browse both codebases in one place

To clone this repository with the submodule:

```powershell
git clone --recurse-submodules https://github.com/gerardog/confluence-md-powershell.git
```

If you already cloned without `--recurse-submodules`:

```powershell
git submodule update --init --recursive
```

## Usage

### Convert an exported HTML file (no API access needed)

```powershell
.\Convert-ConfluenceHtml.ps1 -InputFile "page.html" -OutputFile "page.md"
```

### Download and convert a live Confluence page

```powershell
.\Download-ConfluencePage.ps1 `
    -PageUrl  "https://example.atlassian.net/wiki/spaces/SPACE/pages/12345/Title" `
    -Email    "you@example.com" `
    -ApiToken "your-api-token"
```

The downloader saves the output Markdown (and any images) to the current directory by default. Use `-OutputDir` to specify a different location.

> **Tip:** Create a Confluence API token at <https://id.atlassian.com/manage-profile/security/api-tokens>.

## Requirements

- PowerShell 5.1 or later (Windows built-in) **or** [PowerShell 7+](https://github.com/PowerShell/PowerShell) (cross-platform)
- Network access to your Confluence Cloud instance (downloader script only)

No additional modules or compiled binaries are required.

## Project Status

This project is in early development. The conversion script is being built incrementally by porting behaviour from the reference implementation in `./upstream/confluence-md/`. See the open issues for the current roadmap.

## Upstream Relationship

This project is a PowerShell-oriented port of the original [`jackchuka/confluence-md`](https://github.com/jackchuka/confluence-md) tool. The upstream repository remains the reference implementation for conversion behaviour, while this repository focuses on providing a source-only PowerShell workflow for environments where compiled binaries are not suitable.

## Related Projects

- [jackchuka/confluence-md](https://github.com/jackchuka/confluence-md) — the original Go CLI tool this project ports

## License

[MIT](LICENSE) © Gerardo Grignoli
