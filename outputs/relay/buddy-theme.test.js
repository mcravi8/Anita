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
  assert.deepEqual([...html.matchAll(/aria-checked="(\w+)"/g)].map(m=>m[1]),['false','true','false']);
  for(const label of ['Light','Dark','Match system'])assert.ok(html.includes(`>${label}</span>`),label);
  assert.match(html,/role="radiogroup"/);
});
test('choosing saves the choice into the workspace state once',()=>{
  const state={},saves=[];Theme.init({state:()=>state,save:()=>saves.push(state.theme)});
  global.document={querySelectorAll:()=>[],documentElement:{dataset:{},style:{}},querySelector:()=>null};
  Theme.choose('system');Theme.choose('nonsense');
  assert.equal(state.theme,'system');assert.deepEqual(saves,['system']);
  delete global.document;
});
