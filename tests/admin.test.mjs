/** Drives the Access Rights page against a stubbed Supabase. */
import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../docs');
const PORT = 4321;
const problems = [];

const server = http.createServer((req, res) => {
  const file = path.join(ROOT, req.url === '/' ? 'index.html' : req.url.split('?')[0]);
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) return res.writeHead(404).end('nope');
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(fs.readFileSync(file));
});
await new Promise((r) => server.listen(PORT, r));

const browser = await chromium.launch({ ...(fs.existsSync('/opt/pw-browsers/chromium') ? { executablePath: '/opt/pw-browsers/chromium' } : {}) });

const USERS = [
  { id: 'u-robert', email: 'robert@imetrobert.com', created_at: '2026-05-09T00:00:00Z', last_sign_in_at: '2026-08-09T13:35:51Z' },
  { id: 'u-obou',   email: 'oboulian@gmail.com',    created_at: '2026-08-03T00:00:00Z', last_sign_in_at: '2026-08-03T00:00:00Z' },
  { id: 'u-sheldon',email: 'sheldonrozansky@gmail.com', created_at: '2026-08-02T00:00:00Z', last_sign_in_at: null },
];

async function newPage({ isAdmin = true, inviteError = null } = {}) {
  const page = await browser.newPage();
  const writes = [];
  page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error' && !m.text().includes('Failed to load resource')) problems.push(`console: ${m.text()}`); });

  let grants = [
    { user_id: 'u-robert', app: 'platform',       role: 'app_admin', granted_at: '2026-08-09', granted_by: null },
    { user_id: 'u-robert', app: 'claims-tracker', role: 'member',    granted_at: '2026-08-09', granted_by: null },
    { user_id: 'u-robert', app: 'job',            role: 'member',    granted_at: '2026-08-09', granted_by: null },
    { user_id: 'u-obou',   app: 'legacy-thing',   role: 'member',    granted_at: '2026-08-09', granted_by: null },
  ];

  await page.route('**/auth/v1/**', (route) => {
    if (route.request().url().includes('grant_type=password')) {
      const body = route.request().postDataJSON();
      if (body.password !== 'right') {
        return route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ error_description: 'Invalid login credentials' }) });
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
        access_token: 'tok', refresh_token: 'ref', expires_in: 3600,
        user: { id: 'u-robert', email: 'robert@imetrobert.com' },
      }) });
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
  });

  await page.route('**/rest/v1/rpc/is_platform_admin', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(isAdmin) }));

  await page.route('**/rest/v1/rpc/list_app_users', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(isAdmin ? USERS : []) }));

  await page.route('**/rest/v1/rpc/invite_app_user', (route) => {
    const body = route.request().postDataJSON();
    writes.push({ method: 'INVITE', body });
    if (inviteError) {
      return route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ message: inviteError }) });
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
      user_id: 'u-new', email: body.target_email, granted: (body.grants || []).length,
    }) });
  });

  await page.route('**/rest/v1/app_access**', (route) => {
    const req = route.request();
    if (req.method() === 'POST') {
      const row = req.postDataJSON();
      writes.push({ method: 'POST', row, prefer: req.headers()['prefer'] || '' });
      grants = grants.filter((g) => !(g.user_id === row.user_id && g.app === row.app)).concat(row);
      return route.fulfill({ status: 201, contentType: 'application/json', body: '[]' });
    }
    if (req.method() === 'DELETE') {
      writes.push({ method: 'DELETE', url: req.url() });
      return route.fulfill({ status: 204, body: '' });
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(grants) });
  });

  return { page, writes };
}

const login = async (page, password = 'right') => {
  await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'networkidle' });
  await page.fill('#email', 'robert@imetrobert.com');
  await page.fill('#password', password);
  await page.click('#signin-form button[type="submit"]');
};

