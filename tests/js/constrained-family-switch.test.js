// CONSTRAINED-DEFAULT-1 (review): on the Choose each target page, a machine
// on a constrained vCPU size (DS13-4_v2: 8 vCPUs, 4 active) starts on the
// constrained vCPU size with the same active vCPUs (E8-4ds_v5). A switch of
// the Size family list to D and back to E took the FIRST E size of the list,
// the full size E8ds_v5 (8 active), so per-core licence cost could double
// with no word. The family now starts on familyStartSize.
//
// RUN: the page's own function, lifted out of wizard.html, and the change
// handler of the Size family list read from the page's source.
'use strict';
const { pageSource } = require('./_page-source');
const { lift, test, eq, ok, run } = require('./_harness');

const familyStartSize = lift('wizard.html', 'familyStartSize');

// The order the engine gives: per family the full size first, then its
// constrained vCPU sizes by active vCPUs.
const constrainedSource = [
  { size: 'Standard_D16ds_v5', family: 'D', variant: 'default', vcpus: 16, activeVcpus: 16, memoryGB: 64, best: false },
  { size: 'Standard_E8ds_v5', family: 'E', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 64, best: false },
  { size: 'Standard_E8-2ds_v5', family: 'E', variant: 'constrained', vcpus: 8, activeVcpus: 2, memoryGB: 64, best: false },
  { size: 'Standard_E8-4ds_v5', family: 'E', variant: 'constrained', vcpus: 8, activeVcpus: 4, memoryGB: 64, best: true },
];

test('THE CASE: DS13-4_v2 switched to D and back to E starts on E8-4ds_v5, not E8ds_v5', () => {
  eq(familyStartSize(constrainedSource, 'D').size, 'Standard_D16ds_v5', 'D has no constrained vCPU size: its first size');
  eq(familyStartSize(constrainedSource, 'E').size, 'Standard_E8-4ds_v5', 'back on E: the best choice, 4 active vCPUs');
});

test('a family that is not the best choice keeps the active vCPUs of a constrained vCPU best choice', () => {
  // The best choice is a D size here only to test the rule: E then starts on
  // the E size with the same active vCPUs as the best choice.
  const choices = [
    { size: 'Standard_D8ds_v5', family: 'D', variant: 'constrained', vcpus: 8, activeVcpus: 4, memoryGB: 32, best: true },
    { size: 'Standard_E8ds_v5', family: 'E', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 64, best: false },
    { size: 'Standard_E8-2ds_v5', family: 'E', variant: 'constrained', vcpus: 8, activeVcpus: 2, memoryGB: 64, best: false },
    { size: 'Standard_E8-4ds_v5', family: 'E', variant: 'constrained', vcpus: 8, activeVcpus: 4, memoryGB: 64, best: false },
  ];
  eq(familyStartSize(choices, 'E').size, 'Standard_E8-4ds_v5');
});

test('a machine with all its vCPUs active: a new family starts on its first size, as before', () => {
  const choices = [
    { size: 'Standard_D8ds_v5', family: 'D', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 32, best: true },
    { size: 'Standard_E8ds_v5', family: 'E', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 64, best: false },
    { size: 'Standard_E8-4ds_v5', family: 'E', variant: 'constrained', vcpus: 8, activeVcpus: 4, memoryGB: 64, best: false },
  ];
  eq(familyStartSize(choices, 'E').size, 'Standard_E8ds_v5');
  eq(familyStartSize(choices, 'D').size, 'Standard_D8ds_v5');
  // A 4-vCPU machine with 40 GiB: D4 is not real here, but the rule is - E
  // starts on its full size, never on the constrained vCPU size whose active
  // count happens to match a full-size best choice.
  const four = [
    { size: 'Standard_D4ds_v5', family: 'D', variant: 'default', vcpus: 4, activeVcpus: 4, memoryGB: 48, best: true },
    { size: 'Standard_E8ds_v5', family: 'E', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 64, best: false },
    { size: 'Standard_E8-4ds_v5', family: 'E', variant: 'constrained', vcpus: 8, activeVcpus: 4, memoryGB: 64, best: false },
  ];
  eq(familyStartSize(four, 'E').size, 'Standard_E8ds_v5');
});

test('the best choice wins in its own family, even after another size with its active vCPUs', () => {
  const choices = [
    { size: 'Standard_D16ds_v5', family: 'D', variant: 'default', vcpus: 16, activeVcpus: 16, memoryGB: 64, best: false },
    { size: 'Standard_E8-4ds_v5', family: 'E', variant: 'constrained', vcpus: 8, activeVcpus: 4, memoryGB: 64, best: false },
    { size: 'Standard_E16-4ds_v5', family: 'E', variant: 'constrained', vcpus: 16, activeVcpus: 4, memoryGB: 128, best: true },
  ];
  eq(familyStartSize(choices, 'E').size, 'Standard_E16-4ds_v5');
});

test('no size of that family, or no choices: nothing', () => {
  eq(familyStartSize(constrainedSource, 'Dl'), null);
  eq(familyStartSize(undefined, 'E'), null);
});

test('the Size family list starts the family on familyStartSize, never on the first size of the list', () => {
  const src = pageSource('wizard.html');
  const at = src.indexOf("document.querySelectorAll('select[data-fvm]')");
  ok(at > 0, 'the Size family handler is in the page');
  const handler = src.slice(at, src.indexOf('}));', at));
  ok(/const first = familyStartSize\(o\?\.sizeChoices, e\.target\.value\);/.test(handler), handler);
  ok(!/\.find\(c => c\.family === e\.target\.value\)/.test(handler), 'no first-of-family pick');
});

run('constrained-family-switch');
