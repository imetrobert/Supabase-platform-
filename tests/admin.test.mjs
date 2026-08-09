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

async function newPage({ isAdmin = true } = {}) {
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

await browser.close();
server.close();

if (problems.length) {
  console.error('\nFAILURES:\n' + problems.map((p) => `  ✗ ${p}`).join('\n'));
  process.exit(1);
}
console.log('\nAccess Rights: all checks passed.');
