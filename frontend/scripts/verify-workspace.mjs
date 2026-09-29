// Run against start.sh. Uses local data; never invokes parsing or model APIs.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const base = process.env.PAPERICO_TEST_URL || 'http://127.0.0.1:5173';
const output = fileURLToPath(new URL('../../docs/verification/ui-rollback-2026-09-28/', import.meta.url));
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 960 } });
const errors = [];
const checks = [];
page.on('pageerror', (error) => errors.push(error.message));
const papers = await (await page.request.get(`${base}/api/papers`)).json();
assert(papers.length >= 2, 'Verification needs at least two local papers');
const shot = (name) => page.screenshot({ path: `${output}/${name}.png`, animations: 'disabled' });
const checkPdf = async () => {
  await page.waitForFunction(() => {
    const canvas = document.querySelector('.pdf-page-shell canvas');
    if (!canvas || canvas.width < 250) return false;
    const { data } = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height);
    // Wait for visible PDF ink, not just an empty canvas element.
    for (let i = 0; i < data.length; i += 68) if (data[i + 3] && data[i] < 180) return true;
    return false;
  });
  assert.equal(await page.locator('.pdf-reader-error').count(), 0);
};

try {
  await page.goto(`${base}/library`);
  await page.locator('.paper-library-card').first().waitFor();
  assert.equal(await page.locator('.paper-library-card').count(), papers.length);
  assert.equal(await page.locator('.research-topbar, .library-intro, .paper-card-footer').count(), 0);
  assert(await page.locator('.page-nav-slot .reader-brand-button').isVisible());
  assert(await page.locator('.library-heading').isVisible());
  assert(await page.getByRole('button', { name: '上传论文', exact: true }).evaluate((el) => el.parentElement.classList.contains('library-toolbar')));
  await shot('library-restored');
  await page.getByRole('button', { name: '选择', exact: true }).click();
  await page.locator('.paper-card-selector').first().click();
  assert.match(await page.locator('.library-selection-bar').innerText(), /已选择 1 篇/);
  await page.getByRole('button', { name: '完成', exact: true }).click();
  await page.getByRole('button', { name: '上传论文', exact: true }).click();
  await page.getByText('点击选择 PDF 文件', { exact: true }).waitFor();
  await page.locator('.fixed.inset-0.z-50 button').first().click();
  checks.push('original navigation, compact library, selection and upload dialog');
  await page.goto(`${base}/`);
  await page.locator('.home-hero').waitFor();
  assert(await page.locator('.hero-orbit').isVisible());
  assert.match(await page.locator('.hero-copy h1').innerText(), /真正理解论文/);
  await shot('home-restored');
  checks.push('original home copy and illustration');
  await page.goto(`${base}/library`);
  await page.locator('.paper-library-card').first().click();
  await page.locator('.paper-document').waitFor();
  await shot('reader-text-restored');
  await page.getByRole('button', { name: '切换到原始 PDF', exact: true }).click();
  await checkPdf();
  await shot('reader-pdf-restored');
  await page.getByRole('button', { name: '切换到文本精读', exact: true }).click();
  await page.locator('.paper-document').waitFor();
  checks.push('original reader switches between text and rendered PDF');
  const legacy = papers.find((paper) => paper.id === '72802d5d0d31');
  if (legacy) {
    await page.goto(`${base}/paper/${legacy.id}?view=pdf`);
    await checkPdf();
    checks.push('legacy None.pdf still renders');
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`${base}/library`);
  await page.locator('.paper-library-card').first().waitFor();
  await page.getByRole('button', { name: '打开项目分组', exact: true }).click();
  assert(await page.locator('.library-sidebar.mobile-open').isVisible());
  await page.locator('.library-sidebar').getByRole('button', { name: '关闭项目分组', exact: true }).click();
  await shot('library-mobile-restored');
  await page.goto(`${base}/paper/${papers[0].id}?view=pdf`);
  await checkPdf();
  await shot('reader-mobile-restored');
  checks.push('original mobile drawer and PDF reader');
  assert.deepEqual(errors, [], 'No unhandled browser errors');
  await writeFile(`${output}/browser-checks.json`, JSON.stringify({ passed: true, checks, browserErrors: errors }, null, 2));
  console.log(checks.join('\n'));
} catch (error) {
  await shot('browser-failure');
  await writeFile(`${output}/browser-checks.json`, JSON.stringify({ passed: false, checks, browserErrors: errors, failure: String(error) }, null, 2));
  throw error;
} finally {
  await browser.close();
}
