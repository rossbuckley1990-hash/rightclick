# Independent typed GraphQL peer review

Reviewed PR58 head `9f40589c1fca5e153020c6fa552349fd44c867d8` against baseline `2dd7bd2fafbbaa994812d1bc904730b74aa74816`. Read-only review of the three immutable source copies and exact diff. SHA256s are recorded in source-manifest.json. Unrelated staged integration changes in the original checkout were excluded.

No blocking regression found in the new typed admission, authority, or result boundary. The legacy Unary overload still binds the same closed string schema, same result-string schema, same wire declaration and same host/scopes. The typed overload validates exact input before the same execution host; GraphQL input coercion is repeated and validated before HTTP admission. Typed completion mismatch is handled by the existing host as UNKNOWN after dispatch, with no automatic retry.

The additive integerRange canonical form includes both Int64 bounds and rejects inverted ranges. Existing integer canonical bytes and CapabilityValue integer representation are unchanged. GraphQL Int uses inclusive Int32 boundaries; Float remains finite numeric data. Boolean/integer/enum/object/null/list distinctions stay closed.

Minor new issue: GraphQLReflector.swift lines1113-1116 and2289-2290 inspect recursively unwrapped namedType. Thus nullable [String] and [ID] also advertise the scalar backslash-literal escape. That branch returns a String which the array schema rejects before transport. Limit the guard to a top-level named scalar, or restrict the guidance accordingly. This is conservative rejection and misleading guidance, not broadened execution authority.

Design limits: resultPlan lines2149-2184 binds the actual bounded generated selection, not every field of an arbitrary full GraphQL object. Depth/cycle/first16field restrictions are explicit; interface/union results currently select only __typename and bind it as a string rather than a closed possibleTypes enumeration. Recursive input and unknown custom scalars abstain. These are partial-domain limits and must not be described as complete GraphQL semantic support.

Separate pre-existing hardening concern, not introduced by this change: parseFields/parseInputFields/type names only require nonempty strings, and generated document syntax interpolates those metadata names. Strict GraphQL Name validation and duplicate root-name rejection would make malformed or malicious introspection fail closed. This review did not execute an exploit and does not count that concern as a confirmed new blocker.

Root-provided real HTTP/native results were not independently rerun in this review. They remain attributed evidence, distinct from this source review and from the eleven-world restricted-agent acceptance gate.
