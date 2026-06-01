const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const semver = require('semver');

const EXIT_OK = 0;
const EXIT_PRE_EVAL_ERROR = 1;
const EXIT_EVAL_INCOMPLETE = 2;

const TRIAL_TIMEOUT_MS = 120_000;

let activeScratchDir = null;

function main() {
  const cwd = process.cwd();
  const packageJsonPath = path.join(cwd, 'package.json');
  const packageLockPath = path.join(cwd, 'package-lock.json');

  let packageJson;
  let consumerLock;
  try {
    packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
  } catch (e) {
    console.error(`Could not read or parse package.json: ${e.message}`);
    process.exit(EXIT_PRE_EVAL_ERROR);
  }
  try {
    consumerLock = JSON.parse(fs.readFileSync(packageLockPath, 'utf8'));
  } catch (e) {
    console.error(`Could not read or parse package-lock.json: ${e.message}`);
    process.exit(EXIT_PRE_EVAL_ERROR);
  }

  console.log('Analyzing overrides via trial removal in a scratch tree...\n');

  if (!packageJson.overrides || Object.keys(packageJson.overrides).length === 0) {
    console.log('No overrides found in package.json');
    process.exit(EXIT_OK);
  }

  const decisions = [];
  for (const [pkg, overrideValue] of Object.entries(packageJson.overrides)) {
    console.log(`Checking override: ${pkg}@${typeof overrideValue === 'string' ? overrideValue : JSON.stringify(overrideValue)}`);

    if (typeof overrideValue !== 'string') {
      decisions.push({
        pkg,
        overrideVersion: overrideValue,
        outcome: 'skipped',
        reason: 'non-string override value (nested override form not supported)',
      });
      console.log(`  ⊘ Skipped: non-string override value (nested form)\n`);
      continue;
    }

    // This script only supports flat overrides keyed by a plain package name.
    // Selector keys like `foo@^1.2.3` or `a>b` cannot be mapped to lockfile package names safely.
    const isScoped = pkg.startsWith('@');
    const hasSelectorKey =
      pkg.includes('>') ||
      (!isScoped && pkg.includes('@')) ||
      (isScoped && pkg.indexOf('@', pkg.indexOf('/') + 1) !== -1);
    if (hasSelectorKey) {
      decisions.push({
        pkg,
        overrideVersion: overrideValue,
        outcome: 'skipped',
        reason: 'override key uses selector syntax (e.g. pkg@range or parent>child); only plain package-name keys are supported',
      });
      console.log('  ⊘ Skipped: override key uses selector syntax (not supported)\n');
      continue;
    }

    const decision = evaluateOverride(pkg, overrideValue, packageJson, consumerLock, cwd);
    decisions.push(decision);
    logDecision(decision);
  }

  const toRemove = decisions.filter(d => d.outcome === 'removed').map(d => d.pkg);
  if (toRemove.length > 0) {
    const mutated = JSON.parse(JSON.stringify(packageJson));
    toRemove.forEach(pkg => {
      delete mutated.overrides[pkg];
    });
    if (Object.keys(mutated.overrides).length === 0) {
      delete mutated.overrides;
    }
    fs.writeFileSync(packageJsonPath, JSON.stringify(mutated, null, 2) + '\n');
    console.log(`Updated package.json — removed ${toRemove.length} override(s)\n`);
  } else {
    console.log('No overrides removed.\n');
  }

  printSummary(decisions);

  const anySkipped = decisions.some(d => d.outcome === 'skipped');
  process.exit(anySkipped ? EXIT_EVAL_INCOMPLETE : EXIT_OK);
}

