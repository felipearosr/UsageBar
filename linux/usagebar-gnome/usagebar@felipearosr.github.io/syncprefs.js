// Machine Sync page of the preferences: how its actions become `codexbar
// sync …` invocations, and how their JSON answers and errors become plain
// language. Dependency-free so the Node tests can exercise it without GJS.
//
// The Pairing Link is the Sync Group's key. It reaches the CLI on stdin, never
// in argv, and nothing here returns it inside an error or status string.

// The CLI prints only JSON on stdout with this flag, errors included.
const JSON_FLAG = '--json-only';

// ---------- invocations ----------

export function settingsArgs({timeZone, startHour} = {}) {
    const args = ['sync', 'settings'];
    if (timeZone !== undefined)
        args.push('--timezone', timeZone ?? 'system');
    if (startHour !== undefined)
        args.push('--day-start', String(startHour));
    return [...args, JSON_FLAG];
}

export function infoArgs(server) {
    return ['sync', 'info', '--server', server.trim(), JSON_FLAG];
}

export function createArgs({server, token = '', name = '', allowCleartext = false}) {
    const args = ['sync', 'create', '--server', server.trim()];
    if (token.trim())
        args.push('--token', token.trim());
    if (name.trim())
        args.push('--name', name.trim());
    if (allowCleartext)
        args.push('--yes');
    return [...args, JSON_FLAG];
}

// `-` makes the CLI read the link from stdin: pass `pairStdin(link)` there.
export function pairArgs({name = '', allowCleartext = false} = {}) {
    const args = ['sync', 'pair', '-'];
    if (name.trim())
        args.push('--name', name.trim());
    if (allowCleartext)
        args.push('--yes');
    return [...args, JSON_FLAG];
}

