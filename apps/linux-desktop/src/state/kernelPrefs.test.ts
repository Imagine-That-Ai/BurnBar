// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { KERNEL_META } from '@openburnbar/gl-engine/engine/registry';
import {
  DEFAULT_LINUX_KERNEL_ID,
  KERNEL_PREFS_KEY,
  readPersistedKernelId,
  writePersistedKernelId
} from './kernelPrefs.js';

afterEach(() => {
  localStorage.clear();
});

describe('kernelPrefs', () => {
  it('defaults to swarmEmber when unset', () => {
    expect(readPersistedKernelId()).toBe(DEFAULT_LINUX_KERNEL_ID);
    expect(DEFAULT_LINUX_KERNEL_ID).toBe('swarmEmber');
  });

  it('rejects invalid stored ids', () => {
    localStorage.setItem(KERNEL_PREFS_KEY, 'not-a-kernel');
    expect(readPersistedKernelId()).toBe(DEFAULT_LINUX_KERNEL_ID);
  });

  it('round-trips a valid registry id', () => {
    const id = KERNEL_META[5]!.id;
    writePersistedKernelId(id);
    expect(localStorage.getItem(KERNEL_PREFS_KEY)).toBe(id);
    expect(readPersistedKernelId()).toBe(id);
  });

  it('exposes all 32 kernels in registry metadata', () => {
    expect(KERNEL_META.length).toBe(32);
  });
});