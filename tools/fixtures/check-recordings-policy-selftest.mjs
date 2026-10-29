#!/usr/bin/env node
// Real disposable Git indices exercise both newly staged and already committed paths.
// The files are deliberately arbitrary: this policy prohibits derived recordings by
// their path, independent of whether a current reader can decode their contents.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { checkRecordingsPolicy } from './check-recordings-policy.mjs';

const root = mkdtempSync(join(tmpdir(), 'blocktracer-recording-policy-'));
const git = (...args) => {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
};
try {
  git('init', '--quiet');
  checkRecordingsPolicy(root);
  mkdirSync(join(root, 'inputs'));
  writeFileSync(join(root, 'inputs', 'chain.json'), '{}');
  git('add', 'inputs');
  checkRecordingsPolicy(root);
  const file = join(root, 'nested', 'trace.ct');
  mkdirSync(dirname(file));
  writeFileSync(file, 'recording');
  git('add', 'nested/trace.ct');
  assert.throws(() => checkRecordingsPolicy(root), /nested\/trace\.ct/);
  git('-c', 'user.name=Policy test', '-c', 'user.email=policy@example.invalid',
      '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'recording predates the hook');
  assert.throws(() => checkRecordingsPolicy(root), /nested\/trace\.ct/);
  git('rm', '--quiet', 'nested/trace.ct');
  checkRecordingsPolicy(root);
  const directoryMember = join(root, 'nested', 'trace.ct', 'events.bin');
  mkdirSync(dirname(directoryMember), { recursive: true });
  writeFileSync(directoryMember, 'recording member');
  git('add', 'nested/trace.ct/events.bin');
  assert.throws(() => checkRecordingsPolicy(root), /nested\/trace\.ct\/events\.bin/);
  // A missing working directory is a failed Git invocation, never a clean index.
  assert.throws(() => checkRecordingsPolicy('/definitely-missing-blocktracer-policy-root'),
                /cannot inspect the recording inventory/);
  console.log('recording policy selftest: clean inputs, staged and old recordings, directory recording, Git failure');
} finally {
  rmSync(root, { recursive: true, force: true });
}
