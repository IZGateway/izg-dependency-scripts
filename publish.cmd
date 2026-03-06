npm@echo off
REM Quick Publish Helper for Windows
REM This script helps you set the GitHub token and publish

echo ================================================
echo   NPM Publish to GitHub Packages
echo ================================================
echo.

REM Check if GITHUB_TOKEN is set
if "%GITHUB_TOKEN%"=="" (
    echo WARNING: GITHUB_TOKEN is not set
    echo.
    echo You need a GitHub Personal Access Token to publish.
    echo.
    echo Steps:
    echo   1. Go to: https://github.com/settings/tokens
    echo   2. Generate new token ^(classic^)
    echo   3. Name: npm-publish-izg
    echo   4. Check scope: write:packages
    echo   5. Copy the token ^(ghp_...^)
    echo.
    
    set /p TOKEN="Enter your GitHub token (or press Enter to exit): "
    
    if "!TOKEN!"=="" (
        echo.
        echo Exiting. Set GITHUB_TOKEN and try again.
        exit /b 1
    )
    
    set GITHUB_TOKEN=!TOKEN!
    echo.
    echo Token set for this session.
    echo.
    echo To make it permanent:
    echo   1. Search Windows for "Environment Variables"
    echo   2. Add new User variable: GITHUB_TOKEN
    echo   3. Value: !TOKEN!
    echo.
) else (
    echo GITHUB_TOKEN is set
    echo.
)

REM Test authentication
echo Testing authentication...
npm whoami --registry=https://npm.pkg.github.com >nul 2>&1

if errorlevel 1 (
    echo.
    echo ERROR: Authentication failed
    echo.
    echo Possible issues:
    echo   - Token doesn't have write:packages scope
    echo   - Token has expired
    echo   - Not a member of IZGateway organization
    echo.
    exit /b 1
)

for /f "delims=" %%i in ('npm whoami --registry=https://npm.pkg.github.com 2^>nul') do set USERNAME=%%i
echo Authenticated as: %USERNAME%
echo.

REM Publish
echo Publishing to GitHub Packages...
echo.

npm publish

if errorlevel 1 (
    echo.
    echo ERROR: Publish failed
    echo.
    echo See SETUP.md for troubleshooting
    exit /b 1
) else (
    echo.
    echo ================================================
    echo   SUCCESS! Package Published
    echo ================================================
    echo.
    echo Your package is now available at:
    echo   https://github.com/orgs/IZGateway/packages
    echo.
    echo Others can install it with:
    for /f "delims=" %%i in ('node -p "require('./package.json').name"') do set PKG_NAME=%%i
    echo   npm install --save-dev %PKG_NAME%
    echo.
)
