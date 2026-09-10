# Dependency audit coverage

Target: committed development package source `324a3de6ef8ef94a143b448483ae4f805665de95`. The tracked package manifest is `Package.swift`; it declares no external package dependency. The repository third-party notices and generated development SBOM describe original code/resources and system frameworks. This is an inventory observation, not an advisory or license-compliance verdict.

The installed supply-chain collector supports npm, PyPI and Go. Its instruction is: “Ecosystems other than npm, PyPI, and Go; say the ecosystem is unsupported rather than improvising an audit for it.” No supported manifest was present in the audited application source, so the collector was not run. No GitHub authentication or credentials were accessed. No maintainer counts, registry downloads, staleness scores or CVE claims were inferred.

Unassessed: Swift/toolchain and system-framework advisories, complete dependency/security release review, and hosted CI action supply-chain advisories. These remain outstanding. Existing package integrity and signature checks cover artifact consistency only. Reassess dependencies and license obligations before adopting any third-party component.
