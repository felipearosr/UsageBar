#!/usr/bin/env node
// Reference implementation of the Machine Sync v1 crypto and Pairing Link rules
// (docs/machine-sync-protocol.md §2, §3, §5.1). It exists to generate vectors.json
// and uses only node:crypto, so anyone can rerun it without installing anything.
//
//   node docs/machine-sync-test-vectors/reference.mjs          # rewrite vectors.json
//   node docs/machine-sync-test-vectors/reference.mjs --check  # fail if vectors.json is stale
import { createCipheriv, createDecipheriv, createHash, hkdfSync } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const PROTOCOL_LABEL = 'codexbar-sync/v1';
const ENVELOPE_VERSION = 0x01;
const NONCE_BYTES = 12;
const HEADER_BYTES = 1 + NONCE_BYTES;
const TAG_BYTES = 16;
const PAD_BLOCK = 1024;
const ROOT_KEY_BYTES = 32;

// MARK: - Key derivation (§3)

export function hkdfSha256({ ikm, salt, info, length }) {
    return Buffer.from(hkdfSync('sha256', ikm, salt, info, length));
}

export function deriveKeys(rootKey) {
    const salt = Buffer.from(PROTOCOL_LABEL, 'utf8');
    const derive = (info, length) => hkdfSha256({ ikm: rootKey, salt, info: Buffer.from(info, 'utf8'), length });
    return {
        groupId: derive('group-id', 16),
        authKey: derive('auth', 32),
        encKey: derive('enc', 32),
    };
}

// MARK: - Envelope (§5.1)

export function associatedData({ groupId, machineId, name }) {
    return Buffer.from(`${PROTOCOL_LABEL}|${groupId}|${machineId}|${name}`, 'utf8');
}

export function pad(plaintext) {
    const length = Math.ceil(plaintext.length / PAD_BLOCK) * PAD_BLOCK;
    const padded = Buffer.alloc(length);
    plaintext.copy(padded);
    return padded;
}

export function unpad(padded) {
    let end = padded.length;
    while (end > 0 && padded[end - 1] === 0x00) end -= 1;
    return padded.subarray(0, end);
}

export function sealEnvelope({ encKey, nonce, aad, plaintext }) {
    const cipher = createCipheriv('chacha20-poly1305', encKey, nonce, { authTagLength: TAG_BYTES });
    cipher.setAAD(aad, { plaintextLength: plaintext.length });
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    return Buffer.concat([Buffer.from([ENVELOPE_VERSION]), nonce, ciphertext, cipher.getAuthTag()]);
}