function evaluateOverride(pkg, overrideVersion, packageJson, consumerLock, cwd) {
  let overrideMin;
  try {
    overrideMin = semver.minVersion(overrideVersion);
    if (!overrideMin) throw new Error('semver.minVersion returned null');
  } catch (e) {
    return {
      pkg,
      overrideVersion,
      outcome: 'skipped',
      reason: `cannot interpret override version "${overrideVersion}": ${e.message}`,
    };
  }

  let scratchDir;
  try {
    try {
      scratchDir = createScratchDir();
      activeScratchDir = scratchDir;
      seedScratch(scratchDir, cwd);
    } catch (e) {
      if (scratchDir) cleanupScratch(scratchDir);
      activeScratchDir = null;
      console.error(`Scratch setup failed: ${e.message}`);
      process.exit(EXIT_PRE_EVAL_ERROR);
    }

    const scratchPkgPath = path.join(scratchDir, 'package.json');
    const scratchPkg = JSON.parse(fs.readFileSync(scratchPkgPath, 'utf8'));
    delete scratchPkg.overrides[pkg];
    if (Object.keys(scratchPkg.overrides).length === 0) {
      delete scratchPkg.overrides;
    }
    fs.writeFileSync(scratchPkgPath, JSON.stringify(scratchPkg, null, 2) + '\n');

    const trial = runTrialInstall(scratchDir);
    if (!trial.ok) {
      return {
        pkg,
        overrideVersion,
        outcome: 'skipped',
        reason: `trial install failed: ${summarizeStderr(trial.stderr)}`,
      };
    }

    const scratchLockPath = path.join(scratchDir, 'package-lock.json');
    let scratchLock;
    try {
      scratchLock = JSON.parse(fs.readFileSync(scratchLockPath, 'utf8'));
    } catch (e) {
      return {
        pkg,
        overrideVersion,
        outcome: 'skipped',
        reason: `could not read scratch package-lock.json: ${e.message}`,
      };
    }

    return classifyTrialOutcome(pkg, overrideVersion, overrideMin, consumerLock, scratchLock);
  } catch (e) {
    return {
      pkg,
      overrideVersion,
      outcome: 'skipped',
      reason: `evaluation error: ${e.message}`,
    };
  } finally {
    if (scratchDir) {
      cleanupScratch(scratchDir);
      activeScratchDir = null;
    }
  }
}

