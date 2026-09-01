'use strict';

const childProcess = require('node:child_process');

if (!childProcess.__cmfaPreviewLaunchPatchApplied) {
  const originalSpawn = childProcess.spawn;

  childProcess.spawn = function patchedSpawn(command, args, options) {
    if (shouldPatchPreviewerLaunch(command, args)) {
      const patchedArgs = args.slice();
      const insertAt = patchedArgs.indexOf('-url');
      const insertion = ['-abn', 'TestAbility'];

      if (insertAt >= 0) {
        patchedArgs.splice(insertAt, 0, ...insertion);
      } else {
        patchedArgs.push(...insertion);
      }

      return originalSpawn.call(this, command, patchedArgs, options);
    }

    return originalSpawn.call(this, command, args, options);
  };

  childProcess.__cmfaPreviewLaunchPatchApplied = true;
}

function shouldPatchPreviewerLaunch(command, args) {
  if (typeof command !== 'string' || !Array.isArray(args)) {
    return false;
  }

  if (!/(^|[\\/])Previewer(?:\.exe)?$/u.test(command)) {
    return false;
  }

  return args.includes('-abp') && args.includes('.test/testability/TestAbility.abc') && !args.includes('-abn');
}
