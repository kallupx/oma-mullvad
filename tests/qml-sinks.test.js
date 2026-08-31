const { readFileSync, readdirSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

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
