@echo off
REM Quick Migration Script - Migrate to Shared NPM Package (Windows)
REM This script helps migrate from local scripts to @izgateway/dependency-scripts package

setlocal enabledelayedexpansion

cd /d "%~dp0\.."
set PROJECT_ROOT=%CD%

echo ================================================
echo   IZG Dependency Scripts - Migration Tool
echo ================================================
echo.

REM Check if we're in the right place
if not exist "package.json" (
    echo ERROR: package.json not found. Run this from project root.
    exit /b 1
)

for %%I in ("%PROJECT_ROOT%") do set PROJECT_NAME=%%~nxI
echo Project: %PROJECT_NAME%
echo.

REM Step 1: Check if package is available
echo Step 1/5: Checking package availability...
npm view @izgateway/dependency-scripts version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Package @izgateway/dependency-scripts not found.
    echo.
    echo Please publish the package first:
    echo   1. Create repository: https://github.com/IZGateway/izg-dependency-scripts
    echo   2. Copy scripts to repository
    echo   3. Run: npm publish
    echo.
    echo See SHARED_SCRIPTS_GUIDE.md for detailed instructions.
    exit /b 1
) else (
    for /f "delims=" %%v in ('npm view @izgateway/dependency-scripts version 2^>nul') do set PACKAGE_VERSION=%%v
    echo Package found: @izgateway/dependency-scripts@!PACKAGE_VERSION!
)
echo.

REM Step 2: Create .npmrc if needed
echo Step 2/5: Configuring npm registry...
if not exist ".npmrc" (
    echo @izgateway:registry=https://npm.pkg.github.com> .npmrc
    echo Created .npmrc
) else (
    findstr /C:"@izgateway:registry" .npmrc >nul
    if errorlevel 1 (
        echo @izgateway:registry=https://npm.pkg.github.com>> .npmrc
        echo Updated .npmrc
    ) else (
        echo .npmrc already configured
    )
)
echo.

REM Step 3: Install package
echo Step 3/5: Installing @izgateway/dependency-scripts...
call npm install --save-dev @izgateway/dependency-scripts
if errorlevel 1 (
    echo ERROR: Failed to install package
    exit /b 1
)
echo Package installed
echo.

REM Step 4: Update package.json scripts
echo Step 4/5: Updating package.json scripts...

REM Backup package.json
copy package.json package.json.backup >nul

REM Update scripts using Node.js
node -e "const fs = require('fs'); const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8')); if (pkg.scripts) { if (pkg.scripts['fix-vulnerabilities']) { pkg.scripts['fix-vulnerabilities'] = pkg.scripts['fix-vulnerabilities'].replace('node scripts/fix-all-vulnerabilities.js', 'fix-vulnerabilities'); } if (!pkg.scripts['test-overrides']) { pkg.scripts['test-overrides'] = 'test-overrides'; } if (!pkg.scripts['update-overrides']) { pkg.scripts['update-overrides'] = 'update-overrides'; } } fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n'); console.log('Updated package.json scripts');"
echo.

REM Step 5: Remove old scripts (optional)
echo Step 5/5: Cleanup...
echo.
echo Ready to remove local scripts folder?
echo This will delete: scripts\
echo.
set /p REMOVE="Remove local scripts? (y/N): "

if /i "%REMOVE%"=="y" (
    REM Keep the guide
    if exist "scripts\SHARED_SCRIPTS_GUIDE.md" (
        copy scripts\SHARED_SCRIPTS_GUIDE.md . >nul
        echo Moved SHARED_SCRIPTS_GUIDE.md to project root
    )
    
    rmdir /s /q scripts
    echo Removed local scripts folder
) else (
    echo Skipped removal (you can delete scripts\ manually later)
)
echo.

REM Test installation
echo ================================================
echo   Testing Installation
echo ================================================
echo.

echo Testing fix-vulnerabilities command...
where fix-vulnerabilities >nul 2>&1
if errorlevel 1 (
    echo WARNING: fix-vulnerabilities not found in PATH (may need npm install)
) else (
    echo fix-vulnerabilities is available
)
echo.

REM Summary
echo ================================================
echo   Migration Complete!
echo ================================================
echo.
echo Next steps:
echo   1. Test locally: npm run fix-vulnerabilities
echo   2. Review changes: git diff
echo   3. Update .github\workflows\security-updates.yml if needed
echo   4. Commit changes: git add . ^&^& git commit -m "chore: migrate to shared dependency scripts"
echo.
echo Files modified:
echo   - package.json (scripts updated)
echo   - package-lock.json (new dependency added)
echo   - .npmrc (created or updated)
if not exist "scripts\" (
    echo   - scripts\ (removed)
)
echo.
echo Backup created: package.json.backup
echo.
echo For help, see: SHARED_SCRIPTS_GUIDE.md
echo.

endlocal