// Host of a `codexbar-sync+http://` link, for the plain-http warning; null
// for https links and anything unparseable.
export function cleartextHost(link) {
    const match = /^codexbar-sync\+http:\/\/(\[[^\]]*\]|[^/:#?]+)/i.exec(String(link ?? '').trim());
    return match ? match[1] : null;
}

export function pairStdin(link) {
    return `${link.trim()}\n`;
}

export function linkArgs() {
    return ['sync', 'link', JSON_FLAG];
}

export function renameArgs(name) {
    return ['sync', 'rename', name.trim(), JSON_FLAG];
}

// Machine IDs, not display names: two Machines may share a name.
export function retireArgs(machineId) {
    return ['sync', 'retire', machineId, JSON_FLAG];
}

// Only after the user confirmed in a dialog, hence --yes.
export function forgetArgs(machineId) {
    return ['sync', 'forget', machineId, '--yes', JSON_FLAG];
}

export function leaveArgs() {
    return ['sync', 'leave', '--yes', JSON_FLAG];
}

export function pushArgs() {
    return ['sync', 'push', JSON_FLAG];
}

export function statusArgs() {
    return ['sync', 'status', JSON_FLAG];
}

// ---------- answers ----------

const LINK_PATTERN = /codexbar-sync(\+http)?:\/\/\S+/gi;

// Belt and braces for anything shown or logged: the CLI never puts the link
// in an error, but a server message or a future change could.
export function redactPairingLinks(text) {
    return String(text ?? '').replace(LINK_PATTERN, '[Pairing Link]');
}

// A finished `codexbar sync … --json-only` run → {ok, data} or
// {ok: false, reason, message}. Failures print
// [{"provider":"cli","error":{"message","reason",…}}] on stdout.
export function parseResult({success, stdout = ''}) {
    const text = String(stdout ?? '').trim();
    const start = text.search(/[[{]/);
    let data = null;
    if (start >= 0) {
        try {
            data = JSON.parse(text.slice(start));
        } catch {
            data = null;
        }
    }
    const error = Array.isArray(data) ? data.find(entry => entry?.error)?.error : null;
    if (success && data && !error)
        return {ok: true, data};
    return {
        ok: false,
        reason: error?.reason ?? null,
        message: redactPairingLinks(error?.message ?? ''),
    };
}

// ---------- plain language ----------

const REASONS = {
    enrollment_required: 'This Sync Server only creates Sync Groups with an Enrollment Token. ' +
        'Enter the token you got from its operator.',
    enrollment_invalid: 'The Sync Server didn’t accept this Enrollment Token. ' +
        'Check that you copied all of it and that it is for this server.',
    enrollment_used: 'This Enrollment Token has already created a Sync Group. Each token ' +
        'creates one group. To add this Machine to it, join with that group’s Pairing Link.',
    enrollment_expired: 'The Enrollment Token or this Sync Group has expired. The server no ' +
        'longer accepts new Spend, but it can still be read for a while. Ask the server’s ' +
        'operator to renew it, or move to another server.',
    machine_limit: 'This Sync Group already has as many Machines as its server allows. Forget ' +
        'a Machine you no longer use (retired Machines still count), or ask the server’s ' +
        'operator for a higher limit.',
    group_not_found: 'The Sync Server doesn’t know this Sync Group, or the Pairing Link’s key ' +
        'is wrong. Copy the whole link again from a Machine that is already in the group.',
    unsupported_server: 'This server doesn’t speak Machine Sync protocol v1. Check the address.',
    network: 'Couldn’t reach the Sync Server. Check the address and your connection.',
    rate_limited: 'The Sync Server is busy right now. Try again in a minute.',
    invalid_address: 'That isn’t a Sync Server address. Enter the full URL, starting with ' +
        'https:// (or http:// for a server on your own network).',
    invalid_key: 'This Pairing Link is incomplete. Copy the whole link, including the part after “#”.',
    already_paired: 'This Machine is already in a Sync Group. Leave it before creating or ' +
        'joining another.',
    not_paired: 'This Machine isn’t in a Sync Group.',
    push_in_progress: 'A push is running right now. Try again in a moment.',
    is_this_machine: 'That is this Machine. To take it out of the group, use Leave Sync Group.',
    retired_conflict: 'Other Machines kept changing the retired list at the same time. Try again.',
    invalid_reporting_day: 'That timezone isn’t known on this system.',
    cleartext_not_confirmed: 'Plain http:// needs your confirmation.',
};

// The sentence shown for a failed action. Unknown reasons fall back to the
// CLI's own message, which is already written for people.
export function friendlyError({reason, message} = {}) {
    if (reason && REASONS[reason])
        return REASONS[reason];
    if (reason && /^http_5\d\d$/.test(reason))
        return 'The Sync Server had a problem. Try again later.';
    const text = redactPairingLinks(message).trim();
    return text || 'Something went wrong. Try again.';
}

export function cleartextWarning(host) {
    return `http:// sends this Sync Group’s credential to ${host} unencrypted. Spend stays ` +
        'end-to-end encrypted, but anyone on the network path could change it. Continue only ' +
        `if ${host} is on a private network you trust.`;
}

export const RECOVERY_GUIDANCE =
    'This Pairing Link is the Sync Group’s key and its only recovery key. Store it somewhere ' +
    'safe, such as a password manager. Anyone who has it can read and change the Spend of ' +
    'every Machine in the group, so share it only with your own Machines.';

export const LEAVE_WARNING =
    'This Machine stops syncing and forgets the Pairing Link. Its Spend stays on the Sync ' +
    'Server. To rejoin later you need the Pairing Link from another Machine or your notes.';

export function forgetWarning(label) {
    return `This deletes all of ${label}’s Spend from the Sync Server, for every Machine in ` +
        'the group. It can’t be undone. If it is only gone for now, retire it instead.';
}

// ---------- create form ----------

// §6.2: the token field appears only when the server asks for one.
export function tokenField(info) {
    const enrollment = info?.enrollment;
    if (enrollment === 'required')
        return {visible: true, required: true};
    if (enrollment === 'optional')
        return {visible: true, required: false};
    return {visible: false, required: false};
}

// One line under the server field once `sync info` answered. `operator` is
// the server's own text, shown as-is.
export function serverSummary(info) {
    if (!info)
        return '';
    if (!info.supported)
        return 'This server doesn’t speak Machine Sync protocol v1';
    const parts = [];
    if (info.operator)
        parts.push(info.operator);
    parts.push({
        required: 'Enrollment Token required',
        optional: 'Enrollment Token optional',
    }[info.enrollment] ?? 'No Enrollment Token needed');
    if (info.retentionDays)
        parts.push(`keeps ${info.retentionDays} days`);
    return parts.join(' · ');
}

export function canCreate({info, token = ''}) {
    if (!info?.supported)
        return false;
    return !tokenField(info).required || token.trim().length > 0;
}

// ---------- results ----------

export function createdText(data) {
    const lines = [`Created a Sync Group on ${data.server}.`];
    if (data.pushError)
        lines.push(`The first push failed and will be retried: ${friendlyError({reason: data.pushErrorReason, message: data.pushError})}`);
    return lines.join('\n');
}

export function pairedText(data) {
    if (data.pushError)
        return `Joined. The backfill failed and will be retried: ${friendlyError({reason: data.pushErrorReason, message: data.pushError})}`;
    const days = data.backfilledDays ?? 0;
    return `Joined. Backfilled ${days} ${days === 1 ? 'day' : 'days'} of Spend.`;
}

export function pushText(data) {
    switch (data?.status) {
    case 'pushed':
        return data.uploaded?.length ? 'Synced.' : 'Up to date.';
    case 'locked':
        return 'A push is already running.';
    case 'backing_off':
        return 'Waiting after a sync error before trying again.';
    default:
        return 'Synced.';
    }
}

// ---------- Reporting Day ----------

export function hourLabels() {
    return Array.from({length: 24}, (_, h) => `${String(h).padStart(2, '0')}:00`);
}

// zone1970.tab rows are "CC<TAB>coords<TAB>Zone[<TAB>comments]". Returns the
// sorted zone names plus UTC; the saved zone is kept even when the table
// lacks it.
export function timeZoneChoices(zoneTab, saved = null) {
    const zones = new Set(['UTC']);
    for (const line of String(zoneTab ?? '').split('\n')) {
        if (!line || line.startsWith('#'))
            continue;
        const zone = line.split('\t')[2];
        if (zone)
            zones.add(zone.trim());
    }
    if (saved)
        zones.add(saved);
    return [...zones].sort();
}

export function reportingDaySummary(reportingDay) {
    if (!reportingDay)
        return '';
    const zone = reportingDay.timeZone ?? `system timezone (${reportingDay.effectiveTimeZone})`;
    return `Days start at ${hourLabels()[reportingDay.startHour] ?? '00:00'}, ${zone}`;
}

// ---------- other Machines ----------

// Rows for retire / forget: every Machine but this one, from a `sync status`
// payload.
export function otherMachines(status) {
    return (status?.machines ?? [])
        .filter(machine => !machine.isThisMachine)
        .map(machine => ({
            machineId: machine.machineId,
            label: machine.displayName || machine.machineId,
            retired: !!machine.retired,
            active: !!machine.active,
        }))
        .sort((a, b) => a.label.localeCompare(b.label));
}
