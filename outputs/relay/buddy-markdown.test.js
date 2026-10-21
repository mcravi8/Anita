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

// The file links run with the real link resolver and the folder list the page learns from the Mac app.
function withFolders(folders,activeFolderId=''){
 const context={marked,URL,DOMPurify:{sanitize:html=>html}};vm.createContext(context);
 vm.runInContext(fs.readFileSync(`${__dirname}/buddy-file-links.js`,'utf8'),context);vm.runInContext(fs.readFileSync(`${__dirname}/buddy-markdown.js`,'utf8'),context);
 context.BuddyFileLinks.configure({folders,activeFolderId});return context;
}
const research={folderId:'research',name:'Directed Research',location:'/Users/matteo/Desktop/USC/Semester 4/Directed Research',primary:false,available:true};
const own={folderId:'ws',name:'Buddy files',location:'/Users/matteo/Library/Buddy/ws',primary:true,available:true};
const fileLink=(html,path,folder='research')=>new RegExp(`<a href="#" data-action="project-file" data-path="${path.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}" data-folder-id="${folder}"[^>]*>`).test(html);

test('Chief’s link to the finished paper opens it: an absolute path in angle brackets, with spaces, inside a connected folder',()=>{
 const md=withFolders([own,research]).BuddyMarkdown;
 const html=md.render('Stage 4 is done. [**Open the completed Stage 4 paper draft**](</Users/matteo/Desktop/USC/Semester 4/Directed Research/paper_draft.md>)');
 assert.ok(fileLink(html,'paper_draft.md'),html);
 assert.match(html,/><strong>Open the completed Stage 4 paper draft<\/strong><\/a>/,'the words stay the link');
 assert.doesNotMatch(html,/target="_blank"|href="\/Users|file:/,'never a page address');
 assert.ok(fileLink(md.render('[draft](/Users/matteo/Desktop/USC/Semester 4/Directed Research/paper_draft.md)'),'paper_draft.md'),'without angle brackets, spaces and all');
 assert.ok(fileLink(md.render('[draft](/Users/matteo/Desktop/USC/Semester 4/Directed Research/paper_draft.md "The draft")'),'paper_draft.md'),'with a title');
 assert.ok(fileLink(md.render('[draft](file:///Users/matteo/Desktop/USC/Semester%204/Directed%20Research/paper_draft.md)'),'paper_draft.md'),'a file:// address');
 assert.ok(fileLink(md.render('See [the ledger](verification/paper_audit_corrections_2026-10-20.md).'),'verification/paper_audit_corrections_2026-10-20.md','ws'),'a relative path: the primary folder');
 assert.ok(fileLink(withFolders([own,research],'research').BuddyMarkdown.render('See [the ledger](verification/a.md).'),'verification/a.md'),'or the folder the person has open');
 assert.ok(fileLink(md.render('See [the ledger](verification/a.md).',{files:[{folderId:'research',path:'paper_draft.md',revision:'r'}]}),'verification/a.md'),'or the folder the message saved into');
 assert.ok(fileLink(md.within({files:[{folderId:'research',path:'x.md',revision:'r'}]},()=>md.render('See [the ledger](verification/a.md).')),'verification/a.md'),'the message being drawn gives the same hint');
});

test('a path outside the connected folders keeps its words and shows the path on hover; unsafe addresses stay plain text',()=>{
 const md=withFolders([own,research]).BuddyMarkdown;
 const outside=md.render('[notes](</Users/matteo/Documents/Other folder/notes.md>)');
 assert.doesNotMatch(outside,/<a\b/);assert.match(outside,/<span title="\/Users\/matteo\/Documents\/Other folder\/notes\.md">notes<\/span>/);
 for(const text of ['[up](../secret.md)','[up](</Users/matteo/Desktop/USC/Semester 4/Directed Research/../secret.md>)','[x](file://evil.example/Users/matteo/Desktop/USC/Semester%204/Directed%20Research/a.md)'])assert.doesNotMatch(md.render(text),/<a\b/,text);
 const unsafe=md.render('[bad](javascript:alert%281%29) [data](data:text/html,x) [ok](https://example.com)');
 assert.doesNotMatch(unsafe,/javascript:|data:text|data-action/);assert.match(unsafe,/>ok<\/a>/);assert.match(unsafe,/target="_blank"/);
 assert.doesNotMatch(md.render('<a href="#" data-action="project-disconnect">x</a> <span data-action="project-file" data-path="a.md">y</span>'),/<a\b|<span\b/,'only Buddy’s own file links carry an action; written HTML stays text');
 assert.match(md.render('`[code](/Users/matteo/Desktop/USC/Semester 4/Directed Research/a.md)`'),/<code>\[code\]\(\/Users\/matteo\/Desktop\/USC\/Semester 4\/Directed Research\/a\.md\)<\/code>/,'code is left exactly as written');
 assert.match(md.render('```\n[code](/Users/a b/c.md)\n```'),/\[code\]\(\/Users\/a b\/c\.md\)/);
});

test('links drawn before the folders were known become file links once they are',()=>{
 const context=withFolders([]),md=context.BuddyMarkdown,text='[draft](</Users/matteo/Desktop/USC/Semester 4/Directed Research/paper_draft.md>)';
 assert.doesNotMatch(md.render(text),/<a\b/);
 context.BuddyFileLinks.configure({folders:[research]});
 assert.ok(fileLink(md.render(text),'paper_draft.md'),'the remembered rendering is not reused');
});

test('a preview of an older group message keeps the speaker\'s name once',()=>{
 const md=formatter();
 assert.equal(md.preview('**Chief** **Chief:** Start at the first microstage.'),'Chief: Start at the first microstage.');
 assert.equal(md.preview('**Lyra** **Lyra: Research-track action plan (draft)**\n\nStatus labels: nothing is verified.').startsWith('Lyra: Research-track action plan (draft)'),true);
 assert.equal(md.preview('**Lyra** **Lyra: Research-track action plan (draft)**\n\nBody').includes('**'),false,'no stray bold markers are left');
 assert.equal(md.preview('Chief: Start at the first microstage.'),'Chief: Start at the first microstage.','a message that is already clean is left alone');
 assert.equal(md.preview('**Important** note about Chief'),'**Important** note about Chief','a bold word that is not a doubled speaker is left alone');
});
