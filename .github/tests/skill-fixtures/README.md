# Native skill manifest fixture

`pinned-self-improvement/SKILL.md` is the byte-exact manifest produced by native
`gh skill install` from the reviewed marketplace commit
`72f0f4c6a01e6a4ae59ec5297940dd309641de31`, with that commit pinned.
Its recorded repository is the maintained plugin publisher.

This is deliberately a manifest-only fixture, not a complete installed skill.
The tests exercise pin observation, dry-run updates, internal marking and native
pin restoration. Unused ancillary resource copies are omitted; the native pin
test obtains the actual source tree from the recorded publisher and verifies
that a stale local file is removed.
