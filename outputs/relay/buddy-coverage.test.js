const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/app.js','utf8');
const fn=source.slice(source.indexOf('function reviewCoverage('),source.indexOf('function routineReceipts('));
const context={esc:s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};vm.createContext(context);vm.runInContext(fn,context);
test('prepared answers display original checked time in the collapsed summary and saved-scope explanation',()=>{
 const html=context.reviewCoverage([{id:'source',query:'assessment <script>',read:2,unread:0,partial:false,prepared:true,checkedAt:'2026-10-16T16:00:00Z',at:'2026-10-16T15:59:00Z',routineTitle:'Morning <mail>',pages:2,searchExhausted:true}]);
 const summary=html.match(/<summary>(.*?)<\/summary>/s)[1];assert.match(summary,/From routine · Checked/);assert.match(summary,/Oct/);assert.match(html,/Saved result; mail may have changed/);assert.match(html,/Morning &lt;mail&gt;/);assert.doesNotMatch(html,/<script>/);
});
test('a failed or partial fresh review retains honest unread counts and its gaps',()=>{
 const html=context.reviewCoverage([{query:'assessment',read:1,unread:1,partial:true,pages:1,searchExhausted:false,at:'2026-10-16T16:00:00Z',issues:['Gmail read unavailable']}]);
 assert.match(html,/Email review incomplete/);assert.match(html,/1 unread/);assert.match(html,/More results may remain/);assert.match(html,/Gmail read unavailable/);assert.doesNotMatch(html,/From routine/);
});
