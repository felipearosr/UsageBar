import fs from 'node:fs';

const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!result.ok) {
    console.error(JSON.stringify(result, null, 2));
    process.exit(1);
}
console.log(`UI smoke passed (${result.assertions.length} assertions)`);
