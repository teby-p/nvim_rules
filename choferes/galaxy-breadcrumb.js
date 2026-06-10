// galaxy-breadcrumb.js — scrapea el breadcrumb de una página de instancia de Galaxy.
//
// Conecta via CDP a un Chrome ya corriendo con --remote-debugging-port. Usamos
// el Chrome real (no el Chromium de Playwright) porque Galaxy requiere Microsoft
// Platform SSO con el broker macOS, que solo funciona en el browser instalado
// del sistema con la extensión Microsoft SSO.
//
// Uso:
//   node galaxy-breadcrumb.js <url>     → stdout = breadcrumb text
//
// Env:
//   GALAXY_CDP_URL  default 'http://localhost:9222'
//
// Setup: levantar Chrome con (galaxy.chrome!) o:
//   /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
//     --remote-debugging-port=9222 \
//     --user-data-dir=$HOME/.cache/escort/chrome-debug

const { chromium } = require('playwright');

const CDP_URL = process.env.GALAXY_CDP_URL || 'http://localhost:9222';

async function main() {
  const url = process.argv[2];
  if (!url) {
    console.error('uso: node galaxy-breadcrumb.js <url>');
    process.exit(1);
  }

  let browser;
  try {
    browser = await chromium.connectOverCDP(CDP_URL);
  } catch (e) {
    console.error(
      `No pude conectar a Chrome via CDP en ${CDP_URL}.\n` +
        'Lanzá Chrome con (galaxy.chrome!) desde nvim.\n' +
        `Error: ${e.message}`
    );
    process.exit(2);
  }

  // Primera context = el profile real con su sesión SSO.
  const ctx = browser.contexts()[0];
  if (!ctx) {
    console.error('CDP conectó pero no hay contexts disponibles.');
    process.exit(2);
  }

  const page = await ctx.newPage();
  try {
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    try {
      await page.waitForSelector('.breadcrumbs', { timeout: 15000 });
    } catch {
      console.error(
        `No apareció .breadcrumbs en 15s. URL actual: ${page.url()}\n` +
          '¿Sesión expirada? Re-loguéate en la ventana de Chrome con debug port.'
      );
      process.exit(3);
    }
    const value = await page
      .locator('.breadcrumbs')
      .evaluate((el) => el.lastChild.textContent.replace(/^[›\s]+/, '').trim());
    if (!value) {
      console.error(
        `.breadcrumbs encontrado pero vacío. URL: ${page.url()}\n` +
          'innerHTML:\n' +
          (await page.locator('.breadcrumbs').innerHTML())
      );
      process.exit(4);
    }
    process.stdout.write(value);
  } finally {
    await page.close().catch(() => {});
    // browser.close() en modo CDP solo desconecta — no mata el Chrome real.
    await browser.close().catch(() => {});
  }
}

main().catch((e) => {
  console.error(e.stack || e.message || String(e));
  process.exit(1);
});
