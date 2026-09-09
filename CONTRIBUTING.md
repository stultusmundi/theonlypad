# Contributing

The project is an incomplete native development build. The full requirements are not yet implemented or verified. Start with the [build brief](docs/BUILD_PROMPT.md) and [agent instructions](AGENTS.md).

For a change, describe the problem, expected behavior, and how it was verified. Keep changes focused, include relevant regression tests, and document user-visible behavior. UI changes should include sanitized screenshots and evidence from the actual macOS application.

Use synthetic fixtures and remove personal information from reports. Do not attach real user files, API keys, private paths, or document recovery data.

Before adding a dependency, assess maintenance, security, license compatibility, and whether the benefit justifies it. Commit lockfiles where supported and record third-party notices.

Contributions are submitted under the repository's MIT License. Only contribute material you have the right to license. Third-party material must preserve its license and attribution.

Be respectful, provide reproducible evidence, and discuss technical disagreements constructively. Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Build and test commands are in [AGENTS.md](AGENTS.md) and [README.md](README.md). Run core tests, native synthetic harnesses, strict Swift formatting and public-source checks before proposing changes. A passing build or in-process controller test does not establish desktop workflow parity.
