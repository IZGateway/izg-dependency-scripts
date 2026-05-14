# @izgateway/dependency-scripts

> Shared dependency management and security update scripts for IZGateway projects

[![npm version](https://img.shields.io/github/package-json/v/IZGateway/izg-dependency-scripts)](https://github.com/IZGateway/izg-dependency-scripts/packages)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## 🎯 What is this?

A collection of automated scripts for managing npm dependencies and fixing security vulnerabilities in IZGateway projects. These scripts are used in CI/CD pipelines to keep dependencies up-to-date and secure.

## 📦 Installation

### GitHub Packages (Private)

**Configure npm registry:**
```bash
echo "@izgateway:registry=https://npm.pkg.github.com" >> .npmrc
```

**Install package:**
```bash
npm install --save-dev @izgateway/dependency-scripts
```

**For CI/CD, add to workflow:**
```yaml
- name: Setup npm authentication
  run: echo "//npm.pkg.github.com/:_authToken=${{ secrets.NPM_TOKEN }}" > .npmrc
```

## 🚀 Usage

### As npm scripts (Recommended)

Add to your `package.json`:
```json
{
  "scripts": {
    "fix-vulnerabilities": "fix-vulnerabilities && npm install && npm audit",
    "test-overrides": "test-overrides",
    "update-overrides": "update-overrides"
  }
}
```

Then run:
```bash
npm run fix-vulnerabilities
```

### As CLI commands

After installation, commands are available globally in your project:
```bash
fix-vulnerabilities    # Fix all security vulnerabilities
test-overrides         # Remove unnecessary overrides
update-overrides       # Update existing overrides to latest
```

### In GitHub Actions

**Note:** In CI/CD environments, call scripts using `node` explicitly to avoid execution issues.

```yaml
- name: Install dependencies
  run: npm ci

- name: Fix vulnerabilities
  run: node node_modules/@izgateway/dependency-scripts/fix-all-vulnerabilities.js
  
- name: Update overrides
  run: node node_modules/@izgateway/dependency-scripts/update-overrides.js
  
- name: Test overrides
  run: node node_modules/@izgateway/dependency-scripts/test-overrides.js
  
- name: Update package-lock
  run: npm install
```

## 🛡️ Shared GitHub Actions

This repository also hosts reusable composite GitHub Actions for IZGateway CI/CD pipelines.
Because they are composite actions (not reusable workflows), they run inside the **calling job's
workspace** — no artifact upload/download is needed to access built JARs.

---

### `cve-scan` — OWASP Dependency Check

**Path:** `.github/actions/cve-scan/action.yml`

Runs OWASP Dependency Check against a JAR or directory using NVD + OSS Index as vulnerability
sources. The Central Analyzer is disabled because OSS Index matches by GAV coordinates natively
and NVD matching is accurate from POM metadata alone in a clean Maven build.

#### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `project-name` | ✅ | — | Display name in the dependency-check report |
| `scan-path` | ✅ | — | Path to the JAR or directory to scan |
| `oss-index-username` | ✅ | — | Sonatype OSS Index username |
| `oss-index-password` | ✅ | — | Sonatype OSS Index API token |
| `nvd-api-key` | ✅ | — | NVD API key |
| `suppression-file` | ❌ | `./dependency-suppression.xml` | Path to OWASP suppression XML |
| `report-output-dir` | ❌ | `target/site` | Directory for HTML/JSON report output |
| `fail-on-cvss` | ❌ | `7` | Minimum CVSS score that fails the build (0–10) |
| `continue-on-error` | ❌ | `false` | Set to `true` to report vulnerabilities without failing the build |
| `artifact-name` | ❌ | `DependencyCheck` | Name of the uploaded report artifact; set to `''` to skip upload |

#### Usage

Replace the inline `Cache Dependency-Check NVD data` + `Dependency Check` steps in your
`maven.yml` with:

```yaml
    - name: CVE Scan
      uses: IZGateway/izg-dependency-scripts/.github/actions/cve-scan@main
      with:
        project-name: My Project Name
        scan-path: target/${{ env.IMAGE_TAG }}.jar
        oss-index-username: ${{ secrets.OSS_INDEX_USERNAME }}
        oss-index-password: ${{ secrets.OSS_INDEX_PASSWORD }}
        nvd-api-key: ${{ secrets.NVDAPIKEY }}
        artifact-name: DependencyCheck    # omit or set to '' to skip upload
```

> **Note:** The report upload is handled inside the action (always runs, even on scan failure).
> You no longer need a separate `upload-artifact` step in your calling workflow.

#### Pinning to a release

`@main` always tracks the latest action. For stability in production workflows, pin to a tag:

```yaml
      uses: IZGateway/izg-dependency-scripts/.github/actions/cve-scan@v1.1.0
```

#### Why `--disableCentral`?

The Central Analyzer queries Maven Central's REST API to enrich CPE identifiers for NVD lookups.
In a clean-build CI pipeline:
- **OSS Index** matches by `group:artifact:version` natively — it doesn't use CPE at all.
- **NVD** matching is accurate from the POM's GAV metadata alone for standard artifacts.
- Central makes additional outbound HTTP calls, adding latency and a rate-limit failure mode.

`--disableCentral` is therefore the correct setting for all IZGateway Maven projects.

---

### `ecr-scan-report` — ECR / Inspector2 Scan Report

**Path:** `.github/workflows/ecr-scan-report.yml`

Reusable workflow (`on: workflow_call`) that retrieves AWS Inspector2 findings for a specific
ECR image tag, filters them to vulnerabilities known at release time (`vendorCreatedAt ≤ release-date`),
and uploads JSON, CSV, and HTML scan report files as a GitHub Actions artifact using the CDC
naming convention (`YYYYMMDD_{pkg}_vX.Y.Z_InspectorScan.{ext}`).

The job runs with `continue-on-error: true` — a scan failure will never block a release.

#### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `ecr-repository` | ✅ | — | ECR repository name (e.g. `izgateway-dev-phiz-web-ws`) |
| `image-tag` | ✅ | — | Image tag pushed to ECR — `{version}-RELEASE-{run}` format |
| `gh-pkg-name` | ✅ | — | GitHub package name used in CDC file naming (e.g. `izgw-hub`) |
| `release-date` | ✅ | — | ISO date (`YYYY-MM-DD`) — filters findings to `vendorCreatedAt ≤ this date` |
| `aws-region` | ❌ | `us-east-1` | AWS region where Inspector2 is enabled |
| `artifact-retention-days` | ❌ | `90` | Days to retain the uploaded scan artifact |

The workflow uses `secrets: inherit` — no explicit secret mapping is required in the caller.

#### Usage

Add an `ecr-scan-report` job to your release/publish workflow after the job that pushes to ECR.
That job must expose `image_tag` and `release_date` as named outputs.

```yaml
jobs:
  push-to-aphl:
    outputs:
      image_tag:    ${{ steps.push.outputs.image_tag }}
      release_date: ${{ steps.push.outputs.release_date }}
    steps:
      # ... build and push steps ...
      - name: Set outputs
        id: push
        run: |
          echo "image_tag=${VERSION}-RELEASE-${{ github.run_number }}" >> "$GITHUB_OUTPUT"
          echo "release_date=$(date -u +%Y-%m-%d)" >> "$GITHUB_OUTPUT"

  ecr-scan-report:
    uses: IZGateway/izg-dependency-scripts/.github/workflows/ecr-scan-report.yml@v1
    needs: [push-to-aphl]
    if: always() && needs.push-to-aphl.result == 'success'
    permissions:
      id-token: write   # required for OIDC token exchange (AWS credential configuration)
      contents: read    # required for actions/checkout inside the called workflow
    with:
      ecr-repository: <your-ecr-repo-name>
      image-tag:      ${{ needs.push-to-aphl.outputs.image_tag }}
      gh-pkg-name:    <your-github-package-name>
      release-date:   ${{ needs.push-to-aphl.outputs.release_date }}
    secrets: inherit
```

#### IAM requirement

The calling repository must have `AWS_ROLE_ARN` set as a repository or environment variable
(**Settings → Secrets and variables → Variables**). This is the ARN of the OIDC role assumed
during the workflow run.

The OIDC role must include `inspector2:ListFindings`.
Adding this permission to all service OIDC roles is tracked in
[IGDD-2151](https://izgateway.atlassian.net/browse/IGDD-2151).

---

## 🔧 Commands

### `fix-vulnerabilities`

**Comprehensive automated vulnerability fixer**

- ✅ Updates direct dependencies to latest compatible versions
- ✅ Adds overrides for transitive dependencies
- ✅ Handles parent package update scenarios intelligently
- ✅ Queries npm registry for latest versions
- ✅ Processes all severity levels (critical, high, moderate, low)

**Example:**
```bash
$ fix-vulnerabilities

🔍 Comprehensive Vulnerability Fixer - Analyzing and fixing vulnerabilities...

Found 13 vulnerable packages

⬆ jest-environment-jsdom: Updating direct dependency (29.7.0 → 30.2.0)
➕ jsdom: Adding override 28.1.0 (low, currently: 20.0.3)
➕ dompurify: Adding override 3.3.2 (moderate)

=== Applying Fixes ===
✅ Updated package.json
```

### `test-overrides`

**Analyzes and removes unnecessary overrides**

- Checks if all resolved versions meet override requirements
- Removes obsolete overrides that are no longer needed
- Helps keep package.json clean

**Example:**
```bash
$ test-overrides

Analyzing overrides against resolved versions...

Checking override: prismjs@1.30.0
  ✓ All resolved versions (min: 1.30.0) meet or exceed override 1.30.0

=== Removing unnecessary overrides ===
  Removing: prismjs

✓ Updated package.json
```

### `update-overrides`

**Updates existing overrides to latest minor versions**

- Queries npm registry for each override
- Finds latest compatible version (same major)
- Updates package.json with newer versions

**Example:**
```bash
$ update-overrides

Updating packages in overrides section...

⬆ prismjs: 1.29.0 → 1.30.0
✓ dompurify: Already at latest (3.2.5)

=== Updated Overrides ===
  prismjs: 1.29.0 → 1.30.0

✓ Updated package.json with latest override versions
```

## 🔄 Typical Workflow

### Automated (CI/CD)

Our recommended workflow in `security-updates.yml`:
```yaml
1. ncu --target minor          # Update direct deps to latest minor
2. update-overrides            # Update existing overrides
3. fix-vulnerabilities         # Fix all vulnerabilities
4. test-overrides              # Remove obsolete overrides
5. npm install                 # Update lock file
6. Run tests                   # Verify everything works
7. Create PR                   # Submit for review
```

### Manual (Developer)

```bash
# Fix security issues
npm run fix-vulnerabilities
npm install
npm audit

# Run tests
npm test

# Commit changes
git add package.json package-lock.json
git commit -m "chore(deps): fix security vulnerabilities"
```

## 📋 Requirements

- **Node.js:** >= 18.0.0
- **npm:** >= 9.0.0
- **Dependencies:** semver (peer dependency)

## 🔒 Security

These scripts are designed with security in mind:

- ✅ Never installs packages without user awareness
- ✅ Only updates to non-breaking versions (same major)
- ✅ Logs all changes for review
- ✅ Works with `package-lock.json` for reproducibility
- ✅ Respects blocklist for known breaking changes
- ✅ Handles meta-packages to avoid peer dependency conflicts

**Blocklist:** Packages that require manual review:
- `immutable` - v3 → v5 breaks swagger-ui-react

**Meta-packages:** Packages that bundle multiple sub-packages:
- `typescript-eslint` - Bundles @typescript-eslint/eslint-plugin, @typescript-eslint/parser, etc.
  - When multiple sub-packages are direct dependencies, the script updates them **all together** to maintain version consistency
  - When only one sub-package is direct AND the meta-package is installed transitively, the script uses **overrides** to avoid peer dependency conflicts

## 📚 Documentation

- **Quick Start:** See [Installation](#installation) above
- **Detailed Guide:** See [SHARED_SCRIPTS_GUIDE.md](./SHARED_SCRIPTS_GUIDE.md) in this repo
- **API Reference:** Run commands with `--help` flag
- **Contributing:** See [CONTRIBUTING.md](./CONTRIBUTING.md)

## 🤝 Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## 📊 Version History

See [CHANGELOG.md](./CHANGELOG.md) for detailed version history.

### Latest Releases

- **1.0.0** (2026-03-06) - Initial release with fix-vulnerabilities, test-overrides, update-overrides

## 🐛 Issues

Found a bug or have a feature request?

1. Check [existing issues](https://github.com/IZGateway/izg-dependency-scripts/issues)
2. Create a new issue with:
   - Description of the problem
   - Steps to reproduce
   - Expected vs actual behavior
   - Your environment (Node version, npm version, OS)

## 📄 License

MIT © IZGateway Team

See [LICENSE](./LICENSE) file for details.

## 🙋 Support

- **Documentation:** This README and [SHARED_SCRIPTS_GUIDE.md](./SHARED_SCRIPTS_GUIDE.md)
- **Issues:** [GitHub Issues](https://github.com/IZGateway/izg-dependency-scripts/issues)
- **Team:** Contact IZGateway development team

## 🔗 Related Projects

- [izg-configuration-console](https://github.com/IZGateway/izg-configuration-console)
- [izg-transformation-ui](https://github.com/IZGateway/izg-transformation-ui)
- [izgw-hub](https://github.com/IZGateway/izgw-hub)

---

**Made with ❤️ by the IZGateway Team**
