import { describe, expect, it } from 'vitest';
import { colorForModel, colorForProviderID } from './providerColors.js';

describe('provider and model colors', () => {
  it('matches macOS brand colors and aliases', () => {
    expect(colorForProviderID('claude-code')).toBe('#CC785C');
    expect(colorForProviderID('codex')).toBe('#00A67E');
    expect(colorForProviderID('gemini-cli')).toBe('#4285F4');
    expect(colorForProviderID('unknown-provider')).toBe('#9CA3AF');
  });

  it('uses family colors and a stable palette fallback for models', () => {
    expect(colorForModel('gpt-5.2-codex')).toBe('#00A67E');
    expect(colorForModel('claude-sonnet-4')).toBe('#CC785C');
    expect(colorForModel('custom-model')).toBe(colorForModel('custom-model'));
    expect(colorForModel('custom-model')).toMatch(/^#[0-9A-F]{6}$/);
  });
});