function classifyTrialOutcome(pkg, overrideVersion, overrideMin, consumerLock, scratchLock) {
  const allTrial = findAllResolvedVersions(scratchLock, pkg);
  if (allTrial.length === 0) {
    return {
      pkg,
      overrideVersion,
      outcome: 'removed',
      reason: 'package no longer in dependency graph',
    };
  }

  const trialByPath = findResolvedByPath(scratchLock, pkg);
  const consumerHasPackages = consumerLock && typeof consumerLock.packages === 'object';

  if (Object.keys(trialByPath).length > 0 && consumerHasPackages) {
    const currentByPath = findResolvedByPath(consumerLock, pkg);

    if (process.env.TEST_OVERRIDES_DEBUG) {
      console.log(`    [debug] override floor: ${overrideMin}`);
      console.log(`    [debug] current paths:`);
      for (const [p, v] of Object.entries(currentByPath)) console.log(`      ${p} = ${v}`);
      console.log(`    [debug] trial paths:`);
      for (const [p, v] of Object.entries(trialByPath)) console.log(`      ${p} = ${v}`);
    }

    // Pass 1: trial paths that dropped below floor (existing or newly-introduced)
    for (const [p, vTrial] of Object.entries(trialByPath)) {
      const vCurrent = currentByPath[p];
      let wasProtected, droppedBelow;
      try {
        wasProtected = vCurrent ? semver.gte(vCurrent, overrideMin) : true;
        droppedBelow = semver.lt(vTrial, overrideMin);
      } catch (e) {
        return {
          pkg,
          overrideVersion,
          outcome: 'skipped',
          reason: `invalid semver comparison: ${e.message}`,
        };
      }
      if (wasProtected && droppedBelow) {
        const where = p === '' ? '<root>' : p;
        const reason = vCurrent
          ? `${where} would drop from ${vCurrent} to ${vTrial} (floor ${overrideMin})`
          : `removing override introduces ${where}@${vTrial} (floor ${overrideMin})`;
        return { pkg, overrideVersion, outcome: 'kept', reason };
      }
    }

    // Pass 2: protected paths in the current lockfile that disappeared in the trial.
    // If pkg still resolves below-floor anywhere in the trial, the consumers of the
    // disappeared path almost certainly got deduped down to that low resolution.
    const trialBelowFloor = Object.entries(trialByPath).filter(([, v]) => {
      try { return semver.lt(v, overrideMin); } catch (_) { return false; }
    });
    if (trialBelowFloor.length > 0) {
      for (const [p, vCurrent] of Object.entries(currentByPath)) {
        let wasProtected;
        try { wasProtected = semver.gte(vCurrent, overrideMin); } catch (_) { wasProtected = false; }
        if (!wasProtected) continue;
        if (trialByPath[p] !== undefined) continue;
        const [lowPath, lowVer] = trialBelowFloor[0];
        const where = p === '' ? '<root>' : p;
        const lowWhere = lowPath === '' ? '<root>' : lowPath;
        return {
          pkg,
          overrideVersion,
          outcome: 'kept',
          reason: `${where}@${vCurrent} disappears in trial; consumers deduped to ${lowWhere}@${lowVer} (floor ${overrideMin})`,
        };
      }
    }

    // No regression. Build a reason that focuses on the previously-protected paths.
    const protectedEntries = Object.entries(currentByPath).filter(([, v]) => {
      try { return semver.gte(v, overrideMin); } catch (_) { return false; }
    });
    let reason;
    if (protectedEntries.length === 0) {
      reason = `natural resolution: ${pickMinVersion(Object.values(trialByPath))} (floor ${overrideMin})`;
    } else {
      const sample = protectedEntries.find(([p]) => p === `node_modules/${pkg}`) || protectedEntries[0];
      const [sPath, sCurrent] = sample;
      const sTrial = trialByPath[sPath];
      const where = sPath === '' ? '<root>' : sPath;
      if (sTrial === undefined) {
        reason = `${where} (was ${sCurrent}) absent in trial; remaining trial paths all at or above floor ${overrideMin}`;
      } else if (sTrial === sCurrent) {
        reason = `${where} resolves to ${sTrial} with or without the override`;
      } else {
        reason = `${where} resolves to ${sTrial} naturally (was ${sCurrent} with override, floor ${overrideMin})`;
      }
    }
    return {
      pkg,
      overrideVersion,
      outcome: 'removed',
      reason,
    };
  }

  // Fallback for v1 lockfiles (no `packages` key): aggregate-version check
  const minResolved = pickMinVersion(allTrial);
  for (const v of allTrial) {
    try {
      if (semver.lt(v, overrideMin)) {
        return {
          pkg,
          overrideVersion,
          outcome: 'kept',
          reason: `natural resolution would drop to ${minResolved}`,
        };
      }
    } catch (e) {
      return {
        pkg,
        overrideVersion,
        outcome: 'skipped',
        reason: `invalid semver comparison: ${v} vs ${overrideMin}`,
      };
    }
  }
  return {
    pkg,
    overrideVersion,
    outcome: 'removed',
    reason: `natural resolution: ${minResolved}`,
  };
}

function pickMinVersion(versions) {
  try {
    return semver.minSatisfying(versions, '*') || versions[0];
  } catch (_) {
    return versions[0];
  }
}

function findResolvedByPath(lockData, packageName) {
  const byPath = {};
  if (!lockData || typeof lockData.packages !== 'object') return byPath;
  for (const [p, d] of Object.entries(lockData.packages)) {
    if (!d || !d.version) continue;
    const parts = p.split('node_modules/');
    const name = parts[parts.length - 1];
    if (name === packageName) {
      byPath[p] = d.version;
    }
  }
  return byPath;
}

