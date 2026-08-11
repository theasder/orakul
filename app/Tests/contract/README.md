# Contract tests

These verify the Mac app against `contract/contract.json`, a copy of the document
`cruxwing-api` publishes.

They exist because the checks they replace could only work inside a monorepo: they
read Swift source from JavaScript to prove the client and server agreed on the goal
taxonomy, the call themes, and the credit table. Each of those caught a real bug —
four goal contracts the app could never emit, a Swift credit table drifting from
the server's, a landing page advertising a model the catalog no longer served.

Across repositories JavaScript cannot see the server, so the comparison is against
the vendored contract instead. Re-vendor with:

    curl -fsSL <api-repo>/contract/contract.json -o contract/contract.json

CI must fail when the vendored copy differs from the published one — a stale copy
means these tests verify agreement with a server that no longer exists.
