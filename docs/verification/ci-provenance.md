# CI provenance

Workflow configuration added locally; hosted CI has not run and no badge is claimed.

Immutable action tags verified against official upstream Git refs with `git ls-remote` on 2026-09-09:

- actions/checkout v4.2.2: `11bd71901bbe5b1630ceea73d27597364c9af683`
- actions/dependency-review-action v4.7.3: `595b5aeba73380359d98a5e087f648dbb0edce1b`

Workflow has read-only repository permissions, no credential persistence, no privileged pull-request trigger, no release upload, no signing credentials and no external secrets. Dependencies currently consist only of Apple system frameworks and Swift standard libraries; any newly added package must trigger license/inventory review. Pattern checks are limited source hygiene, not a comprehensive secret scanner. Full secret-scanning coverage remains outstanding.
