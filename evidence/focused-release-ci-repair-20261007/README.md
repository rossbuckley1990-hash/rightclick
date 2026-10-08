# Focused release repair checks

The complete macOS native suite passed 967 tests, 35 existing skips and no failures after the credential fixture used the shared numeric loopback server. The manifest records the checked production and fixture bytes. Only the existing OpenAPI credential-return gate and gRPC wire bounds repair change production source.

Historical Windows CI is CANCELLED/RED. Its last visible output follows compilation at 20:08:31 UTC; normal cancellation occurred at 21:12:37 UTC. The protected-reference selection passed first. Buffered output prevents a claim that no tests started or that a particular test deadlocked. Fresh platform CI is required. The replacement workflow retains full test selections, adds bounded discovery/integrated phases, and always uploads diagnostic output.

Compressed artifacts are lossless; both compressed and original digests are retained. Candidate package alignment and public bottle alignment are separate required checks. Public alignment remains RED until accepted published bytes, the tap, the matching new bottle and a fresh installation align.
