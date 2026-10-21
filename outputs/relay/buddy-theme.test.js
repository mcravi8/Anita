const test=require('node:test'),assert=require('node:assert/strict');
const Theme=require('./buddy-theme.js');
test('the chosen appearance resolves to light or dark, and Match system follows the OS',()=>{
  assert.equal(Theme.resolve('light',true),'light');assert.equal(Theme.resolve('dark',false),'dark');
  assert.equal(Theme.resolve('system',true),'dark');assert.equal(Theme.resolve('system',false),'light');
});
test('a missing or unknown saved choice is light, so existing workspaces look unchanged',()=>{
  for(const value of [undefined,null,'',7,'sepia','Dark'])assert.equal(Theme.normalize(value),'light');
  assert.equal(Theme.resolve(undefined,true),'light');
});
test('the settings block offers exactly Light, Dark and Match system and marks the current one',()=>{
  const state={theme:'dark'};Theme.init({state:()=>state,save(){}});
  const html=Theme.section();
  assert.deepEqual([...html.matchAll(/data-theme-choice="(\w+)"/g)].map(m=>m[1]),['light','dark','system']);
  assert.deepEqual([...html.matchAll(/aria-pressed="(\w+)"/g)].map(m=>m[1]),['false','true','false']);
  for(const label of ['Light','Dark','Match system'])assert.ok(html.includes(`>${label}</span>`),label);
  assert.match(html,/role="group" aria-label="Appearance"/);assert.doesNotMatch(html,/role="radio"/,'toggle buttons, so no arrow-key radio contract is promised');
});
test('the page picks its theme before any stylesheet loads, from the choice remembered at the last change',()=>{
  const html=require('node:fs').readFileSync(__dirname+'/index.html','utf8'),script=html.match(/<script>(try\{var a=[\s\S]*?)<\/script>/)?.[1];
  assert.ok(script&&html.indexOf(script)<html.indexOf('rel="stylesheet"'),'an inline script runs before the first stylesheet');
  const theme=(stored,systemDark)=>{const el={dataset:{}},store={getItem:()=>stored};require('node:vm').runInNewContext(script,{localStorage:store,matchMedia:()=>({matches:systemDark}),document:{documentElement:el}});return el.dataset.theme;};
  assert.equal(theme('dark',false),'dark');assert.equal(theme('light',true),'light');assert.equal(theme('system',true),'dark');assert.equal(theme('system',false),'light');assert.equal(theme(null,true),'light','nothing remembered means light, as before');
  assert.equal(theme('sepia',true),'light');
  const broken=()=>{const el={dataset:{}};require('node:vm').runInNewContext(script,{localStorage:{getItem(){throw Error('blocked');}},matchMedia:()=>({matches:true}),document:{documentElement:el}});return el.dataset.theme;};
  assert.equal(broken(),undefined,'storage that throws leaves the default, it does not break the page');
});
test('choosing saves the choice into the workspace state once',()=>{
  const state={},saves=[];Theme.init({state:()=>state,save:()=>saves.push(state.theme)});
  global.document={querySelectorAll:()=>[],documentElement:{dataset:{},style:{}},querySelector:()=>null};
  Theme.choose('system');Theme.choose('nonsense');
  assert.equal(state.theme,'system');assert.deepEqual(saves,['system']);
  delete global.document;
});
