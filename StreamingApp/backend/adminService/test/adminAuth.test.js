const { test } = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes } = require('node:crypto');
const jwt = require('jsonwebtoken');
const { adminAuth } = require('../middleware/adminAuth');

// Generated exclusively for this test process. No AWS secrets are needed.
process.env.JWT_SECRET = randomBytes(32).toString('hex');

function invoke(token) {
  const req = {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  };

  const res = {
    statusCode: 200,
    body: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };

  let nextCalls = 0;
  adminAuth(req, res, () => {
    nextCalls += 1;
  });

  return { req, res, nextCalls };
}

function sign(role, options = {}) {
  return jwt.sign(
    {
      sub: 'capstone-test-user',
      email: 'test@example.com',
      role,
    },
    process.env.JWT_SECRET,
    { expiresIn: '5m', ...options },
  );
}

function assertDenied(result, status) {
  assert.equal(result.res.statusCode, status);
  assert.equal(result.res.body.success, false);
  assert.equal(result.nextCalls, 0);
  assert.equal(result.req.user, undefined);
}

test('rejects requests without an authorization token', () => {
  assertDenied(invoke(), 401);
});

test('rejects malformed tokens', () => {
  assertDenied(invoke('not-a-valid-jwt'), 401);
});

test('rejects tokens signed with a different secret', () => {
  const token = jwt.sign(
    { sub: 'capstone-test-user', role: 'admin' },
    randomBytes(32).toString('hex'),
  );

  assertDenied(invoke(token), 401);
});

test('rejects expired admin tokens', () => {
  assertDenied(invoke(sign('admin', { expiresIn: -60 })), 401);
});

test('rejects authenticated users without admin privileges', () => {
  assertDenied(invoke(sign('user')), 403);
});

test('allows a valid admin and passes identity to the next handler', () => {
  const result = invoke(sign('admin'));

  assert.equal(result.nextCalls, 1);
  assert.equal(result.res.body, undefined);
  assert.deepEqual(result.req.user, {
    _id: 'capstone-test-user',
    email: 'test@example.com',
    role: 'admin',
  });
});