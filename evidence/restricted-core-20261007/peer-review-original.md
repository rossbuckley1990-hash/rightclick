# Independent restricted-client broker review

Exact source dfe496b3eda02dca36f37c605b82059c35feab6b, scripts/restricted-core-probe.py SHA25637a2b6ea50221e5f7a8cbd8c363ccd24505e221ff0de5c2b9e606651fc9e6c19. Read-only source review and temporary external diagnostics; no repository edit, real AI request or backend inference.

Confirmed cleanup blocker: RPC.close111-119 persists JSON before any process termination. A controlled save failure left a real diagnostic sleeping child alive. The reviewer then killed that child independently. Use finally to terminate/wait/close independently of persistence; failure remains FAIL.

Catalogue integrity limitation: validate_capture134-143 verifies names only. Parameter schemas and otherToolFields collected by the handler are ignored. A synthetic seven-name record with unrelated required parameters and a shell-bearing unknown tool field passed that validator. The current dynamicToolsSHA pins the input declarations supplied to app-server, while captureCatalogSHA pins captured bytes; no comparison establishes outgoing schema equality. Require normalized schema equality and explicitly reject unknown tool-bearing fields before claiming that equality.

No automatic RPC/phase mutation retry found: RPC.call sends once, timeout propagates to overall incomplete failure; foreign tool namespaces, permissions, thread/turn IDs and completion IDs fail closed. Provider UNKNOWN responses are forwarded; the model instruction says no retry, but the broker itself does not prevent a model choosing a new repeated context_run. This is an explicit enforcement limit, distinct from automatic transport replay.

Host phase commands use fixed operator-authored argv, never model argument interpolation. Exit codes permit continuation only, and semanticAcceptance/universalAcceptance remain NOT_INFERRED/NOT_EVALUATED. Host command timeout cleans the direct process via subprocess.run, but any operator-started descendant/provider lifecycle requires separately owned teardown.

The actualAIInference field currently records requested --actual mode even on failures before inference; result FAIL and explicit no interception prevent universal acceptance claims, but the field should be described as requested mode rather than independent proof that inference occurred. The local catalogue proof is trusted operator evidence, not a signed proof against same-principal filesystem forgery. These limits must remain explicit.
