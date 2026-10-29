#!/usr/bin/env node
// Check the complete Git index, including recordings added before an additions-only hook.
// Generated recordings belong beside their immutable inputs only in the working tree.
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function trackedRecordings(root) {
  const git = spawnSync('git', ['ls-files', '-z'], {
    cwd: root, encoding: 'utf8',
  });
  if (git.error || git.status !== 0) {
    throw new Error(`cannot inspect the recording inventory: ${git.error?.message ?? git.stderr}`);
  }
  return git.stdout.split('\0').filter((p) => p.split('/').some((part) => part.endsWith('.ct')));
}

export function checkRecordingsPolicy(root) {
  const paths = trackedRecordings(root);
  if (paths.length) {
    throw new Error(`${paths.length} committed .ct paths must be generated from their inputs:\n`
      + paths.map((p) => `  ${p}`).join('\n'));
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    checkRecordingsPolicy(resolve(dirname(fileURLToPath(import.meta.url)), '../..'));
    console.log('recording policy: no .ct paths tracked');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
