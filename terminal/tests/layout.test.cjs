const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader } = require('./support/harness.cjs');

const load = createEtsLoader();
const { LayoutCoordinator } = load('entry/src/main/ets/posture/LayoutCoordinator.ets');
const { LayoutPreference, PostureSnapshot, PostureState } = load('entry/src/main/ets/posture/PostureEngine.ets');
const vertical = { left: 300, top: 0, width: 4, height: 800 };
const horizontal = { left: 0, top: 420, width: 600, height: 4 };

function layout(crease, preference = LayoutPreference.LAPTOP, height = 800, syntheticSplit = false) {
  const snapshot = new PostureSnapshot();
  snapshot.state = PostureState.LAPTOP;
  snapshot.preference = preference;
  snapshot.crease = crease;
  snapshot.syntheticSplit = syntheticSplit;
  return LayoutCoordinator.compute(600, height, 38, snapshot, true, false);
}

for (const [name, crease] of [
  ['vertical', [vertical]],
  ['absent', []],
  ['outside the window', [{ ...horizontal, top: 1000 }]],
  ['outside the window horizontally', [{ ...horizontal, left: 700 }]],
  ['non-finite', [{ ...horizontal, top: NaN }]]
]) {
  test(`manual split uses window halves when the crease is ${name}`, () => {
    const result = layout(crease);
    assert.equal(result.laptop, true);
    assert.equal(result.terminalHeight, 400);
    assert.equal(result.keyboardY, 400);
    assert.equal(result.keyboardHeight, 400);
  });
}

test('selects the valid horizontal crease even when it is not the first rectangle', () => {
  const result = layout([vertical, horizontal]);
  assert.equal(result.laptop, true);
  assert.equal(result.terminalHeight, 382);
  assert.equal(result.keyboardY, 386);
});

test('automatic mode never invents a physical crease, and small windows keep minimum sizes', () => {
  assert.equal(layout([vertical], LayoutPreference.AUTO).laptop, false);
  assert.equal(layout([{ ...horizontal, top: 1000 }], LayoutPreference.AUTO).laptop, false);
  assert.equal(layout([], LayoutPreference.LAPTOP, 350).laptop, false);
  assert.equal(layout([horizontal], LayoutPreference.LAPTOP, 800, true).terminalHeight, 400);
});
