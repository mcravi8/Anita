const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const marked=require('./vendor/marked.umd.js');
// Parser/URL checks here; the actual DOMPurify pipeline is checked in the browser.
function formatter(){const context={marked,URL,DOMPurify:{sanitize:html=>html}};vm.createContext(context);vm.runInContext(fs.readFileSync(`${__dirname}/buddy-markdown.js`,'utf8'),context);return context.BuddyMarkdown;}
test('a real reply becomes headings, emphasis, lists, code and labeled links',()=>{const html=formatter().render('A **clear** summary.\n\n### Urgent\n- **Cedar:** Review `draft.md`. [Email](https://mail.google.com/mail/u/0/#all/example)\n- A second item.');for(const expected of ['<strong>clear</strong>','<h3>Urgent</h3>','<ul>','<li>','<code>draft.md</code>','>Email</a>'])assert.ok(html.includes(expected));assert.ok(!html.includes('### Urgent'));});
test('HTML, image requests and unsafe link schemes cannot become active reply content',()=>{const html=formatter().render('<img src="https://example.com/private" onerror="alert(1)">\n\n![tracking](https://example.com/pixel) [bad](javascript:alert%281%29) [data](data:text/html,test) [safe](https://example.com/?q=%22)');assert.ok(!/<img\b|onerror=\"|href=\"(?:javascript:|data:)/.test(html));assert.ok(html.includes('&lt;img'));assert.ok(html.includes('>safe</a>'));});
test('code fences and table structure survive formatting without executing code',()=>{const html=formatter().render('```html\n<script>alert(1)</script>\n```\n\n| Task | Owner |\n| --- | --- |\n| Copy | Cedar |');assert.ok(html.includes('<pre><code'));assert.ok(html.includes('&lt;script&gt;'));assert.ok(html.includes('<div class="reply-table"><table>'));assert.ok(html.includes('<th>Task</th>'));});

test('a message already rendered is not rendered again, and the parser is built once',()=>{
 let built=0,parsed=0;class Counting extends marked.Marked{constructor(...a){super(...a);built++;const inner=this.parse;this.parse=(...b)=>{parsed++;return inner(...b);};}}
 const context={marked:{Marked:Counting},URL,DOMPurify:{sanitize:html=>html}};vm.createContext(context);vm.runInContext(fs.readFileSync(`${__dirname}/buddy-markdown.js`,'utf8'),context);
 const md=context.BuddyMarkdown,first=md.render('A **clear** summary.'),second=md.render('A **clear** summary.');md.render('Another message');
 assert.equal(first,second);assert.equal(parsed,2,'two different messages are parsed once each');assert.equal(built,1,'one parser serves every message');
});

test('a preview of an older group message keeps the speaker\'s name once',()=>{
 const md=formatter();
 assert.equal(md.preview('**Chief** **Chief:** Start at the first microstage.'),'Chief: Start at the first microstage.');
 assert.equal(md.preview('**Lyra** **Lyra: Research-track action plan (draft)**\n\nStatus labels: nothing is verified.').startsWith('Lyra: Research-track action plan (draft)'),true);
 assert.equal(md.preview('**Lyra** **Lyra: Research-track action plan (draft)**\n\nBody').includes('**'),false,'no stray bold markers are left');
 assert.equal(md.preview('Chief: Start at the first microstage.'),'Chief: Start at the first microstage.','a message that is already clean is left alone');
 assert.equal(md.preview('**Important** note about Chief'),'**Important** note about Chief','a bold word that is not a doubled speaker is left alone');
});