/* 1 — a platform admin signs in and sees every account. */
{
  const { page } = await newPage();
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  const emails = await page.locator('.email').allTextContents();
  for (const u of USERS) if (!emails.includes(u.email)) problems.push(`missing user ${u.email}`);
  const badges = await page.locator('.badge').allTextContents();
  if (badges.length !== 1) problems.push(`expected exactly one admin badge, got ${badges.length}`);
  if (!(await page.locator('text=never signed in').count())) problems.push('never-signed-in not surfaced');
  console.log('  ✓ admin sees every account, with the admin badge and sign-in history');
  await page.close();
}

/* 2 — an app present only in the data still appears. */
{
  const { page } = await newPage();
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  if (!(await page.locator('text=legacy-thing').count())) {
    problems.push('a grant for an app missing from APPS was not shown — it would be invisible and unrevokable');
  }
  console.log('  ✓ a grant for an unlisted app is still shown, so it can be revoked');
  await page.close();
}

/* 3 — granting an app sends an upsert with the right row. */
{
  const { page, writes } = await newPage();
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  // Sheldon is the third card; grant him Job Search (4th app row).
  const card = page.locator('.user').nth(2);
  await card.locator('.app-row', { hasText: 'Job Search' }).locator('button', { hasText: 'Member' }).click();
  await page.waitForFunction(() => document.getElementById('status')?.textContent?.startsWith('Saved'), { timeout: 5000 });
  const post = writes.find((w) => w.method === 'POST');
  if (!post) problems.push('granting sent no write');
  else {
    if (post.row.user_id !== 'u-sheldon') problems.push(`granted to the wrong user: ${post.row.user_id}`);
    if (post.row.app !== 'job') problems.push(`granted the wrong app: ${post.row.app}`);
    if (post.row.role !== 'member') problems.push(`granted the wrong role: ${post.row.role}`);
    if (post.row.granted_by !== 'u-robert') problems.push('granted_by was not recorded');
    if (!post.prefer.includes('merge-duplicates')) problems.push('upsert did not ask for merge-duplicates');
  }
  console.log('  ✓ granting upserts the right row and records who granted it');
  await page.close();
}

/* 4 — revoking deletes by the composite key, not by user alone. */
{
  const { page, writes } = await newPage();
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  const card = page.locator('.user').filter({ hasText: 'robert@imetrobert.com' }).first();
  await card.locator('.app-row', { hasText: 'Claims Tracker' }).locator('button', { hasText: 'None' }).click();
  await page.waitForFunction(() => document.getElementById('status')?.textContent?.startsWith('Saved'), { timeout: 5000 });
  const del = writes.find((w) => w.method === 'DELETE');
  if (!del) problems.push('revoking sent no delete');
  else {
    if (!del.url.includes('user_id=eq.u-robert')) problems.push('delete did not scope to the user');
    if (!del.url.includes('app=eq.claims-tracker')) problems.push('delete did not scope to the app — it would revoke everything');
  }
  console.log('  ✓ revoking deletes only that one grant');
  await page.close();
}

/* 5 — you cannot remove your own admin rights and lock yourself out. */
{
  const { page, writes } = await newPage();
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  const card = page.locator('.user').filter({ hasText: 'robert@imetrobert.com' }).first();
  await card.locator('.app-row', { hasText: 'Access Rights' }).locator('button', { hasText: 'No' }).click();
  await page.waitForSelector('#status.err', { timeout: 5000 });
  const msg = await page.locator('#status').textContent();
  if (!msg.includes('lock you out')) problems.push(`unclear self-lockout refusal: "${msg}"`);
  if (writes.length) problems.push('self-lockout was refused in the UI but still sent a write');
  console.log('  ✓ removing your own admin rights is refused, and sends nothing');
  await page.close();
}

/* 6 — promoting someone else to admin asks first. */
{
  const { page, writes } = await newPage();
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  page.on('dialog', (d) => d.dismiss());
  const card = page.locator('.user').filter({ hasText: 'oboulian@gmail.com' }).first();
  await card.locator('.app-row', { hasText: 'Access Rights' }).locator('button', { hasText: 'Admin' }).click();
  await page.waitForTimeout(500);
  if (writes.length) problems.push('declining the confirmation still granted admin');
  console.log('  ✓ promoting another account to admin asks first, and cancelling writes nothing');
  await page.close();
}

