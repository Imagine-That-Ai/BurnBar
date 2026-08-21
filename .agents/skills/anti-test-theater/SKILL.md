---
name: anti-test-theater
description: Prevents 'tests pass, user fails' test theater, tautological assertions, mock-heavy non-tests, and trivial assertions that pass while user flows are broken.
---

# Anti-Test Theater: Real Verification over Green CI (@sirstripy)

Eliminates "tests pass, user fails" test suites where AI writes tests that test only the mocks, verify nothing about real execution, or assert tautologies to achieve fake 100% coverage.

---

## 1. Hallmarks of Test Theater

- ❌ **Mocking the unit under test:** Mocking internal logic so heavily that the test only asserts the mock was called.
- ❌ **Tautological assertions:** `expect(response).toBeDefined()`, `expect(result.length >= 0).toBe(true)`, `expect(true).toBe(true)`.
- ❌ **Testing implementation details instead of behavior:** Asserting that a private method was called 1 time instead of asserting the actual output/state change.
- ❌ **Ignoring negative / error / boundary conditions:** Testing only the happy path where all inputs are pre-sanitized constants.
- ❌ **Mocks that drift from reality:** Mocking an external service with an outdated or fictional schema that passes in CI while failing in production.

---

## 2. Bad vs Good Tests

```typescript
// ❌ TEST THEATER: Mocks everything, tests nothing, asserts triviality
test("processPayment works", async () => {
  const mockGateway = { charge: jest.fn().mockResolvedValue({ success: true }) };
  const service = new PaymentService(mockGateway);
  const result = await service.processPayment({ amount: 100 });
  expect(mockGateway.charge).toHaveBeenCalled();
  expect(result).toBeDefined(); // Tautology: ignores currency, status, idempotency key
});

// ✅ REAL BEHAVIOR TEST: Verifies state changes, contracts, and failure handling
test("processPayment generates idempotency key and records transaction", async () => {
  const gateway = new MockPaymentGateway();
  const db = createTestDatabase();
  const service = new PaymentService(gateway, db);

  const result = await service.processPayment({
    userId: "usr_123",
    amountCents: 5000,
    currency: "USD"
  });

  expect(result.status).toBe("succeeded");
  expect(result.transactionId).toMatch(/^tx_[a-zA-Z0-9]+$/);
  
  // Verify persistence
  const savedTx = await db.transactions.findById(result.transactionId);
  expect(savedTx.amountCents).toBe(5000);
  expect(savedTx.status).toBe("succeeded");
});
```

---

## 3. The Anti-Theater Test Checklist

1. **Would this test fail if the core business logic was deleted or inverted?** If not, the test is theater.
2. **Does the test verify the final observable outcome (DB state, return value, HTTP response)?**
3. **Does the suite test error branches, edge cases, zero-values, and invalid inputs?**
4. **Are integration and E2E boundaries exercised with realistic data?**
