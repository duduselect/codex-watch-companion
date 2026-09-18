import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const root = path.resolve(import.meta.dirname, "../..");

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

test("tracked source uses generic defaults instead of personal network or signing values", () => {
  const project = read("CodexWatchCompanion.xcodeproj/project.pbxproj");
  const source = [
    project,
    read("CodexWatchPhone/PhoneGatewayViewModel.swift"),
    read("CodexWatchCompanion/WatchPhoneBridgeClient.swift")
  ].join("\n");

  const privateIPv4 = /\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b/;
  assert.doesNotMatch(source, privateIPv4);
  assert.doesNotMatch(project, /DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10};/);
  assert.match(read("scripts/install.sh"), /\.codex-watch\/local\.env/);
});
