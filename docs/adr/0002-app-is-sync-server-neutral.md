# The app is neutral about which Sync Server it uses

Machine Sync is meant to go upstream to CodexBar, while a paid hosted Sync Server will also be offered. The app therefore names and promotes no particular server. Creating a Sync Group asks for a server URL and an optional Enrollment Token, and nothing more. The hosted plan is an external website that issues a URL and token after payment, and self-hosters enter their own URL. The Sync Group key is always created on the Machine, so no server, hosted or self-hosted, takes part in key handling.

## Considered Options

- **Built-in server list with the hosted plan preselected.** It would be easier for users, but upstream would be promoting one operator's paid service, which is unlikely to get maintainer sign-off.