function createScratchDir() {
  const suffix = crypto.randomBytes(6).toString('hex');
  const dir = path.join(os.tmpdir(), `izg-override-trial-${suffix}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function seedScratch(scratchDir, cwd) {
  const files = ['package.json', 'package-lock.json', '.npmrc'];
  for (const name of files) {
    const src = path.join(cwd, name);
    if (fs.existsSync(src)) {
      fs.copyFileSync(src, path.join(scratchDir, name));
    }
  }
}

function cleanupScratch(scratchDir) {
  try {
    fs.rmSync(scratchDir, { recursive: true, force: true });
  } catch (_) {
    // best effort
  }
}

function runTrialInstall(scratchDir) {
  const start = Date.now();
  const result = spawnSync(
    'npm',
    ['install', '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund'],
    {
      cwd: scratchDir,
      encoding: 'utf8',
      timeout: TRIAL_TIMEOUT_MS,
      env: process.env,
    }
  );
  const durationMs = Date.now() - start;
  const stdout = result.stdout || '';
  const stderr = result.stderr || '';

  if (result.error) {
    return {
      ok: false,
      stdout,
      stderr: `${stderr}\n${result.error.message}`.trim(),
      durationMs,
    };
  }
  if (result.status !== 0) {
    return { ok: false, stdout, stderr, durationMs };
  }
  return { ok: true, stdout, stderr, durationMs };
}

function summarizeStderr(stderr) {
  if (!stderr) return 'unknown error (no stderr)';
  const lines = stderr.split('\n').map(s => s.trim()).filter(Boolean);
  const errLine = lines.find(l => l.startsWith('npm error') || l.includes('npm ERR!'));
  const pick = errLine || lines[0] || stderr.trim();
  return pick.slice(0, 200);
}

function logDecision(d) {
  switch (d.outcome) {
    case 'kept':
      console.log(`  ✓ Kept: ${d.reason}\n`);
      break;
    case 'removed':
      console.log(`  ✗ Removed: ${d.reason}\n`);
      break;
    case 'skipped':
      console.log(`  ⊘ Skipped: ${d.reason}\n`);
      break;
  }
}

function printSummary(decisions) {
  console.log('=== Override evaluation summary ===');
  const labelWidth = Math.max(
    20,
    ...decisions.map(d => `${d.pkg}@${typeof d.overrideVersion === 'string' ? d.overrideVersion : JSON.stringify(d.overrideVersion)}`.length)
  );
  const outcomeWidth = 8;
  for (const d of decisions) {
    const v = typeof d.overrideVersion === 'string' ? d.overrideVersion : JSON.stringify(d.overrideVersion);
    const label = `${d.pkg}@${v}`.padEnd(labelWidth);
    const outcome = d.outcome.padEnd(outcomeWidth);
    console.log(`  ${label}  ${outcome}  (${d.reason})`);
  }
  console.log();
}

function findAllResolvedVersions(lockData, packageName) {
  const versions = new Set();

  function traverse(obj, path = '') {
    if (!obj || typeof obj !== 'object') return;

    if (obj.name === packageName && obj.version) {
      versions.add(obj.version);
    }

    if (path === '' && obj.packages) {
      for (const [pkgPath, pkgData] of Object.entries(obj.packages)) {
        const pathParts = pkgPath.split('node_modules/');
        const pkgName = pathParts[pathParts.length - 1];
        if (pkgName === packageName && pkgData.version) {
          versions.add(pkgData.version);
        }
      }
    }

    if (obj.dependencies) {
      for (const [depName, depData] of Object.entries(obj.dependencies)) {
        if (depName === packageName && depData.version) {
          versions.add(depData.version);
        }
        if (depData.dependencies) {
          traverse(depData, path + '/' + depName);
        }
      }
    }
  }

  traverse(lockData);
  return Array.from(versions);
}

process.on('uncaughtException', (err) => {
  if (activeScratchDir) cleanupScratch(activeScratchDir);
  console.error(`Uncaught error: ${err.message}`);
  process.exit(EXIT_PRE_EVAL_ERROR);
});
process.on('SIGINT', () => {
  if (activeScratchDir) cleanupScratch(activeScratchDir);
  process.exit(EXIT_PRE_EVAL_ERROR);
});

main();
