const { spawnSync } = require("node:child_process");
const { readFileSync, readdirSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const guard = join(__dirname, "..", "bounded-command");

function run(args) {
    return spawnSync(guard, args, { encoding: "utf8", timeout: 4000 });
}

test("command guard enforces deadlines and output limits", () => {
    let result = run(["finite", "2", "3", "100", "--", "/usr/bin/printf", "a\nb\nc\nd\n"]);
    assert.equal(result.stdout, "a\nb\nc\n");

    result = run(["finite", "2", "100", "5", "--", "/usr/bin/printf", "123456789"]);
    assert.equal(result.stdout, "12345");

    result = run(["listen", "8", "--", "/usr/bin/printf", "123456789abcdefgh\n"]);
    assert.deepEqual(result.stdout.trimEnd().split("\n"), ["12345678", "9abcdefg", "h"]);

    const started = Date.now();
    result = run(["finite", "1", "10", "100", "--", "/usr/bin/bash", "-c", "sleep 5 &"]);
    assert.equal(result.status, 124);
    assert.ok(Date.now() - started < 3000);
});

test("every local QML Text sink is explicitly plain text", () => {
    const root = join(__dirname, "..");
    for (const file of readdirSync(root).filter(name => name.endsWith(".qml"))) {
        const lines = readFileSync(join(root, file), "utf8").split("\n");
        for (let i = 0; i < lines.length; i++) {
            if (/\bText\s*\{/.test(lines[i]))
                assert.match(lines.slice(i + 1, i + 4).join("\n"), /textFormat:\s*Text\.PlainText/, `${file}:${i + 1}`);
        }
    }
});
