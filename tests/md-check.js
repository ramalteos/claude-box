// Checks the dashboard's markdown renderer: it must produce structure, and never live
// markup from a document. Task documents are agent-written and the page carries an action
// token, so an injection here would be an injection with privileges.
//
// Usage: node tests/md-check.js <extracted-md-source.js>
const fs = require('fs');
// The extracted slice may touch browser globals in passing; stub them so the two functions
// under test can be evaluated in isolation.
global.document = { querySelectorAll: () => [], getElementById: () => null, addEventListener() {} };
global.window = {};
global.setInterval = () => 0;
eval(fs.readFileSync(process.argv[2], 'utf8'));   // defines esc() and md()

const ALLOWED = new Set(['p', 'h1', 'h2', 'h3', 'h4', 'ul', 'ol', 'li', 'code', 'pre',
                         'strong', 'em', 'blockquote', 'hr', 'a', 'br', 'span', 'div']);
const attacks = [
  '<script>fetch("/api/action")</script>',
  '<img src=x onerror=alert(1)>',
  '[click](javascript:alert(1))',
  '<iframe src="http://evil"></iframe>',
  '<a href="javascript:alert(1)">x</a>',
];
const bad = [];
for (const src of attacks) {
  const html = md(src);
  const tags = [...html.matchAll(/<\/?([a-zA-Z][a-zA-Z0-9]*)/g)].map(m => m[1].toLowerCase());
  const rogue = tags.filter(t => !ALLOWED.has(t));
  if (rogue.length) bad.push(`${src} => rogue tags: ${rogue.join(',')}`);
  if (/href="\s*javascript:/i.test(html)) bad.push(`${src} => javascript: href`);
  if (/<[a-z][^>]*\son[a-z]+\s*=/i.test(html)) bad.push(`${src} => inline handler in a tag`);
}

const good = md('## Heading\n\n- one\n- two\n\n`code` and **bold** and [link](https://x.test)');
for (const [needle, what] of [['<h3>', 'heading'], ['<li>', 'list item'], ['<code>', 'code'],
                              ['<strong>', 'bold'], ['href="https://x.test"', 'link']]) {
  if (!good.includes(needle)) bad.push(`markdown did not render a ${what}`);
}

if (bad.length) { console.log('FAIL\n' + bad.join('\n')); process.exit(1); }
console.log('OK');
