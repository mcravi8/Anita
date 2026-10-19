// Draws Buddy's current logo (the dot-matrix head from the figure engine) to icon-logo.png, the artwork render-icon.swift puts on the app icon's tile.
// Run it only when the logo changes; the build uses the saved PNG and needs neither Chrome nor Playwright.
//   node make-icon-logo.mjs <path to the playwright-core package>
import {pathToFileURL} from 'node:url';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
const {chromium}=await import(pathToFileURL(path.resolve(process.argv[2]||'../buddy-worker/node_modules/playwright-core/index.mjs')).href);
const here=new URL('.',import.meta.url).pathname,directory=await mkdtemp(path.join(tmpdir(),'buddy-icon-'));
const context=await chromium.launchPersistentContext(directory,{channel:'chrome',headless:true,viewport:{width:900,height:900},deviceScaleFactor:2});
try{
  await context.route('**/*',r=>/^https?:/.test(r.request().url())?r.abort():r.continue());
  const page=context.pages()[0];
  // Reduced motion drops the idle life (blinking, breathing), so the figure is drawn at rest with its eyes open.
  await page.emulateMedia({reducedMotion:'reduce'});
  await page.goto(new URL('../relay/index.html',import.meta.url).href);
  await page.evaluate(()=>{
    document.documentElement.dataset.theme='light';document.getElementById('onboarding-root').innerHTML='';closeModal();
    // Nothing else on the page, and no page colour behind the logo, so the picture has a clear background.
    document.getElementById('app').style.display='none';document.documentElement.style.background='transparent';document.body.style.background='transparent';
    const holder=document.createElement('div');holder.id='icon-logo';holder.style.cssText='position:fixed;left:50px;top:50px;width:800px;height:800px;z-index:99999;background:transparent';
    holder.innerHTML=BuddyFigures.logoHTML(800);document.body.appendChild(holder);
  });
  await page.waitForTimeout(1500);
  await page.locator('#icon-logo canvas').screenshot({path:path.join(here,'icon-logo.png'),omitBackground:true});
}finally{await context.close();await rm(directory,{recursive:true,force:true});}
