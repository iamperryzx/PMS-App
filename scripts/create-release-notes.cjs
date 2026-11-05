const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

function runGit(args) {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

function main() {
  const packageJson = JSON.parse(fs.readFileSync(path.resolve(__dirname, "..", "package.json"), "utf8"));
  const previousTag = runGit(["tag", "--list", "v*", "--sort=-version:refname"])
    .split(/\r?\n/)
    .find(Boolean);
  const range = previousTag ? `${previousTag}..HEAD` : "HEAD";
  const commits = runGit(["log", range, "--format=%s"])
    .split(/\r?\n/)
    .map(subject => subject.trim())
    .filter(Boolean);

  const content = [
    `Phiên bản ${packageJson.version}`,
    "",
    "Nội dung cập nhật:",
    ...(commits.length
      ? commits.map(subject => `- ${subject}`)
      : ["- Cải thiện và cập nhật ứng dụng."]),
    "",
    "Bản cập nhật chỉ được cài đặt sau khi người dùng xác nhận trong ứng dụng."
  ].join("\n");

  fs.writeFileSync(path.resolve(__dirname, "..", "release-notes.md"), `${content}\n`);
}

try {
  main();
} catch (error) {
  console.error("Could not prepare Vietnamese release notes:", error);
  process.exitCode = 1;
}