export function openEnvelope({ encKey, aad, envelope }) {
    if (envelope.length < HEADER_BYTES + TAG_BYTES) throw new Error('envelope too short');
    if (envelope[0] !== ENVELOPE_VERSION) throw new Error(`unsupported envelope version ${envelope[0]}`);
    const nonce = envelope.subarray(1, HEADER_BYTES);
    const ciphertext = envelope.subarray(HEADER_BYTES, envelope.length - TAG_BYTES);
    const tag = envelope.subarray(envelope.length - TAG_BYTES);
    const decipher = createDecipheriv('chacha20-poly1305', encKey, nonce, { authTagLength: TAG_BYTES });
    decipher.setAAD(aad, { plaintextLength: ciphertext.length });
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

// MARK: - Pairing Link (§2)

export class PairingLinkError extends Error {
    constructor(code, message) {
        super(message);
        this.name = 'PairingLinkError';
        this.code = code;
    }
}

const TRANSPORTS = { 'codexbar-sync': 'https', 'codexbar-sync+http': 'http' };
const LINK_PATTERN = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(?:#(.*))?$/;
const AUTHORITY_PATTERN = /^(\[[0-9A-Fa-f:.]+\]|[^:[\]]*)(?::([^:]*))?$/;
const HOST_PATTERN = /^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)$/;

function isLoopback(host) {
    const lower = host.toLowerCase();
    return lower === 'localhost' || lower === '[::1]' || /^127(\.\d{1,3}){3}$/.test(lower);
}

export function parsePairingLink(link) {
    const match = LINK_PATTERN.exec(link);
    if (!match) throw new PairingLinkError('unsupported_scheme', 'not a codexbar-sync link');
    const [, scheme, authority, rawPath, query, fragment] = match;
    const transport = TRANSPORTS[scheme.toLowerCase()];
    if (!transport) throw new PairingLinkError('unsupported_scheme', `unsupported scheme ${scheme}`);
    if (query !== undefined) throw new PairingLinkError('unexpected_query', 'pairing links carry no query');

    const [, host, rawPort] = AUTHORITY_PATTERN.exec(authority) ?? [];
    if (host === '') throw new PairingLinkError('missing_host', 'pairing link has no host');
    if (!host || !HOST_PATTERN.test(host)) throw new PairingLinkError('invalid_host', `invalid host ${authority}`);
    let port = null;
    if (rawPort !== undefined) {
        const isValidPort = /^\d{1,5}$/.test(rawPort) && Number(rawPort) >= 1 && Number(rawPort) <= 65535;
        if (!isValidPort) throw new PairingLinkError('invalid_port', `invalid port ${rawPort}`);
        port = Number(rawPort);
    }

    if (!fragment) throw new PairingLinkError('missing_root_key', 'pairing link has no root key');
    if (!/^[A-Za-z0-9_-]{43}$/.test(fragment)) {
        throw new PairingLinkError('invalid_root_key', 'root key must be 43 base64url characters');
    }
    const rootKey = Buffer.from(fragment, 'base64url');
    if (rootKey.length !== ROOT_KEY_BYTES || rootKey.toString('base64url') !== fragment) {
        throw new PairingLinkError('invalid_root_key', 'root key is not the canonical encoding of 32 bytes');
    }

    const basePath = rawPath.replace(/\/+$/, '');
    const baseURL = `${transport}://${host}${port === null ? '' : `:${port}`}${basePath}`;
    return {
        transport,
        host,
        port,
        basePath,
        baseURL,
        apiBaseURL: `${baseURL}/v1`,
        rootKey: rootKey.toString('hex'),
        groupId: deriveKeys(rootKey).groupId.toString('base64url'),
        cleartextWarning: transport === 'http' && !isLoopback(host),
    };
}

// MARK: - Vectors

const sequentialBytes = (start, count) => Buffer.from(Array.from({ length: count }, (_, i) => (start + i) & 0xff));

const ROOT_KEY = sequentialBytes(0x00, 32);
const MACHINE_ID = sequentialBytes(0xa0, 16).toString('base64url');
const OTHER_MACHINE_ID = sequentialBytes(0xb0, 16).toString('base64url');
const GROUP_MACHINE_ID = 'group';

function dayBucket(hour, overrides = {}) {
    return {
        hour,
        provider: 'claude',
        model: 'claude-sonnet-5',
        costUSD: 1.84,
        inputTokens: 12040,
        outputTokens: 3310,
        cacheReadTokens: 402113,
        cacheCreationTokens: 18220,
        totalTokens: 435683,
        requests: 41,
        ...overrides,
    };
}

function exactBlockProfile() {
    const profile = {
        v: 1,
        displayName: '',
        platform: 'macos',
        clientVersion: '0.24.0',
        coverageStart: '2026-01-02',
        pushedAt: '2026-09-23T14:05:40Z',
    };
    profile.displayName = 'x'.repeat(PAD_BLOCK - Buffer.byteLength(JSON.stringify(profile)));
    return profile;
}

const BLOBS = [
    {
        description: 'profile blob from §5.2',
        machineId: MACHINE_ID,
        name: 'profile',
        nonce: sequentialBytes(0x10, 12),
        body: {
            v: 1,
            displayName: 'laptop',
            platform: 'linux',
            clientVersion: '0.24.0',
            coverageStart: '2026-06-25',
            pushedAt: '2026-09-23T14:05:12Z',
        },
    },
    {
        description: 'day blob from §5.2 (one Spend Bucket, pads to 1 KiB)',
        machineId: MACHINE_ID,
        name: 'day-2026-09-23',
        nonce: sequentialBytes(0x20, 12),
        body: { v: 1, buckets: [dayBucket(14)] },
    },
    {
        description: 'day blob larger than 1 KiB (pads to 2 KiB); costUSD omitted where pricing is unknown',
        machineId: MACHINE_ID,
        name: 'day-2026-09-22',
        nonce: sequentialBytes(0x30, 12),
        body: {
            v: 1,
            buckets: [
                dayBucket(0),
                dayBucket(1, { provider: 'codex', model: 'gpt-5-codex', costUSD: 0.62 }),
                dayBucket(9, { costUSD: 3.07, requests: 88 }),
                dayBucket(9, { provider: 'codex', model: 'gpt-5-codex', costUSD: 0.19 }),
                { hour: 13, provider: 'pi', model: 'fictional-model-a', inputTokens: 900, outputTokens: 120, requests: 2 },
                dayBucket(17, { model: 'claude-opus-4-1', costUSD: 11.5 }),
                dayBucket(23, { costUSD: 0.04, requests: 1 }),
            ],
        },
    },
    {
        description: 'profile blob whose JSON is exactly 1024 bytes, so it gets no padding',
        machineId: OTHER_MACHINE_ID,
        name: 'profile',
        nonce: sequentialBytes(0x50, 12),
        body: exactBlockProfile(),
    },
    {
        description: 'group retired blob from §5.3 (machine-id = group)',
        machineId: GROUP_MACHINE_ID,
        name: 'retired',
        nonce: sequentialBytes(0x40, 12),
        body: { v: 1, machines: { [OTHER_MACHINE_ID]: { retiredAt: '2026-09-01T10:00:00Z' } } },
    },
];

// Sets the two unused low bits of the last character, which a lenient decoder ignores.
function nonCanonical(keyText) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    return keyText.slice(0, -1) + alphabet[alphabet.indexOf(keyText.at(-1)) | 0b01];
}

