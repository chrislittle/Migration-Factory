/* SEC-REPORT-1: osText escaped the OS on one path and not the other.
 *
 *   if (!sku) return os ? `${os} <span ...>` : ...     // RAW
 *   return `${esc(os)} <span ...>${esc(sku)}</span>`;  // escaped
 *
 * The raw branch runs when a machine has no image SKU - a custom image, or a
 * machine built from a managed disk. NOT exploitable: `os` is
 * storageProfile.osDisk.osType, which Azure fills with Windows or Linux. But a
 * field escaped on one branch and not the other is a trap for whoever widens
 * it next, and the branch that is missing the escape is the rarer one, so it
 * would have been the harder bug to see.
 */
'use strict';
const { lift, test, ok, run } = require('./_harness');

const osText = lift('migrations.html', 'osText');

global.esc = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
global.UX_MISC = { osUnknownVersion: 'version unknown', osUnknown: 'not recorded' };
global.OS_SKU_NAMES = [];

test('the NO-SKU path escapes the operating system name', () => {
  const out = osText({ assessment: { os: '<img src=x onerror=alert(1)>', osVersion: '' } });
  ok(!out.includes('<img src=x'), 'the raw branch is the one that was missing esc()');
  ok(out.includes('&lt;img src=x'), 'and it is escaped now');
});

test('the WITH-SKU path still escapes both, as it always did', () => {
  const out = osText({ assessment: { os: '<b>Windows</b>', osVersion: '<i>2022</i>' } });
  ok(!out.includes('<b>Windows</b>'), 'os escaped');
  ok(!out.includes('<i>2022</i>'), 'sku escaped');
});

test('and the ordinary case still reads as it should', () => {
  const out = osText({ assessment: { os: 'Windows', osVersion: '' } });
  ok(out.includes('Windows'), 'the name survives');
  ok(out.includes('version unknown'), 'with the note that the version is not known');
});

test('a machine with no OS at all says so, rather than rendering empty', () => {
  const out = osText({ assessment: {} });
  ok(out.includes('not recorded'), 'unknown stays unknown');
});

run();
