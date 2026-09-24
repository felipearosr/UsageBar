import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import {
    associatedData,
    buildVectors,
    deriveKeys,
    hkdfSha256,
    openEnvelope,
    pad,
    parsePairingLink,
    PairingLinkError,
    sealEnvelope,
    unpad,
} from './reference.mjs';

const hex = (value) => Buffer.from(value.replace(/\s+/g, ''), 'hex');

test('HKDF-SHA256 matches RFC 5869 test case 1', () => {
    const okm = hkdfSha256({
        ikm: hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        salt: hex('000102030405060708090a0b0c'),
        info: hex('f0f1f2f3f4f5f6f7f8f9'),
        length: 42,
    });
    assert.equal(
        okm.toString('hex'),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865');
});

test('ChaCha20-Poly1305 matches RFC 8439 section 2.8.2', () => {
    const plaintext = Buffer.from(
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, "
        + 'sunscreen would be it.');
    const envelope = sealEnvelope({
        encKey: hex('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f'),
        nonce: hex('070000004041424344454647'),
        aad: hex('50515253c0c1c2c3c4c5c6c7'),
        plaintext,
    });
    assert.equal(envelope[0], 0x01);
    assert.equal(envelope.subarray(1, 13).toString('hex'), '070000004041424344454647');
    assert.equal(
        envelope.subarray(13).toString('hex'),
        'd31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b'
        + '1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc'
        + '3ff4def08e4b7a9de576d26586cec64b6116'
        + '1ae10b594f09e26a7e902ecbd0600691');
});

test('keys are derived with the v1 salt and per-output info labels', () => {
    const rootKey = Buffer.alloc(32, 7);
    const keys = deriveKeys(rootKey);
    const salt = Buffer.from('codexbar-sync/v1');
    assert.deepEqual(keys.groupId, hkdfSha256({ ikm: rootKey, salt, info: Buffer.from('group-id'), length: 16 }));
    assert.deepEqual(keys.authKey, hkdfSha256({ ikm: rootKey, salt, info: Buffer.from('auth'), length: 32 }));
    assert.deepEqual(keys.encKey, hkdfSha256({ ikm: rootKey, salt, info: Buffer.from('enc'), length: 32 }));
});

test('associated data binds the base64url group ID, machine ID, and blob name', () => {
    assert.equal(
        associatedData({ groupId: 'G', machineId: 'M', name: 'profile' }).toString('utf8'),
        'codexbar-sync/v1|G|M|profile');
});

test('padding rounds up to the next 1 KiB and leaves exact multiples alone', () => {
    assert.equal(pad(Buffer.from('{}')).length, 1024);
    assert.equal(pad(Buffer.alloc(1024, 0x20)).length, 1024);
    assert.equal(pad(Buffer.alloc(1025, 0x20)).length, 2048);
    assert.deepEqual(unpad(pad(Buffer.from('{"v":1}'))), Buffer.from('{"v":1}'));
});

test('an envelope opens only with the associated data it was sealed with', () => {
    const encKey = Buffer.alloc(32, 1);
    const nonce = Buffer.alloc(12, 2);
    const aad = associatedData({ groupId: 'g', machineId: 'm', name: 'profile' });
    const envelope = sealEnvelope({ encKey, nonce, aad, plaintext: Buffer.from('hello') });
    assert.deepEqual(openEnvelope({ encKey, aad, envelope }), Buffer.from('hello'));
    assert.throws(() => openEnvelope({
        encKey,
        aad: associatedData({ groupId: 'g', machineId: 'other', name: 'profile' }),
        envelope,
    }));
});

test('an envelope with an unknown version byte is rejected', () => {
    const encKey = Buffer.alloc(32, 1);
    const aad = Buffer.from('a');
    const envelope = sealEnvelope({ encKey, nonce: Buffer.alloc(12), aad, plaintext: Buffer.from('x') });
    envelope[0] = 0x02;
    assert.throws(() => openEnvelope({ encKey, aad, envelope }), /version/);
});

test('a secure pairing link maps to https and derives the group', () => {
    const rootKey = Buffer.alloc(32, 9);
    const link = `codexbar-sync://sync.example.com:8443/team/sync#${rootKey.toString('base64url')}`;
    assert.deepEqual(parsePairingLink(link), {
        transport: 'https',
        host: 'sync.example.com',
        port: 8443,
        basePath: '/team/sync',
        baseURL: 'https://sync.example.com:8443/team/sync',
        apiBaseURL: 'https://sync.example.com:8443/team/sync/v1',
        rootKey: rootKey.toString('hex'),
        groupId: deriveKeys(rootKey).groupId.toString('base64url'),
        cleartextWarning: false,
    });
});

test('a plain-http pairing link warns unless the host is loopback', () => {
    const key = Buffer.alloc(32, 3).toString('base64url');
    assert.equal(parsePairingLink(`codexbar-sync+http://127.0.0.1:8080#${key}`).cleartextWarning, false);
    assert.equal(parsePairingLink(`codexbar-sync+http://localhost#${key}`).cleartextWarning, false);
    assert.equal(parsePairingLink(`codexbar-sync+http://[::1]:8080#${key}`).cleartextWarning, false);
    const tailnet = parsePairingLink(`codexbar-sync+http://box.tail1234.ts.net:8080#${key}`);
    assert.equal(tailnet.transport, 'http');
    assert.equal(tailnet.apiBaseURL, 'http://box.tail1234.ts.net:8080/v1');
    assert.equal(tailnet.cleartextWarning, true);
});

test('malformed pairing links are rejected with a reason', () => {
    const key = Buffer.alloc(32, 3).toString('base64url');
    const cases = [
        ['codexbar-sync://sync.example.com', 'missing_root_key'],
        ['codexbar-sync://sync.example.com#', 'missing_root_key'],
        [`codexbar-sync://sync.example.com#${key.slice(0, 42)}`, 'invalid_root_key'],
        [`codexbar-sync://sync.example.com#${key}=`, 'invalid_root_key'],
        [`codexbar-sync://sync.example.com#${key.slice(0, 42)}+`, 'invalid_root_key'],
        [`https://sync.example.com#${key}`, 'unsupported_scheme'],
        [`codexbar-sync://#${key}`, 'missing_host'],
        [`codexbar-sync://sync.example.com?x=1#${key}`, 'unexpected_query'],
    ];
    for (const [link, code] of cases) {
        assert.throws(() => parsePairingLink(link), (error) => {
            assert.ok(error instanceof PairingLinkError, link);
            assert.equal(error.code, code, link);
            return true;
        });
    }
});

test('committed vectors match the reference implementation', () => {
    const committed = JSON.parse(readFileSync(new URL('./vectors.json', import.meta.url), 'utf8'));
    assert.deepEqual(committed, buildVectors());
});

test('every envelope vector opens to its plaintext and every tampered case fails', () => {
    const vectors = buildVectors();
    const encKey = Buffer.from(vectors.keys.encKey, 'hex');
    for (const blob of vectors.envelopes) {
        const opened = openEnvelope({
            encKey,
            aad: Buffer.from(blob.associatedData, 'utf8'),
            envelope: Buffer.from(blob.envelope, 'base64'),
        });
        assert.equal(opened.toString('hex'), blob.paddedPlaintext);
        assert.equal(unpad(opened).toString('utf8'), blob.plaintext);
    }
    assert.ok(vectors.tamperedEnvelopes.length > 0);
    for (const tampered of vectors.tamperedEnvelopes) {
        assert.throws(() => openEnvelope({
            encKey,
            aad: Buffer.from(tampered.associatedData, 'utf8'),
            envelope: Buffer.from(tampered.envelope, 'base64'),
        }), tampered.description);
    }
});

test('every pairing link vector parses to its recorded result', () => {
    const { pairingLinks } = buildVectors();
    assert.ok(pairingLinks.valid.some((c) => c.link.startsWith('codexbar-sync+http://')));
    for (const { link, result } of pairingLinks.valid) assert.deepEqual(parsePairingLink(link), result);
    for (const { link, error } of pairingLinks.invalid) {
        assert.throws(() => parsePairingLink(link), (e) => e.code === error, link);
    }
});