/* 7 — a non-admin is turned away and signed out. */
{
  const { page } = await newPage({ isAdmin: false });
  await login(page);
  await page.waitForSelector('#signin-error:not(.hidden)', { timeout: 5000 });
  if (await page.locator('#admin-view').isVisible()) problems.push('a non-admin saw the grants page');
  const stored = await page.evaluate(() => localStorage.getItem('access-rights.session'));
  if (stored) problems.push('a refused account was left signed in');
  console.log('  ✓ a non-admin is refused and signed back out');
  await page.close();
}

/* 8 — a wrong password reports the server message. */
{
  const { page } = await newPage();
  await login(page, 'wrong');
  await page.waitForSelector('#signin-error:not(.hidden)', { timeout: 5000 });
  const msg = await page.locator('#signin-error').textContent();
  if (!msg.includes('Invalid login credentials')) problems.push(`unhelpful error: "${msg}"`);
  console.log('  ✓ a wrong password reports the server message');
  await page.close();
}

/* 9 — inviting sends the address and the chosen apps, and nothing else. */
{
  const { page, writes } = await newPage();
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  await page.click('#invite-toggle');
  await page.fill('#invite-email', 'new@example.com');
  await page.locator('#invite-apps .app-row', { hasText: 'Job Search' }).locator('button', { hasText: 'Member' }).click();
  await page.locator('#invite-apps .app-row', { hasText: 'ETF Tracker' }).locator('button', { hasText: 'Admin' }).click();
  await page.click('#invite-send');
  await page.waitForFunction(() => document.getElementById('status')?.textContent?.startsWith('Invitation sent'), { timeout: 5000 });

  const invite = writes.find((w) => w.method === 'INVITE');
  if (!invite) problems.push('the invite form sent nothing');
  else {
    if (invite.body.target_email !== 'new@example.com') problems.push(`invited the wrong address: ${invite.body.target_email}`);
    const sent = JSON.stringify([...invite.body.grants].sort((a, b) => a.app.localeCompare(b.app)));
    if (sent !== '[{"app":"etf","role":"app_admin"},{"app":"job","role":"member"}]') {
      problems.push(`invited with the wrong access: ${sent}`);
    }
  }
  // The form must not offer platform — the function refuses it, and a control
  // that always fails is worse than no control.
  if (await page.locator('#invite-apps').locator('text=Access Rights').count()) {
    problems.push('the invite form offered platform admin, which invite_app_user refuses');
  }
  console.log('  ✓ inviting sends the address and exactly the apps chosen');
  await page.close();
}

/* 10 — the form resets, so the next invitation cannot inherit this one's apps. */
{
  const { page, writes } = await newPage();
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  await page.click('#invite-toggle');
  await page.fill('#invite-email', 'first@example.com');
  await page.locator('#invite-apps .app-row', { hasText: 'Job Search' }).locator('button', { hasText: 'Member' }).click();
  await page.click('#invite-send');
  await page.waitForFunction(() => document.getElementById('status')?.textContent?.startsWith('Invitation sent'), { timeout: 5000 });

  page.on('dialog', (d) => d.dismiss());
  await page.click('#invite-toggle');
  if (await page.inputValue('#invite-email')) problems.push('the address stayed in the form after sending');
  const pressed = await page.locator('#invite-apps button[aria-pressed="true"]').allTextContents();
  if (pressed.some((label) => label !== 'None')) {
    problems.push(`the previous invitation's apps were still selected: ${pressed.join(', ')}`);
  }
  await page.click('#invite-send');
  await page.waitForTimeout(400);
  if (writes.filter((w) => w.method === 'INVITE').length !== 1) {
    problems.push('inviting with no apps did not ask first, or sent anyway after being cancelled');
  }
  console.log('  ✓ the form resets, and inviting with no access asks first');
  await page.close();
}

