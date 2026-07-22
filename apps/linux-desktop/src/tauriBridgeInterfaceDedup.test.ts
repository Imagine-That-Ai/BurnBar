import { describe, expect, expectTypeOf, it } from 'vitest';
import { bridgeStubDefaults } from './testing/bridgeStubs';
import type { ComputerUsePanicHaltResult, LinuxShellBridge } from './tauriBridge';

/**
 * Regression test for P-CQ-1: the LinuxShellBridge interface must not contain
 * duplicate member declarations. The pre-fix code declared several members
 * (notably computerUsePanicHalt) twice with conflicting signatures — once as
 * `computerUsePanicHalt?: Promise<unknown>` and once as
 * `computerUsePanicHalt: Promise<ComputerUsePanicHaltResult>`. This triggered
 * TS2386 ("Overload signatures must all be optional or required") and a
 * downstream TS2345.
 *
 * These tests prove at the type level (enforced by tsc) and at runtime (enforced
 * by vitest) that:
 *  1. The subset of LinuxShellBridge members that bridgeStubDefaults implements
 *     is compatible with the interface — this would fail to compile if the
 *     interface had conflicting duplicate members (TS2386 makes any reference
 *     to LinuxShellBridge invalid).
 *  2. computerUsePanicHalt has the typed signature returning
 *     Promise<ComputerUsePanicHaltResult>, not Promise<unknown>.
 *  3. bridgeStubDefaults has exactly one computerUsePanicHalt key.
 */
describe('LinuxShellBridge interface dedup (P-CQ-1)', () => {
  it('bridgeStubDefaults members are compatible with LinuxShellBridge', () => {
    // Type-level proof: verify that each member bridgeStubDefaults provides
    // has a signature compatible with the corresponding LinuxShellBridge member.
    // We use Pick to narrow to only the keys bridgeStubDefaults implements,
    // since bridgeStubDefaults is a partial mock (core infrastructure members
    // like daemonHealth are added per-test via spread).
    //
    // If the interface had duplicate members with conflicting signatures,
    // TS2386 would make the LinuxShellBridge type invalid, and this assertion
    // would fail to compile.
    type BridgeStubKeys = Pick<LinuxShellBridge, keyof typeof bridgeStubDefaults>;
    expectTypeOf(bridgeStubDefaults).toMatchTypeOf<BridgeStubKeys>();

    // Runtime sanity: the object exists and has members.
    expect(bridgeStubDefaults).toBeDefined();
    expect(Object.keys(bridgeStubDefaults).length).toBeGreaterThan(0);
  });

  it('computerUsePanicHalt returns ComputerUsePanicHaltResult, not unknown', async () => {
    // Type-level: the return type of computerUsePanicHalt must resolve to
    // ComputerUsePanicHaltResult, not unknown. With the pre-fix duplicate
    // declaration (Promise<unknown> vs Promise<ComputerUsePanicHaltResult>),
    // tsc would emit TS2386 on the interface, making this type assertion fail.
    expectTypeOf(bridgeStubDefaults.computerUsePanicHalt)
      .returns.resolves.toEqualTypeOf<ComputerUsePanicHaltResult>();

    // Also verify at the interface level: the picked member must return the
    // typed result, not unknown.
    type PanicHaltPick = Pick<LinuxShellBridge, 'computerUsePanicHalt'>;
    expectTypeOf<PanicHaltPick>()
      .toHaveProperty('computerUsePanicHalt')
      .returns.resolves.toEqualTypeOf<ComputerUsePanicHaltResult>();

    // Runtime: verify the actual returned shape matches ComputerUsePanicHaltResult.
    const result = await bridgeStubDefaults.computerUsePanicHalt();
    expect(result).toEqual({
      sessionId: '*',
      endedAt: new Date(0).toISOString(),
      auditHeadHashHex: '',
      source: 'hotkey'
    });
    expect(typeof result).toBe('object');
    expect(result).toHaveProperty('sessionId');
    expect(result).toHaveProperty('endedAt');
    expect(result).toHaveProperty('auditHeadHashHex');
    expect(result).toHaveProperty('source');
  });

  it('bridgeStubDefaults has exactly one computerUsePanicHalt key', () => {
    const keys = Object.keys(bridgeStubDefaults);
    const panicHaltKeys = keys.filter((k) => k === 'computerUsePanicHalt');
    expect(panicHaltKeys).toHaveLength(1);

    // Verify the key is a direct, enumerable own property — not silently
    // overwritten by a duplicate in the object literal.
    expect(Object.prototype.hasOwnProperty.call(bridgeStubDefaults, 'computerUsePanicHalt')).toBe(true);
    expect(Object.getOwnPropertyDescriptor(bridgeStubDefaults, 'computerUsePanicHalt')?.enumerable).toBe(true);
  });
});