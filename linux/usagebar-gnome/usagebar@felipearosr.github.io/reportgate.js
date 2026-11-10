// Startup sequencing for /usage: on the first poll after serve (re)starts,
// with no capability report known yet, /usage waits for /health so it asks
// for the right rows once (accounts=all or plain) instead of plain rows now
// and account rows a moment later.
//
// The wait is one fixed window (WAIT_MS) from the first /usage that waits.
// Only a successful /health or the end of that window lets /usage go. A
// failed /health (serve reports its port before it listens, so the first
// ones are often refused) is retried after RETRY_MS while the window is
// open; retries never move the window. Dependency-free and clock-free (the
// caller passes `now` and runs the timers) so the Node tests drive it.
//
// Every method returns actions for the caller to run, in order:
//   {type: 'health'}           send GET /health, then call healthResult()
//   {type: 'window', ms}       call windowClosed() after ms
//   {type: 'retry', ms}        call retryDue() after ms
//   {type: 'cancelTimers'}     drop the window and retry timers
//   {type: 'usage'}            send the /usage that was waiting

export const WAIT_MS = 2000;
export const RETRY_MS = 250;

export class ReportGate {
    constructor() {
        this.reset();
    }

    // Serve (re)started: wait again on the next poll.
    reset() {
        this.windowEndsAt = null;
        this.released = false;
        this.waiting = false;
        this.healthInFlight = false;
        this.retryPending = false;
    }

    // A /usage wants to go. [{type: 'usage'}] once the gate is open.
    request(now) {
        if (this.released)
            return [{type: 'usage'}];
        const actions = [];
        this.waiting = true;
        if (this.windowEndsAt === null) {
            this.windowEndsAt = now + WAIT_MS;
            actions.push({type: 'window', ms: WAIT_MS});
        }
        if (!this.healthInFlight && !this.retryPending) {
            this.healthInFlight = true;
            actions.push({type: 'health'});
        }
        return actions;
    }

    // /health answered (ok) or failed.
    healthResult(ok, now) {
        this.healthInFlight = false;
        if (this.released)
            return [];
        if (ok || now >= this.windowEndsAt)
            return this._release();
        if (!this.waiting)
            return [];
        this.retryPending = true;
        return [{type: 'retry', ms: Math.max(0, Math.min(RETRY_MS, this.windowEndsAt - now))}];
    }

    retryDue(now) {
        this.retryPending = false;
        if (this.released || !this.waiting)
            return [];
        if (now >= this.windowEndsAt)
            return this._release();
        this.healthInFlight = true;
        return [{type: 'health'}];
    }

    windowClosed() {
        return this.released ? [] : this._release();
    }

    _release() {
        this.released = true;
        this.retryPending = false;
        const actions = [{type: 'cancelTimers'}];
        if (this.waiting)
            actions.push({type: 'usage'});
        this.waiting = false;
        return actions;
    }
}
