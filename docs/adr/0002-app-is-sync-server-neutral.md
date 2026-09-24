# The app is neutral about which Sync Server it uses

Machine Sync ships in UsageBar only; it is not proposed to CodexBar. A paid hosted Sync Server will be offered alongside self-hosting, and the app names and promotes no particular server. Creating a Sync Group asks for a server URL and an optional Enrollment Token, and nothing more. The hosted plan is an external website that issues a URL and token after payment, and self-hosters enter their own URL. The Sync Group key is always created on the Machine, so no server, hosted or self-hosted, takes part in key handling.

Keeping the app neutral treats self-hosters the same as paying users, and keeps the hosted plan's pricing and availability out of app releases.

## Considered Options

- **Built-in server list with the hosted plan preselected.** It would be easier for users, but it makes self-hosting a second-class path and ties an app release to every change in the hosted plan. This option was first rejected to win CodexBar maintainer sign-off; that reason no longer applies now that Machine Sync stays in UsageBar.
