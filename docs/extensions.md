# Declarative local extensions

The current extension API accepts local JSON manifests defining named commands backed by the existing `LineTransform` operations. It does not load executable plugin code and is not compatible with Windows Notepad++ plugin binaries.

Each manifest requires exactly `apiVersion`, `id`, `name`, `version`, `capabilities`, and `commands`. API version is `1`; `version` is a three-part numeric version such as `1.0.0`. IDs use lowercase ASCII letters/numbers with dot or hyphen separators. The only accepted capability list is `["text.transform"]`. Each command requires a unique local `id`, `title`, and `transform`. Supported transformations are `sorted`, `deduplicated`, `trimTrailingWhitespace`, `uppercase`, `lowercase`, `indent`, and `outdent`.

An original working manifest is in `Examples/CleanupExtension/manifest.json`. Installation discloses its capability and transformations and stores the exact reviewed manifest, initially disabled. Enabling makes commands available in the manager; execution still requires an explicit user action. Disable prevents command use and uninstall removes the manifest. Opening a document or project never installs, enables or runs an extension.

Manifests are limited to 64 KiB and 32 commands. The private catalog supports at most 64 extensions and 4 MiB of serialized data. Unsupported versions/capabilities, unknown fields, invalid values, duplicate IDs, symlink files, malformed storage and unsafe storage permissions produce explicit errors. Existing incompatible or corrupt catalogs are never silently replaced. The catalog lives in the state directory's `Extensions` subdirectory with 0700 directory and 0600 file permissions; names and IDs are not filesystem paths. `THEONLYPAD_STATE_DIRECTORY` also applies to extension state.

The trust boundary is a bounded parser plus an allowlist of built-in transformations. This is not a general code sandbox or a process-isolation system. An enabled command can change document text when invoked; the editor integration supplies its normal undo behavior. Extensions cannot request file, network or process access through this API. Another process running as the same user can modify local state; private permissions do not authenticate against that user. In-process catalog mutations are serialized, while arbitrary external writers retain the documented filesystem comparison/rename race.

The sample and implementation are original code/data covered by the repository MIT license. No third-party plugin asset or runtime was adopted.