function linkCases(rootKeyText) {
    const valid = [
        ['codexbar-sync://sync.example.com', 'https, host only'],
        ['codexbar-sync://sync.example.com:8443/codexbar', 'https with port and base path'],
        ['codexbar-sync://sync.example.com/codexbar/', 'trailing slash on the base path is dropped'],
        ['codexbar-sync+http://127.0.0.1:8787', 'plain http on IPv4 loopback, no warning'],
        ['codexbar-sync+http://[::1]:8787', 'plain http on IPv6 loopback, no warning'],
        ['codexbar-sync+http://localhost', 'plain http on localhost, no warning'],
        ['codexbar-sync+http://nas.tail1234.ts.net:8787', 'plain http on a non-loopback host must warn before use'],
        ['CODEXBAR-SYNC://sync.example.com', 'the scheme is case-insensitive'],
    ];
    const invalid = [
        ['codexbar-sync://sync.example.com', 'no fragment', 'missing_root_key'],
        ['codexbar-sync://sync.example.com#', 'empty fragment', 'missing_root_key'],
        [`codexbar-sync://sync.example.com#${rootKeyText.slice(0, 42)}`, 'key one character short', 'invalid_root_key'],
        [`codexbar-sync://sync.example.com#${rootKeyText.slice(0, 20)}`, 'key far too short', 'invalid_root_key'],
        [`codexbar-sync://sync.example.com#${rootKeyText}A`, 'key one character long', 'invalid_root_key'],
        [`codexbar-sync://sync.example.com#${rootKeyText}=`, 'key with base64 padding', 'invalid_root_key'],
        [
            `codexbar-sync://sync.example.com#${rootKeyText.slice(0, 41)}+/`,
            'key in standard base64 alphabet',
            'invalid_root_key',
        ],
        [
            `codexbar-sync://sync.example.com#${nonCanonical(rootKeyText)}`,
            'key whose unused trailing bits are not zero (non-canonical encoding of the same bytes)',
            'invalid_root_key',
        ],
        [`https://sync.example.com#${rootKeyText}`, 'https scheme instead of codexbar-sync', 'unsupported_scheme'],
        [`codexbar-sync+https://sync.example.com#${rootKeyText}`, 'unknown transport suffix', 'unsupported_scheme'],
        [`codexbar-sync://#${rootKeyText}`, 'no host', 'missing_host'],
        [`codexbar-sync://:8443#${rootKeyText}`, 'port without host', 'missing_host'],
        [`codexbar-sync://user@sync.example.com#${rootKeyText}`, 'userinfo before the host', 'invalid_host'],
        [`codexbar-sync://sync example.com#${rootKeyText}`, 'space in the host', 'invalid_host'],
        [`codexbar-sync://sync.example.com:0#${rootKeyText}`, 'port 0', 'invalid_port'],
        [`codexbar-sync://sync.example.com:65536#${rootKeyText}`, 'port above 65535', 'invalid_port'],
        [`codexbar-sync://sync.example.com:84a3#${rootKeyText}`, 'port with a non-digit', 'invalid_port'],
        [`codexbar-sync://sync.example.com?group=x#${rootKeyText}`, 'query string', 'unexpected_query'],
    ];
    return {
        valid: valid.map(([prefix, description]) => {
            const link = `${prefix}#${rootKeyText}`;
            return { description, link, result: parsePairingLink(link) };
        }),
        invalid: invalid.map(([link, description, error]) => ({ description, link, error })),
    };
}

