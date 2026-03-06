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
  run: echo "//npm.pkg.github.com/:_authToken=${{ secrets.GITHUB_TOKEN }}" > .npmrc
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

```yaml
- name: Install dependencies
  run: npm ci

- name: Fix vulnerabilities
  run: fix-vulnerabilities
  
- name: Update package-lock
  run: npm install
```

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

**Blocklist:** Packages that require manual review:
- `immutable` - v3 → v5 breaks swagger-ui-react

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
