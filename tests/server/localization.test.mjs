import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const languages = ["en", "zh-Hans"];
const targets = [
  {
    name: "watch",
    directory: "CodexWatchCompanion",
    catalog: "CodexWatchCompanion/Localizable.xcstrings",
    infoCatalog: "CodexWatchCompanion/InfoPlist.xcstrings"
  },
  {
    name: "phone",
    directory: "CodexWatchPhone",
    catalog: "CodexWatchPhone/Localizable.xcstrings",
    infoCatalog: "CodexWatchPhone/InfoPlist.xcstrings"
  }
];

test("watch and phone catalogs contain complete English and Simplified Chinese translations", () => {
  for (const target of targets) {
    for (const relativePath of [target.catalog, target.infoCatalog]) {
      const catalog = JSON.parse(fs.readFileSync(path.join(root, relativePath), "utf8"));
      assert.equal(catalog.sourceLanguage, "en", `${relativePath} must fall back to English`);
      assert.ok(Object.keys(catalog.strings).length > 0, `${relativePath} must not be empty`);
      for (const [key, entry] of Object.entries(catalog.strings)) {
        for (const language of languages) {
          const unit = entry.localizations?.[language]?.stringUnit;
          assert.equal(unit?.state, "translated", `${relativePath}: ${language}:${key}`);
          assert.ok(unit.value.length > 0, `${relativePath}: ${language}:${key} must not be empty`);
        }
      }
    }
  }
});

test("literal user-interface keys used by Swift source exist in the matching catalog", () => {
  for (const target of targets) {
    const catalog = JSON.parse(fs.readFileSync(path.join(root, target.catalog), "utf8"));
    const sourceDirectory = path.join(root, target.directory);
    const files = fs.readdirSync(sourceDirectory)
      .filter(file => file.endsWith(".swift"))
      .map(file => path.join(sourceDirectory, file));
    const missing = new Set();

    for (const file of files) {
      const source = fs.readFileSync(file, "utf8");
      for (const pattern of [
        /\bL10n\.(?:text|format)\(\s*"((?:\\.|[^"\\])*)"/g,
        /\b(?:Text|Button|Label|Section|navigationTitle|TextField)\(\s*"((?:\\.|[^"\\])*)"/g
      ]) {
        for (const match of source.matchAll(pattern)) {
          if (match[1].includes("\\(")) continue;
          const key = JSON.parse(`"${match[1]}"`);
          if (!catalog.strings[key]) missing.add(key);
        }
      }
    }
    assert.deepEqual([...missing].sort(), [], `${target.name} catalog is missing Swift UI keys`);
  }
});

test("the Xcode project declares Simplified Chinese and embeds phone localization resources", () => {
  const project = fs.readFileSync(path.join(root, "CodexWatchCompanion.xcodeproj/project.pbxproj"), "utf8");
  assert.match(project, /knownRegions = \([\s\S]*"zh-Hans"/);
  assert.match(project, /Localizable\.xcstrings in Resources/);
  assert.match(project, /InfoPlist\.xcstrings in Resources/);
  assert.match(project, /Localization\.swift in Sources/);
});
