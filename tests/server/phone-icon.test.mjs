import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

test("phone icon asset is present and project references are unique", () => {
  const project = fs.readFileSync(new URL("../../CodexWatchCompanion.xcodeproj/project.pbxproj", import.meta.url), "utf8");
  const ids = [...project.matchAll(/^\s*(CW[0-9A-F]+) \/\*.*?\*\/ = \{/gm)].map(match => match[1]);
  assert.equal(new Set(ids).size, ids.length);
  const dir = new URL("../../CodexWatchPhone/Assets.xcassets/AppIcon.appiconset/", import.meta.url);
  const contents = JSON.parse(fs.readFileSync(new URL("Contents.json", dir), "utf8"));
  const icon = contents.images.find(image => image.platform === "ios" && image.size === "1024x1024");
  assert.ok(icon);
  assert.ok(fs.statSync(new URL(icon.filename, dir)).size > 0);
  for (const id of ["CW0000000000000000003070", "CW0000000000000000003071"]) {
    const block = project.match(new RegExp(id + " /\\* (?:Debug|Release) \\*/ = \\{([\\s\\S]*?)\\n\\t\\t\\};"))?.[1];
    assert.match(block, /ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;/);
  }
});
