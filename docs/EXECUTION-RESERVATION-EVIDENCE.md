# Thrown entry points release execution reservations

The acquired-interface path exposed a generic bookkeeping deficiency: argument
validation can throw after the engine reserves an active execution but before
the host returns a record. Active reservations deliberately do not expire while
callbacks may own them, so these abandoned entries consumed capacity forever.

Both `run` and `begin` now release an active reservation when the provider entry
point throws. The retained record says `unknown`, with unverified error evidence;
an arbitrary callback may have dispatched before throwing. An already terminal
record is preserved, and the original error still reaches the caller. There is
no provider-specific cleanup layer.

The same frozen throwing-reflector test ran before and after the fix. Before,
six rejected calls left six active reservations and six assertions failed. After,
both engine entry points preserve the error while active count returns to its
baseline after every call. The full-capacity zero-dispatch control also passes.
Logs are retained under `evidence/universal-execution-20261007/` as
`reservation-throw-red.log` and `reservation-throw-green.log`.

This primitive benefits malformed interface arguments, failed local clients and
throwing network transports across every substrate. It proves bookkeeping
cleanup; it does not establish whether an arbitrary throwing provider had an
external effect, durable history, or final eleven-substrate acceptance.
