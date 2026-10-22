const test=require('node:test'),assert=require('node:assert/strict');
const W=require('./buddy-website-signins.js');

test('remembered website sign-ins are listed by site and account, with Replace and Remove, and never a password',()=>{
 const list=[{origin:'https://shop.example',username:'ada@example.com',site:'shop.example',password:'never-shown'},{origin:'https://journal.example:8443',username:''}];
 const html=W.html(list);
 assert.match(html,/shop\.example/);assert.match(html,/ada@example\.com/);assert.match(html,/journal\.example:8443/);
 assert.match(html,/The account this site asks for/,'an entry without a username says what it is for');
 assert.equal((html.match(/data-website-replace=/g)||[]).length,2);assert.equal((html.match(/data-website-remove=/g)||[]).length,2);
 assert.ok(!html.includes('never-shown'),'a password is never drawn, even if one were handed over');
 assert.ok(!html.includes('type="password"'),'no field until Replace is chosen');
});

test('Replace opens a masked field for that entry only; while busy its buttons wait; nothing yet and loading say so',()=>{
 const list=[{origin:'https://shop.example',username:'ada@example.com'},{origin:'https://other.example',username:'bo@example.com'}];
 const key=W.keyOf(list[0]);
 const editing=W.html(list,{editing:key});
 assert.equal((editing.match(/type="password"/g)||[]).length,1);
 assert.match(editing,/aria-label="New password for shop\.example"/);assert.match(editing,/autocomplete="off"/);
 assert.match(W.html(list,{busy:new Set([W.keyOf(list[1])])}),/Removing…/);
 assert.match(W.html([]),/None yet/);assert.match(W.html(null),/Loading/);
 assert.match(W.html(list,{error:'Keychain is locked.'}),/role="alert">Keychain is locked\./);
 assert.match(W.html('<x>'.length?[{origin:'https://a.example',username:'<script>'}]:[]),/&lt;script&gt;/,'escaped');
});