/* 11 — a refusal from the database is shown as it came. */
{
  const { page } = await newPage({ inviteError: 'robert@imetrobert.com already has an account — set their access from the grid instead' });
  await login(page);
  await page.waitForSelector('#admin-view:not(.hidden)', { timeout: 5000 });
  await page.click('#invite-toggle');
  await page.fill('#invite-email', 'robert@imetrobert.com');
  await page.locator('#invite-apps .app-row', { hasText: 'Job Search' }).locator('button', { hasText: 'Member' }).click();
  await page.click('#invite-send');
  await page.waitForSelector('#status.err', { timeout: 5000 });
  const msg = await page.locator('#status').textContent();
  if (!msg.includes('already has an account')) problems.push(`the refusal was not shown: "${msg}"`);
  if (await page.isDisabled('#invite-send')) problems.push('a failed invitation left the form unusable');
  console.log('  ✓ a refused invitation shows the reason and lets you try again');
  await page.close();
}

/* ── The page the invitation email lands on ──────────────────────────── */

async function newInvitePage({ granted = [], updateFails = null } = {}) {
  const page = await browser.newPage();
  const calls = [];
  page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error' && !m.text().includes('Failed to load resource')) problems.push(`console: ${m.text()}`); });

  await page.route('**/auth/v1/verify', (route) => {
    calls.push({ method: 'VERIFY', body: route.request().postDataJSON() });
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ access_token: 'tok-from-hash' }) });
  });

  await page.route('**/auth/v1/user', (route) => {
    const req = route.request();
    if (req.method() === 'PUT') {
      calls.push({ method: 'PUT', body: req.postDataJSON(), auth: req.headers()['authorization'] });
      if (updateFails) {
        return route.fulfill({ status: 422, contentType: 'application/json', body: JSON.stringify({ message: updateFails }) });
      }
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'u-new', email: 'new@example.com' }) });
  });

  await page.route('**/rest/v1/app_access**', (route) => {
    calls.push({ method: 'GRANTS', url: route.request().url() });
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(granted) });
  });

  return { page, calls };
}

const STRONG = 'Correct-Horse-42';

