import CodexBarCore
import Foundation

extension CodexBarCLI {
    static func cardsHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar cards [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                        [--provider \(ProviderHelp.list)]
                        [--account <label>] [--account-index <index>] [--all-accounts]
                        [--no-credits] [--no-color] [--status] [--source <auto|web|cli|oauth|api>]
                        [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug] [--augment-debug]
                        [--brief]

        Description:
          Print a one-shot usage snapshot as a responsive card grid in the terminal.
          Honors enabled providers from config and reuses the same fetch flags as codexbar usage.
          Failed providers are summarized in a footer instead of error cards.
          Use --brief for a compact table layout (Provider / Usage / Reset).
          Stdout is always the rendered card/table text; --json-output only affects stderr logs.

        Global flags:
          -h, --help      Show help
          -V, --version   Show version
          -v, --verbose   Enable verbose logging
          --no-color      Disable ANSI colors in text output
          --log-level <trace|verbose|debug|info|warning|error|critical>
          --json-output   Emit machine-readable logs (JSONL) to stderr

        Examples:
          codexbar cards
          codexbar cards --provider codex
          codexbar cards --provider all --status
          codexbar cards --brief
          codexbar cards --no-color
        """
    }

    static func usageHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar usage [--format text|json]
                       [--json]
                       [--json-only]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                       [--provider \(ProviderHelp.list)]
                       [--account <label>] [--account-index <index>] [--all-accounts]
                       [--no-credits] [--no-color] [--pretty] [--status] [--source <auto|web|cli|oauth|api>]
                       [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug] [--augment-debug]

        Description:
          Print usage from enabled providers as text (default) or JSON. Honors your in-app toggles.
          Output format: use --json (or --format json) for JSON on stdout; use --json-output for JSON logs on stderr.
          Source behavior is provider-specific:
          - Codex: OpenAI web dashboard (usage limits, credits remaining, code review remaining, usage breakdown).
            Auto falls back to Codex CLI only when cookies are missing.
          - Claude: claude.ai API.
            Auto falls back to Claude CLI only when cookies are missing.
          - Kilo: app.kilo.ai API.
            Auto falls back to Kilo CLI when API credentials are missing or unauthorized.
          Token accounts are loaded from the resolved CodexBar config file.
          Use --account or --account-index to select a specific token account.
          Use --all-accounts to fetch every token account, or every visible Codex account for Codex.
          Account selection requires a single provider.

        Global flags:
          -h, --help      Show help
          -V, --version   Show version
          -v, --verbose   Enable verbose logging
          --no-color      Disable ANSI colors in text output
          --log-level <trace|verbose|debug|info|warning|error|critical>
          --json-output   Emit machine-readable logs (JSONL) to stderr

        Examples:
          codexbar usage
          codexbar usage --provider claude
          codexbar usage --provider gemini
          codexbar usage --format json --provider all --pretty
          codexbar usage --provider all --json
          codexbar usage --status
          codexbar usage --provider codex --source web --format json --pretty
        """
    }

    static func costHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar cost [--format text|json]
                       [--json]
                       [--json-only]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                       [--provider \(ProviderHelp.list)]
                       [--no-color] [--pretty] [--refresh] [--days <days>] [--group-by project]

        Description:
          Print local token cost usage from Claude/Codex native logs plus supported pi sessions.
          This does not require web or CLI access and uses cached scan results unless --refresh is provided.

