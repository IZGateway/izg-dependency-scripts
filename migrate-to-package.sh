#!/bin/bash

# Quick Migration Script - Migrate to Shared NPM Package
# This script helps migrate from local scripts to @izgateway/dependency-scripts package

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================"
echo "  IZG Dependency Scripts - Migration Tool"
echo "================================================"
echo ""

# Check if we're in the right place
if [ ! -f "package.json" ]; then
    echo "❌ Error: package.json not found. Run this from project root."
    exit 1
fi

echo "📍 Project: $(basename "$PROJECT_ROOT")"
echo ""

# Step 1: Check if package is available
echo "Step 1/5: Checking package availability..."
if npm view @izgateway/dependency-scripts version &>/dev/null; then
    PACKAGE_VERSION=$(npm view @izgateway/dependency-scripts version)
    echo "✅ Package found: @izgateway/dependency-scripts@$PACKAGE_VERSION"
else
    echo "❌ Package @izgateway/dependency-scripts not found."
    echo ""
    echo "Please publish the package first:"
    echo "  1. Create repository: https://github.com/IZGateway/izg-dependency-scripts"
    echo "  2. Copy scripts to repository"
    echo "  3. Run: npm publish"
    echo ""
    echo "See SHARED_SCRIPTS_GUIDE.md for detailed instructions."
    exit 1
fi
echo ""

# Step 2: Create .npmrc if needed
echo "Step 2/5: Configuring npm registry..."
if [ ! -f ".npmrc" ]; then
    echo "@izgateway:registry=https://npm.pkg.github.com" > .npmrc
    echo "✅ Created .npmrc"
else
    if ! grep -q "@izgateway:registry" .npmrc; then
        echo "@izgateway:registry=https://npm.pkg.github.com" >> .npmrc
        echo "✅ Updated .npmrc"
    else
        echo "✅ .npmrc already configured"
    fi
fi
echo ""

# Step 3: Install package
echo "Step 3/5: Installing @izgateway/dependency-scripts..."
npm install --save-dev @izgateway/dependency-scripts
echo "✅ Package installed"
echo ""

# Step 4: Update package.json scripts
echo "Step 4/5: Updating package.json scripts..."

# Backup package.json
cp package.json package.json.backup

# Update scripts using Node.js
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));

// Update script references
if (pkg.scripts) {
    if (pkg.scripts['fix-vulnerabilities']) {
        pkg.scripts['fix-vulnerabilities'] = pkg.scripts['fix-vulnerabilities']
            .replace('node scripts/fix-all-vulnerabilities.js', 'fix-vulnerabilities');
    }
    // Add convenience scripts if they don't exist
    if (!pkg.scripts['test-overrides']) {
        pkg.scripts['test-overrides'] = 'test-overrides';
    }
    if (!pkg.scripts['update-overrides']) {
        pkg.scripts['update-overrides'] = 'update-overrides';
    }
}

fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
console.log('✅ Updated package.json scripts');
"
echo ""

# Step 5: Remove old scripts (optional)
echo "Step 5/5: Cleanup..."
echo ""
echo "⚠️  Ready to remove local scripts folder?"
echo "    This will delete: scripts/"
echo ""
read -p "Remove local scripts? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Keep the guide
    if [ -f "scripts/SHARED_SCRIPTS_GUIDE.md" ]; then
        cp scripts/SHARED_SCRIPTS_GUIDE.md .
        echo "📄 Moved SHARED_SCRIPTS_GUIDE.md to project root"
    fi
    
    rm -rf scripts/
    echo "✅ Removed local scripts folder"
else
    echo "⏭️  Skipped removal (you can delete scripts/ manually later)"
fi
echo ""

# Test installation
echo "================================================"
echo "  Testing Installation"
echo "================================================"
echo ""

echo "Testing fix-vulnerabilities command..."
if command -v fix-vulnerabilities &>/dev/null; then
    echo "✅ fix-vulnerabilities is available"
else
    echo "⚠️  fix-vulnerabilities not found in PATH (may need npm install)"
fi
echo ""

# Summary
echo "================================================"
echo "  ✅ Migration Complete!"
echo "================================================"
echo ""
echo "Next steps:"
echo "  1. Test locally: npm run fix-vulnerabilities"
echo "  2. Review changes: git diff"
echo "  3. Update .github/workflows/security-updates.yml if needed"
echo "  4. Commit changes: git add . && git commit -m 'chore: migrate to shared dependency scripts'"
echo ""
echo "Files modified:"
echo "  - package.json (scripts updated)"
echo "  - package-lock.json (new dependency added)"
echo "  - .npmrc (created or updated)"
if [ ! -d "scripts" ]; then
    echo "  - scripts/ (removed)"
fi
echo ""
echo "Backup created: package.json.backup"
echo ""
echo "For help, see: SHARED_SCRIPTS_GUIDE.md"
echo ""