/* 12 — a weak password cannot be submitted, and the rules say why. */
{
  const { page } = await newInvitePage();
  await page.goto(`http://localhost:${PORT}/invite.html#access_token=tok&type=invite`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#form-view:not(.hidden)', { timeout: 5000 });

  await page.fill('#password', 'short');
  await page.fill('#confirm', 'short');
  if (!(await page.isDisabled('#save'))) problems.push('a five-character password could be submitted');
  const met = await page.locator('.rules li.met').count();
  if (met !== 1) problems.push(`"short" satisfied ${met} rules, expected only the lowercase one`);

  await page.fill('#password', STRONG);
  await page.fill('#confirm', STRONG);
  if (await page.isDisabled('#save')) problems.push(`a password meeting every rule was still refused: ${STRONG}`);

  // Mismatch is the slip that produces an account nobody can sign into.
  await page.fill('#confirm', STRONG + 'x');
  if (!(await page.isDisabled('#save'))) problems.push('a mistyped confirmation could be submitted');
  console.log('  ✓ the password rules are enforced before anything is sent');
  await page.close();
}

/* 13 — setting a password uses the invitation's session, and the token does
        not stay in the address bar afterwards. */
{
  const { page, calls } = await newInvitePage({
    granted: [
      { app: 'job', role: 'member' },
      { app: 'etf', role: 'app_admin' },
      // Every app this page knows about now has an address, so the only way to
      // reach the no-address path is an app it does not know — a legacy grant,
      // or one added to the project before anyone updated this list.
      { app: 'legacy-thing', role: 'member' },
    ],
  });
  await page.goto(`http://localhost:${PORT}/invite.html#access_token=tok&type=invite`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#form-view:not(.hidden)', { timeout: 5000 });

  if (page.url().includes('access_token')) problems.push('the access token was left in the address bar');
  if (!(await page.locator('#for-whom').textContent()).includes('new@example.com')) {
    problems.push('the page did not say who the invitation is for');
  }

  await page.fill('#password', STRONG);
  await page.fill('#confirm', STRONG);
  await page.click('#save');
  await page.waitForSelector('#done-view:not(.hidden)', { timeout: 5000 });

  const put = calls.find((c) => c.method === 'PUT');
  if (!put) problems.push('no password was sent');
  else {
    if (put.body.password !== STRONG) problems.push('the wrong password was sent');
    if (put.auth !== 'Bearer tok') problems.push(`the invitation session was not used: ${put.auth}`);
  }

  const shown = await page.locator('#access').textContent();
  if (!shown.includes('Job Search') || !shown.includes('ETF Tracker')) {
    problems.push(`the apps they were granted were not listed: "${shown}"`);
  }
  // The address is the point of this screen — a name alone tells someone they
  // have something without telling them where it is.
  const link = page.locator('#access a.app-url', { hasText: 'jobs.imetrobert.com' });
  if (!(await link.count())) problems.push('the granted app was listed without its address');
  else if (await link.getAttribute('href') !== 'https://jobs.imetrobert.com') {
    problems.push(`the app link pointed somewhere else: ${await link.getAttribute('href')}`);
  }
  // An app this page has never heard of must still be named, not silently
  // dropped — a stale list cannot be allowed to hide access that was granted.
  const unknown = page.locator('#access li', { hasText: 'legacy-thing' });
  if (!(await unknown.count())) problems.push('an app with no address on file vanished from the list');
  if (await unknown.locator('a').count()) problems.push('an app with no address on file was given a link anyway');
  if (!shown.includes('administrator')) problems.push('the admin role was not shown');

  // Only what they were given. The read policy widens to the whole table for a
  // platform admin, so leaving this to RLS would show an admin who landed here
  // every grant on the project as though it were theirs.
  const fetched = calls.find((c) => c.method === 'GRANTS');
  if (!fetched?.url.includes('user_id=eq.u-new')) {
    problems.push(`the granted apps were read unscoped: ${fetched?.url}`);
  }
  if (await page.locator('#access li').count() !== 3) {
    problems.push('the list showed something other than the apps they were granted');
  }
  const stored = await page.evaluate(() => Object.keys(localStorage).length);
  if (stored) problems.push('the invitation session was left in localStorage on a possibly shared device');
  console.log('  ✓ the password is set on the invitation session, and nothing is left behind');
  await page.close();
}

/* 14 — the token_hash form of the link works too. It is the shape Supabase
        sends on some projects, and the one nobody would notice was broken. */
{
  const { page, calls } = await newInvitePage();
  await page.goto(`http://localhost:${PORT}/invite.html?token_hash=abc123&type=invite`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#form-view:not(.hidden)', { timeout: 5000 });
  const verify = calls.find((c) => c.method === 'VERIFY');
  if (!verify) problems.push('a token_hash link was not exchanged for a session');
  else if (verify.body.token_hash !== 'abc123' || verify.body.type !== 'invite') {
    problems.push(`the wrong verification was sent: ${JSON.stringify(verify.body)}`);
  }
  console.log('  ✓ a token_hash invitation link is redeemed too');
  await page.close();
}

/* 15 — an expired link says so instead of showing an empty form. */
{
  const { page } = await newInvitePage();
  await page.goto(`http://localhost:${PORT}/invite.html#error=access_denied&error_description=Email+link+is+invalid+or+has+expired`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#bad-view:not(.hidden)', { timeout: 5000 });
  const msg = await page.locator('#bad-message').textContent();
  if (!msg.includes('invalid or has expired')) problems.push(`unclear expired-link message: "${msg}"`);
  if (await page.locator('#form-view').isVisible()) problems.push('an expired link still showed the password form');
  console.log('  ✓ an expired link explains itself');
  await page.close();
}

await browser.close();
server.close();

if (problems.length) {
  console.error('\nFAILURES:\n' + problems.map((p) => `  ✗ ${p}`).join('\n'));
  process.exit(1);
}
console.log('\nAccess Rights: all checks passed.');
