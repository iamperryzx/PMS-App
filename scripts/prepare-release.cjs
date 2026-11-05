const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const packagePath = path.join(root, "package.json");
const lockPath = path.join(root, "package-lock.json");
const packageJson = JSON.parse(fs.readFileSync(packagePath, "utf8"));
const packageLock = JSON.parse(fs.readFileSync(lockPath, "utf8"));

function parseVersion(version) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
  if (!match) throw new Error(`Unsupported release version: ${version}`);
  return match.slice(1).map(Number);
}

function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  for (let index = 0; index < a.length; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

async function getLatestReleaseVersion() {
  const repository = process.env.GITHUB_REPOSITORY || "iamperryzx/PMS-App";
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository)) {
    throw new Error(`Invalid GitHub repository: ${repository}`);
  }

  const headers = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "PMS-Enterprise-Release"
  };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

  const response = await fetch(`https://api.github.com/repos/${repository}/releases/latest`, { headers });
  if (response.status === 404) return null;
  if (!response.ok) {
    throw new Error(`Could not read the latest GitHub release (${response.status} ${response.statusText}).`);
  }

  const release = await response.json();
  const version = String(release.tag_name || "").replace(/^v/, "");
  parseVersion(version);
  return version;
}

async function main() {
  const latestVersion = await getLatestReleaseVersion();
  let version = packageJson.version;

  if (latestVersion && compareVersions(latestVersion, version) >= 0) {
    const [major, minor, patch] = parseVersion(latestVersion);
    version = `${major}.${minor}.${patch + 1}`;
  }

  packageJson.version = version;
  packageLock.version = version;
  if (packageLock.packages && packageLock.packages[""]) {
    packageLock.packages[""].version = version;
  }

  fs.writeFileSync(packagePath, `${JSON.stringify(packageJson, null, 2)}\n`);
  fs.writeFileSync(lockPath, `${JSON.stringify(packageLock, null, 2)}\n`);
  console.log(`Prepared PMS release version ${version}.`);
}

main().catch(error => {
  console.error("Could not prepare the PMS release:", error);
  process.exitCode = 1;
});