        Examples:
          codexbar cost
          codexbar cost --provider codex --group-by project
          codexbar cost --provider claude --format json --pretty
        """
    }

    static func sessionsHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar sessions [--json] [--pretty]
          codexbar sessions focus <id>

        Description:
          List live local Codex and Claude Code agent sessions.
          JSON uses stable AgentSession field names and ISO-8601 dates.
          Focus activates the owning terminal or desktop app on macOS.

        Examples:
          codexbar sessions
          codexbar sessions --json
          codexbar sessions focus 019f3497-73bf-7df3-a173-4f67d968914a
        """
    }

    static func serveHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar serve [--port <port>] [--refresh-interval <seconds>]
                         [--request-timeout <seconds>]
                         [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                         [-v|--verbose]

        Description:
          Start a foreground localhost-only HTTP server that exposes existing CLI JSON payloads.
          The server binds to 127.0.0.1 only in this initial version.

        Endpoints:
          GET /health
          GET /usage
          GET /usage?provider=claude
          GET /usage?provider=all
          GET /cost
          GET /cost?provider=codex&days=90

        Examples:
          codexbar serve
          codexbar serve --port 8080 --refresh-interval 60 --request-timeout 30
          curl http://127.0.0.1:8080/usage?provider=all
        """
    }

    static func configHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar config validate [--format text|json]
                                 [--json]
                                 [--json-only]
                                 [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                                 [-v|--verbose]
                                 [--pretty]
          codexbar config dump [--format text|json]
                             [--json]
                             [--json-only]
                             [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                             [-v|--verbose]
                             [--pretty]
          codexbar config providers [--format text|json] [--json] [--json-only] [--pretty]
          codexbar config enable --provider <name> [--format text|json] [--json] [--json-only] [--pretty]
          codexbar config disable --provider <name> [--format text|json] [--json] [--json-only] [--pretty]
          codexbar config set-api-key --provider <name> (--api-key <key>|--stdin)
                                    [--label <label>] [--usage-scope team]
                                    [--organization-id <org>] [--workspace-id <project>]
                                    [--no-enable]
                                    [--format text|json] [--json] [--json-only] [--pretty]

        Description:
          Validate or print the CodexBar config file (default: validate).
          providers lists persistent provider enablement.
          enable/disable updates the same provider toggle used by Settings.
          set-api-key stores a provider API key in the resolved config file and enables that provider by default.
          For z.ai team usage, add --usage-scope team with BigModel organization and project IDs; this stores
          the key as a token account instead of a provider-level personal key.

        Examples:
          codexbar config validate --format json --pretty
          codexbar config dump --pretty
          codexbar config providers
          codexbar config enable --provider grok
          codexbar config disable --provider cursor
          printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
          printf '%s' "$Z_AI_API_KEY" | codexbar config set-api-key --provider zai --stdin \\
            --label Team --usage-scope team --organization-id org_... --workspace-id proj_...
        """
    }

    static func cacheHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar cache clear <--cookies|--cost|--all>
                              [--provider <name>]
                              [--format text|json]
                              [--json]
                              [--json-only]
                              [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                              [-v|--verbose]
                              [--pretty]

        Description:
          Clear cached data. Use --cookies to clear browser cookie caches (stored in Keychain),
          --cost to clear cost usage scan caches, or --all for both.
          Optionally specify --provider with --cookies to clear cookies for a single provider only.

        Examples:
          codexbar cache clear --cookies
          codexbar cache clear --cookies --provider claude
          codexbar cache clear --cost
          codexbar cache clear --all
          codexbar cache clear --all --format json --pretty
        """
    }

    static func syncHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar sync create --server <url> [--token <enrollment-token>] [--name <display-name>]
                               [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync push [--format text|json] [--json] [--json-only] [--pretty]

        Description:
          Machine Sync shares each Machine's Spend (local-log cost, tokens, and requests) with your other
          Machines through a Sync Server, end-to-end encrypted. It stays off until you create a Sync Group.

          create  Generates the Sync Group key on this Machine, registers the group on the server (with an
                  Enrollment Token if the server requires one), pushes this Machine's Spend, and prints the
                  Pairing Link. Store the link somewhere safe: it is the recovery key for the group.
          push    Uploads today's and yesterday's UTC Spend plus this Machine's profile, skipping anything
                  unchanged since the last push. Only one push runs at a time per Machine.

        Examples:
          codexbar sync create --server https://sync.example.com --token tok_123 --name laptop
          codexbar sync push
        """
    }

    static func diagnoseHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar diagnose --provider <name|all> --format json
                           [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                           [-v|--verbose]
                           [--redact] [--output <path>]
                           [--pretty]

        Description:
          Run provider diagnostic fetches and print a safe JSON export for issue reporting.
          The export is redacted and omits raw API tokens, cookies, auth headers, emails,
          account IDs, org IDs, raw responses, and billing-history records.

        Examples:
          codexbar diagnose --provider minimax --format json --redact --output diagnostic.json
          codexbar diagnose --provider minimax --format json --pretty
          codexbar diagnose --provider claude --format json --pretty
          codexbar diagnose --provider all --format json
        """
    }

    static func rootHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar [--format text|json]
                  [--json]
                  [--json-only]
                  [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                  [--provider \(ProviderHelp.list)]
                  [--account <label>] [--account-index <index>] [--all-accounts]
                  [--no-credits] [--no-color] [--pretty] [--status] [--source <auto|web|cli|oauth|api>]
                  [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug] [--augment-debug]
          codexbar cards [--provider \(ProviderHelp.list)] [--brief] [--no-color] [--status]
          codexbar cost [--format text|json]
                       [--json]
                       [--json-only]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                       [--provider \(ProviderHelp.list)] [--no-color] [--pretty] [--refresh]
                       [--days <days>] [--group-by project]
          codexbar sessions [--json] [--pretty]
          codexbar sessions focus <id>
          codexbar serve [--port <port>] [--refresh-interval <seconds>]
                       [--request-timeout <seconds>]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
          codexbar config <validate|dump|providers> [--format text|json]
                                        [--json]
                                        [--json-only]
                                        [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                                        [-v|--verbose]
                                        [--pretty]
          codexbar config enable --provider <name>
          codexbar config disable --provider <name>
          codexbar config set-api-key --provider <name> (--api-key <key>|--stdin)
          codexbar config set-api-key --provider zai --stdin --usage-scope team
                                   --organization-id <org> --workspace-id <project>
          codexbar cache clear <--cookies|--cost|--all> [--provider <name>]
          codexbar diagnose --provider <name|all> --format json [--redact] [--output <path>] [--pretty]
          codexbar sync create --server <url> [--token <enrollment-token>] [--name <display-name>]
          codexbar sync push

        Global flags:
          -h, --help      Show help
          -V, --version   Show version
          -v, --verbose   Enable verbose logging
          --no-color      Disable ANSI colors in text output
          --log-level <trace|verbose|debug|info|warning|error|critical>
          --json-output   Emit machine-readable logs (JSONL) to stderr

        Examples:
          codexbar
          codexbar --format json --provider all --pretty
          codexbar --provider all --json
          codexbar --provider gemini
          codexbar cards --provider all --status
          codexbar cards --brief
          codexbar cost --provider claude --format json --pretty
          codexbar sessions --json
          codexbar serve --port 8080
          codexbar config validate --format json --pretty
          codexbar config enable --provider grok
          codexbar config set-api-key --provider elevenlabs --stdin
          codexbar cache clear --cookies
          codexbar diagnose --provider minimax --format json --redact --output diagnostic.json
          codexbar diagnose --provider minimax --format json --pretty
          codexbar diagnose --provider all --format json
        """
    }
}
