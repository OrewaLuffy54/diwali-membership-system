import test from 'node:test';
import assert from 'node:assert/strict';

function quoteCoupon(planPaise, coupon, now = new Date()) {
  if (!coupon.active) throw new Error('Coupon is disabled');
  if (coupon.expires_at && new Date(coupon.expires_at) <= now) throw new Error('Coupon has expired');
  if (coupon.max_uses !== null && coupon.uses >= coupon.max_uses) throw new Error('Coupon usage limit reached');
  const discount = coupon.discount_type === 'percent'
    ? Math.floor(planPaise * coupon.discount_value / 100)
    : coupon.discount_value;
  return { discount_paise: Math.min(planPaise, discount), amount_paise: Math.max(0, planPaise - discount) };
}

function keyedTransactionLock() {
  const tails = new Map();
  return async (key, action) => {
    const previous = tails.get(key) || Promise.resolve();
    let release;
    const current = new Promise(resolve => { release = resolve; });
    tails.set(key, previous.then(() => current));
    await previous;
    try { return await action(); } finally { release(); }
  };
}

function couponReferenceModel() {
  const lock = keyedTransactionLock();
  const coupon = { exists: true, references: new Set() };
  return {
    coupon,
    submit: paymentId => lock('coupon:TEST10', async () => {
      if (!coupon.exists) throw new Error('Coupon no longer exists');
      coupon.references.add(paymentId);
    }),
    remove: () => lock('coupon:TEST10', async () => {
      if (coupon.references.size) return false;
      coupon.exists = false;
      return true;
    }),
    rename: code => lock('coupon:TEST10', async () => {
      if (coupon.references.size) throw new Error('cannot be renamed after a payment references it');
      return code;
    }),
  };
}

function minecraftAccountModel() {
  const lock = keyedTransactionLock();
  const accounts = new Map();
  let nextId = 0;
  return {
    accounts,
    getOrCreate: (username, userId) => lock(`minecraft:${username}`, async () => {
      const existing = accounts.get(username);
      if (existing) {
        if (existing.userId !== userId) throw new Error('Minecraft username belongs to another account');
        return existing;
      }
      const account = { id: `account-${++nextId}`, userId };
      accounts.set(username, account);
      return account;
    }),
  };
}

test('TEST10 gives 10% off ₹50, leaving ₹45', () => {
  const testCoupon = { code: 'TEST10', active: true, expires_at: '2027-01-01T00:00:00Z', max_uses: 5, uses: 0, discount_type: 'percent', discount_value: 10 };
  assert.deepEqual(quoteCoupon(5000, testCoupon, new Date('2026-11-01T00:00:00Z')), { discount_paise: 500, amount_paise: 4500 });
});

test('expired and disabled coupons are rejected', () => {
  const base = { expires_at: null, max_uses: 1, uses: 0, discount_type: 'percent', discount_value: 10 };
  assert.throws(() => quoteCoupon(5000, { ...base, active: false }), /disabled/);
  assert.throws(() => quoteCoupon(5000, { ...base, active: true, expires_at: '2026-10-31T23:59:59Z' }, new Date('2026-11-01T00:00:00Z')), /expired/);
});

test('usage limits reject a coupon and a quote never increments usage', () => {
  const coupon = { active: true, expires_at: null, max_uses: 1, uses: 0, discount_type: 'percent', discount_value: 10 };
  quoteCoupon(5000, coupon);
  assert.equal(coupon.uses, 0);
  assert.throws(() => quoteCoupon(5000, { ...coupon, uses: 1 }), /usage limit/);
});

test('an approval retry cannot increment coupon usage twice', () => {
  const payment = { status: 'pending' };
  const coupon = { uses: 0 };
  const approveOnce = () => {
    if (payment.status !== 'pending') return 'already_processed';
    payment.status = 'approved';
    coupon.uses += 1;
    return 'approved';
  };
  assert.equal(approveOnce(), 'approved');
  assert.equal(approveOnce(), 'already_processed');
  assert.equal(coupon.uses, 1);
});

test('a concurrent coupon deletion and payment submission are serialized', async () => {
  const deleteFirst = couponReferenceModel();
  const [deleted, submission] = await Promise.allSettled([
    deleteFirst.remove(),
    deleteFirst.submit('payment-1'),
  ]);
  assert.equal(deleted.status, 'fulfilled');
  assert.equal(deleted.value, true);
  assert.equal(submission.status, 'rejected');
  assert.match(submission.reason.message, /no longer exists/);

  const submitFirst = couponReferenceModel();
  const [created, deletion] = await Promise.all([
    submitFirst.submit('payment-2'),
    submitFirst.remove(),
  ]);
  assert.equal(created, undefined);
  assert.equal(deletion, false);
});

test('a coupon code cannot be renamed after any payment reference exists', async () => {
  const model = couponReferenceModel();
  await model.submit('payment-1');
  await assert.rejects(model.rename('NEW10'), /cannot be renamed/);
});

test('concurrent first-time account creation yields one account without overwriting another owner', async () => {
  const model = minecraftAccountModel();
  const [first, second] = await Promise.all([
    model.getOrCreate('PlayerOne', 'user-a'),
    model.getOrCreate('PlayerOne', 'user-a'),
  ]);
  assert.equal(first.id, second.id);
  assert.equal(model.accounts.size, 1);
  await assert.rejects(model.getOrCreate('PlayerOne', 'user-b'), /another account/);
  assert.equal(model.accounts.get('PlayerOne').userId, 'user-a');
});

test('discounts cannot make the payable amount negative', () => {
  const coupon = { active: true, expires_at: null, max_uses: null, uses: 0, discount_type: 'fixed', discount_value: 99999 };
  assert.equal(quoteCoupon(5000, coupon).amount_paise, 0);
});
