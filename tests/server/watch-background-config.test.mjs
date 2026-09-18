import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

test("both Watch build configurations use the background-audio plist", () => {
  const project = fs.readFileSync(new URL("../../CodexWatchCompanion.xcodeproj/project.pbxproj", import.meta.url), "utf8");
  const plist = fs.readFileSync(new URL("../../CodexWatchCompanion-Info.plist", import.meta.url), "utf8");
  for (const id of ["CW0000000000000000000020", "CW0000000000000000000021"]) {
    const block = project.match(new RegExp(id + " /\\* (?:Debug|Release) \\*/ = \\{([\\s\\S]*?)\\n\\t\\t\\};"))?.[1];
    assert.ok(block, `Missing Watch build configuration ${id}`);
    assert.match(block, /INFOPLIST_FILE = "CodexWatchCompanion-Info.plist";/);
  }
  assert.match(plist, /<key>UIBackgroundModes<\/key>\s*<array>\s*<string>audio<\/string>\s*<\/array>/);
});