export function buildVectors() {
    const keys = deriveKeys(ROOT_KEY);
    const groupId = keys.groupId.toString('base64url');
    const authKeyHash = createHash('sha256').update(keys.authKey).digest();
    const rootKeyText = ROOT_KEY.toString('base64url');

    const envelopes = BLOBS.map((blob) => {
        const plaintext = Buffer.from(JSON.stringify(blob.body), 'utf8');
        const paddedPlaintext = pad(plaintext);
        const aad = associatedData({ groupId, machineId: blob.machineId, name: blob.name });
        const envelope = sealEnvelope({ encKey: keys.encKey, nonce: blob.nonce, aad, plaintext: paddedPlaintext });
        return {
            description: blob.description,
            machineId: blob.machineId,
            name: blob.name,
            nonce: blob.nonce.toString('hex'),
            associatedData: aad.toString('utf8'),
            plaintext: plaintext.toString('utf8'),
            paddedPlaintext: paddedPlaintext.toString('hex'),
            ciphertext: envelope.subarray(HEADER_BYTES).toString('hex'),
            envelope: envelope.toString('base64'),
        };
    });

    const day = envelopes.find((blob) => blob.name === 'day-2026-09-23');
    const flipped = Buffer.from(day.envelope, 'base64');
    flipped[HEADER_BYTES] ^= 0x01;
    const tamperedEnvelopes = [
        {
            description: 'day envelope replayed under another machine ID (AAD mismatch)',
            associatedData: associatedData({ groupId, machineId: OTHER_MACHINE_ID, name: day.name }).toString('utf8'),
            envelope: day.envelope,
        },
        {
            description: 'day envelope replayed under another day name (AAD mismatch)',
            associatedData: associatedData({ groupId, machineId: MACHINE_ID, name: 'day-2026-09-24' }).toString('utf8'),
            envelope: day.envelope,
        },
        {
            description: 'day envelope replayed into another Sync Group (AAD mismatch)',
            associatedData: associatedData({
                groupId: sequentialBytes(0xc0, 16).toString('base64url'),
                machineId: MACHINE_ID,
                name: day.name,
            }).toString('utf8'),
            envelope: day.envelope,
        },
        {
            description: 'day envelope with the first ciphertext bit flipped',
            associatedData: day.associatedData,
            envelope: flipped.toString('base64'),
        },
    ];

    return {
        description: 'Machine Sync v1 test vectors. Generated by reference.mjs in this directory; do not edit by hand.',
        spec: '../machine-sync-protocol.md',
        encoding: {
            bytes: 'Raw byte strings are lowercase hex unless the field name says otherwise.',
            envelope: 'Envelopes are standard base64 with padding, as in the changes response body (§6.5).',
            associatedData: 'UTF-8 text, fed to ChaCha20-Poly1305 as its bytes.',
            plaintext: 'The JSON written by the reference implementation, before padding. Readers need not reproduce it byte for byte.',
        },
        rootKey: { hex: ROOT_KEY.toString('hex'), base64url: rootKeyText },
        keys: {
            groupId: keys.groupId.toString('hex'),
            groupIdBase64url: groupId,
            authKey: keys.authKey.toString('hex'),
            authorizationHeader: `Bearer ${keys.authKey.toString('base64url')}`,
            authKeyHash: authKeyHash.toString('hex'),
            authKeyHashBase64url: authKeyHash.toString('base64url'),
            encKey: keys.encKey.toString('hex'),
        },
        envelopes,
        tamperedEnvelopes,
        pairingLinks: linkCases(rootKeyText),
    };
}

// MARK: - CLI

const VECTORS_PATH = fileURLToPath(new URL('./vectors.json', import.meta.url));

function main(argv) {
    const rendered = `${JSON.stringify(buildVectors(), null, 2)}\n`;
    if (argv.includes('--check')) {
        let current = '';
        try {
            current = readFileSync(VECTORS_PATH, 'utf8');
        } catch {}
        if (current !== rendered) {
            console.error('vectors.json is stale; run node docs/machine-sync-test-vectors/reference.mjs');
            process.exit(1);
        }
        console.log('machine sync vectors OK');
        return;
    }
    writeFileSync(VECTORS_PATH, rendered);
    console.log(`wrote ${VECTORS_PATH}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
