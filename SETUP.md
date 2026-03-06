# Quick Setup for Publishing

## ✅ Files Created
- `.npmrc` - Authentication configuration (DO NOT commit this!)
- `package.json` - Already has correct `publishConfig`

## 🚀 Next Steps to Publish

### Step 1: Create GitHub Personal Access Token

1. Go to: https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Name it: `npm-publish-izg`
4. Check the scope: ✅ **write:packages**
5. Click "Generate token"
6. **Copy the token** (starts with `ghp_...`)

### Step 2: Set Environment Variable

**Windows Command Prompt:**
```cmd
set GITHUB_TOKEN=ghp_your_token_here
```

**Windows PowerShell:**
```powershell
$env:GITHUB_TOKEN="ghp_your_token_here"
```

**Linux/Mac:**
```bash
export GITHUB_TOKEN=ghp_your_token_here
```

### Step 3: Verify Authentication

```cmd
npm whoami --registry=https://npm.pkg.github.com
```

This should display your GitHub username. If it does, you're ready!

### Step 4: Publish

```cmd
npm publish
```

## 🔒 Security Notes

- ⚠️ The `.npmrc` file is already in `.gitignore` - never commit it!
- ⚠️ Keep your GITHUB_TOKEN secret
- ✅ The token should have `write:packages` scope only

## 📝 Making Token Permanent

### Windows (System Environment Variable):
1. Search for "Environment Variables" in Windows
2. Click "Environment Variables"
3. Under "User variables", click "New"
4. Variable name: `GITHUB_TOKEN`
5. Variable value: `ghp_your_token_here`
6. Click OK

### Linux/Mac (Shell Profile):
```bash
echo 'export GITHUB_TOKEN=ghp_your_token_here' >> ~/.bashrc
source ~/.bashrc
```

## ✅ Test Your Setup

```cmd
# Test authentication
npm whoami --registry=https://npm.pkg.github.com

# If successful, publish
npm publish
```

## 🆘 Troubleshooting

**"403 Forbidden"**
- Check: Token has `write:packages` scope
- Check: You're a member of the IZGateway organization

**"Authentication failed"**
- Check: `GITHUB_TOKEN` environment variable is set
- Check: Token hasn't expired

**"Cannot publish over existing version"**
- Update version: `npm version patch`
- Then publish: `npm publish`

---

**You're ready to publish! Just set the GITHUB_TOKEN environment variable and run `npm publish`** 🚀
