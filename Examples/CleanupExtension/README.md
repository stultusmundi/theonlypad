# Cleanup example extension

This original MIT-licensed manifest exposes three existing text transformations. Open Local Extensions, choose Install, select `manifest.json`, review the capability disclosure and install it disabled. Select the installed extension and enable it. Choose a command and run it against a synthetic editor document. Disable it to remove command access; uninstall to remove its catalog entry.

For example, trimming `hello  ` followed by a newline and `world` followed by a tab produces `hello` followed by a newline and `world`. Sorting and deduplication use the application's existing line-transform behavior and native undo integration.

There is no JavaScript, shell command, dynamic library, network access or project-open hook in this extension. The manifest is copied into private application state when installed. Editing this source file afterward does not change the installed copy. See `docs/extensions.md` for the supported schema and trust boundary.
