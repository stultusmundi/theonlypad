# Intel cross-compilation

On 2026-09-10, source checkpoint `6c7fb68` built successfully for Intel using the installed Swift 6.3.3 toolchain on Apple Silicon. The source was the same isolated committed archive used for the pane-persistence package; ongoing recovery-close/model changes were excluded.

From that checkout:

```sh
scripts/swift.sh build --configuration release --product TheOnlyPad --triple x86_64-apple-macosx14.0 --scratch-path .build/intel-crosscheck
file .build/intel-crosscheck/x86_64-apple-macosx/release/TheOnlyPad
xcrun vtool -show-build .build/intel-crosscheck/x86_64-apple-macosx/release/TheOnlyPad
```

The release build exited 0 in 25.69 seconds. `file` identified a Mach-O 64-bit x86_64 executable; the build load command reports macOS platform, minimum OS 14.0 and SDK 26.5. Private log: `.local/intel-cross-build.log`; isolated source/output: `.local/pane-package-source/`.

This establishes cross-compilation with this toolchain, not Intel runtime compatibility. No Intel or Rosetta execution, Intel app packaging, minimum-OS runtime, universal bundle or Intel performance measurement was performed. The current `dist/` package remains ARM64. Later source changes need their own cross-build verification.
