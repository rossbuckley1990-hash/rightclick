# Native fixture journal framing repair

The original Windows run failed naturally in the credential-reflection causal test while decoding its multi-record journal. This directory records a test/evidence reader repair, not a new product runtime capability. The original raw output is retained privately and only its hash and case identity are published here.

The local synthetic CRLF reproduction shows the prior Character split combines two objects into one undecodable row. The shared byte reader returns both exact objects. Six XCTest controls pass on macOS; they cover LF/CRLF/mixed endings, final records, malformed/blank framing, strict object decoding, Unicode payloads, private-error suppression, missing journals and real read failures.

Nine existing journal readers now propagate failures rather than crashing or treating malformed evidence as zero effects. Existing assertion values and test names remain; six additional tests strengthen the evidence boundary. Production Sources are untouched. Full integrated adopter suites and the repaired native Windows full suite remain pending. This evidence does not prove release readiness, Windows acquisition, or eleven-substrate acceptance.
