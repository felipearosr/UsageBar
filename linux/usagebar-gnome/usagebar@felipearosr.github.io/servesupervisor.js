// Serve child lifecycle, independent of GJS so races can be tested without timers.
const HEALTHY_SECS = 30;
const KILL_GRACE_SECS = 3;

export class ServeSupervisor {
    // deps: pickPort(), spawn(argv) -> {wait(cb), terminate(), kill()},
    // addTimeout(seconds, cb), removeTimeout(id), now() in milliseconds.
    constructor(binary, interval, onState, deps, requestTimeoutSecs) {
        this._binary = binary;
        this._interval = interval;
        this._onState = onState;
        this._deps = deps;
        this._requestTimeoutSecs = requestTimeoutSecs;
        this._enabled = false;
        this._proc = null;
        this._restartId = 0;
        this._backoff = 2;
        this._killIds = new Map();
        this.port = 0;
    }

    restart(interval) {
        this._interval = interval;
        this.stop();
        this.start();
    }

    start() {
        if (this._enabled)
            return;
        this._enabled = true;
        this._spawn();
    }

    _spawn() {
        this.port = 0;
        try {
            this.port = this._deps.pickPort();
        } catch (e) {
            this._onState(null, `no free loopback port: ${e.message}`);
            this._scheduleRestart();
            return;
        }
        let proc;
        try {
            proc = this._deps.spawn([
                this._binary, 'serve',
                '--port', String(this.port),
                '--refresh-interval', String(this._interval),
                '--request-timeout', String(this._requestTimeoutSecs),
            ]);
        } catch (e) {
            this.port = 0;
            this._onState(null, `failed to start codexbar serve: ${e.message}`);
            this._scheduleRestart();
            return;
        }
        const spawnedAt = this._deps.now();
        this._proc = proc;
        proc.wait(() => {
            // Clean up this child's timer even if a restart has replaced it.
            const killId = this._killIds.get(proc);
            if (killId) {
                this._deps.removeTimeout(killId);
                this._killIds.delete(proc);
            }
            if (this._proc !== proc)
                return;
            this._proc = null;
            this.port = 0;
            if (this._enabled) {
                if (this._deps.now() - spawnedAt >= HEALTHY_SECS * 1000)
                    this._backoff = 2;
                this._onState(null, 'codexbar serve exited — restarting…');
                this._scheduleRestart();
            }
        });
        // Readiness is handled by the fetch retry loop, not a /health gate.
        this._onState(this.port, '');
    }

    _scheduleRestart() {
        if (!this._enabled || this._restartId)
            return;
        this._restartId = this._deps.addTimeout(this._backoff, () => {
            this._restartId = 0;
            this._backoff = Math.min(this._backoff * 2, 30);
            if (this._enabled)
                this._spawn();
        });
    }

    stop() {
        this._enabled = false;
        this.port = 0;
        if (this._restartId) {
            this._deps.removeTimeout(this._restartId);
            this._restartId = 0;
        }
        const proc = this._proc;
        if (!proc || this._killIds.has(proc))
            return;
        proc.terminate();
        // Each retiring child owns its timer, including across rapid restarts.
        // These sources may outlive disable() by up to 3 s intentionally;
        // a child's exit callback removes its timer as soon as it exits.
        const killId = this._deps.addTimeout(KILL_GRACE_SECS, () => {
            this._killIds.delete(proc);
            proc.kill();
        });
        this._killIds.set(proc, killId);
    }
}
