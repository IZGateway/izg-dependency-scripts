#!/bin/bash
#
# update-dependencies.sh
# Performs dependency updates locally (steps 6-9 of security-updates workflow)
#
# Usage: ./scripts/update-dependencies.sh
#

set -e  # Exit on error

echo "============================================"
echo "Local Dependency Update Script"
echo "============================================"
echo ""

# Check if we're in the right directory
if [ ! -f "package.json" ]; then
  echo "❌ Error: package.json not found. Run this script from the project root."
  exit 1
fi

# Check if scripts directory exists
if [ ! -d "scripts" ]; then
  echo "❌ Error: scripts directory not found."
  exit 1
fi

# Check if all required scripts exist
REQUIRED_SCRIPTS=("update-overrides.js" "add-security-overrides.js" "test-overrides.js")
for script in "${REQUIRED_SCRIPTS[@]}"; do
  if [ ! -f "scripts/$script" ]; then
    echo "❌ Error: scripts/$script not found."
    exit 1
  fi
done

echo "Step 1: Updating existing overrides to latest minor versions..."
echo "----------------------------------------------"
node scripts/update-overrides.js
if [ $? -ne 0 ]; then
  echo "⚠️  Warning: update-overrides.js completed with warnings"
fi
echo ""

echo "Step 2: Adding security overrides for vulnerabilities..."
echo "----------------------------------------------"
node scripts/add-security-overrides.js
if [ $? -ne 0 ]; then
  echo "⚠️  Warning: add-security-overrides.js completed with warnings"
fi
echo ""

echo "Step 3: Testing if overrides can be removed..."
echo "----------------------------------------------"
# test-overrides.js uses tri-state exit codes:
#   0 = clean, every override classified
#   1 = pre-evaluation error (missing package.json, unwritable temp dir,
#       JSON parse failure) — fatal, should abort
#   2 = evaluation-incomplete: at least one override classified as "skipped"
#       (routine for repos with nested or alias override forms) — non-fatal
#
# Under `set -e` a bare `node scripts/test-overrides.js` would abort on
# either non-zero code, collapsing the distinction. To preserve it we
# capture the exit code via `|| status=$?` (which neutralizes set -e for
# that one line) and branch on the value below.
status=0
node scripts/test-overrides.js || status=$?
if [ $status -eq 1 ]; then
  echo "Error: test-overrides.js failed with pre-evaluation error (exit 1)"
  exit 1
elif [ $status -eq 2 ]; then
  echo "Warning: test-overrides.js completed with some overrides skipped (exit 2)"
fi
echo ""

echo "Step 4: Updating package-lock.json..."
echo "----------------------------------------------"
npm install
if [ $? -ne 0 ]; then
  echo "❌ Error: npm install failed"
  exit 1
fi
echo ""

echo "============================================"
echo "✅ Dependency update complete!"
echo "============================================"
echo ""

# Check if there are any changes
if git diff --quiet package.json package-lock.json; then
  echo "ℹ️  No changes were made to package.json or package-lock.json"
else
  echo "📝 Changes detected:"
  echo ""
  git diff --stat package.json package-lock.json
  echo ""
  echo "Next steps:"
  echo "  1. Review the changes: git diff package.json"
  echo "  2. Run tests: npm test"
  echo "  3. Run code quality checks: npm run code-quality-check"
  echo "  4. Build: npm run build"
  echo "  5. Commit changes: git add package.json package-lock.json"
  echo "  6. Create commit: git commit -m 'chore(deps): update dependencies'"
fi
