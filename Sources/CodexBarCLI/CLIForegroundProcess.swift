import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Interactive child in the terminal's foreground process group

/// Runs an interactive command (a login flow) in the caller's terminal, the way `system(3)` does, minus the shell.
///
/// Foundation's `Process` on Linux always starts the child in a new process group. That group is not the terminal's
/// foreground group, so a child that reads the terminal or switches it to raw mode (`claude auth login`, `codex
/// login`) is stopped by SIGTTIN/SIGTTOU and the caller waits forever. This runner uses `posix_spawn` without
/// `POSIX_SPAWN_SETPGROUP`, so the child stays in the caller's group and owns the terminal like any shell command.
///
/// While the child runs, the caller ignores SIGINT and SIGQUIT and the child gets them back at their defaults
/// (`POSIX_SPAWN_SETSIGDEF`): Ctrl-C stops the child, and the caller lives on to report it (status 128 + signal).
/// The child also starts with an empty signal mask (`POSIX_SPAWN_SETSIGMASK`): `posix_spawn` otherwise copies the
/// calling thread's mask, and Swift concurrency's worker threads on Linux block SIGINT, SIGQUIT, SIGHUP and SIGTERM,
/// which would leave a child that doesn't reset its own mask (Python's `cswap`) deaf to Ctrl-C and to the terminal
/// closing.
/// The child inherits the given environment and the caller's stdin, stdout and stderr. No shell is involved.
enum CLIForegroundProcess {
    enum LaunchError: Error, Equatable {
        case spawnFailed(Int32)
    }

    /// Runs `executable` with `arguments` to completion and returns its exit status, or 128 + the signal that
    /// ended it. Throws when it can't start.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Int32
    {
        #if canImport(Darwin)
        var attr: posix_spawnattr_t?
        #else
        var attr = posix_spawnattr_t()
        #endif
        guard posix_spawnattr_init(&attr) == 0 else { throw LaunchError.spawnFailed(errno) }
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGQUIT)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attr, &unblocked)
        // Deliberately no POSIX_SPAWN_SETPGROUP: the child must stay in the terminal's foreground group.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var cArgs: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        cArgs.append(nil)
        defer {
            for arg in cArgs {
                free(arg)
            }
        }
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for entry in cEnv {
                free(entry)
            }
        }

        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, previousInterrupt)
            signal(SIGQUIT, previousQuit)
        }

        var pid: pid_t = 0
        let result = executable.withCString { path in
            posix_spawn(&pid, path, nil, &attr, cArgs, cEnv)
        }
        guard result == 0 else { throw LaunchError.spawnFailed(result) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw LaunchError.spawnFailed(errno) }
        }
        return self.exitCode(fromWaitStatus: status)
    }

    /// `WIFEXITED`/`WEXITSTATUS`/`WTERMSIG`, which Swift doesn't import as functions.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
