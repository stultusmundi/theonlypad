# Accessibility permission retry

The user explicitly authorized retrying the native permission request after granting access. On 2026-09-10 the existing private probe called `AXIsProcessTrustedWithOptions` again. Its initial trust check was false; the post-request check was true. This establishes permission for this probe identity, not a complete accessibility audit.

The probe launched an isolated copy of the verified development package (`9231fc3`, executable SHA256 `8f5fe6c898b4c60ceff367fefc3ccdd2ad67ef3b89e1b0ce9ea414d5057613de`). It confirmed target ownership and one initial tab. Both File and New Tab accessibility press operations returned success. A subsequent accessibility query failed before the required two-tab and stability postconditions. The root driver correctly rejected that incomplete receipt. The original query did not preserve its exact operation/error value; a diagnostic change is required before attributing the failure to the product or harness.

The owned target terminated normally and cleanup was confirmed. The driver observed probe termination. No system security setting was changed by the agent. An initial sandboxed launch failed; the authorized outside-sandbox retry produced the observations above. Ordinary XCUITest remains separately available and its prior results are unchanged.

Private evidence is retained in `.local/ax-native-probe/actual-granted-retry/` (canonical run `run.bBWZ03`). Probe executable SHA256: `1abd3ba8fb04a99af5d8a5c64b460187c3555a659e6dd1a45c9d53074fc5da91`. Driver SHA256: `299e3f98ad2062ce1abd432c1ee5a9ffc5b22bc1cce21af695e0dd2b85c5c656`.

Status: permission confirmed; File/New end-to-end AX verification outstanding. No VoiceOver, keyboard navigation, contrast, IME or broader accessibility acceptance follows from this check.
