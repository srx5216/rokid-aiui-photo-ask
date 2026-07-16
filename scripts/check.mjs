import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const root = new URL('../', import.meta.url);
const app = JSON.parse(await readFile(new URL('app.json', root), 'utf8'));
const page = await readFile(new URL('pages/index/index.ink', root), 'utf8');
const scriptSetup = page.match(/<script setup>([\s\S]*?)<\/script>/);

assert.deepEqual(app.pages, ['pages/index/index']);
assert.ok(scriptSetup);
new vm.SourceTextModule(scriptSetup[1]);

assert.match(page, /const MAX_PENDING_JOBS = 5/);
assert.match(page, /const RECORD_LIMIT = 20/);
assert.match(page, /function requestHealth\(token\)/);
assert.match(page, /\/v1\/ask\/health/);
assert.match(page, /async refreshHealth\(\)/);
assert.match(page, /async processQueue\(\)/);
assert.match(page, /retakeTargetId/);
assert.match(page, /captureMode/);
assert.match(page, /function toPersistentRecord\(record\)/);
assert.match(page, /function createThumbnail\(/);
assert.match(page, /fullAnswer/);
assert.match(page, /clarity/);
assert.match(page, /runtime/);
assert.match(page, /modelOptions/);
assert.match(page, /reasoningOptions/);
assert.match(page, /cycleModel\(\)/);
assert.match(page, /cycleReasoning\(\)/);
assert.match(page, /onKeyUp\(event\)/);
assert.match(page, /keyCode === 4/);
assert.match(page, /keyCode === 19/);
assert.match(page, /keyCode === 20/);
assert.match(page, /keyCode === 21/);
assert.match(page, /keyCode === 22/);
assert.match(page, /keyCode === 23/);
assert.match(page, /keyCode === 66/);
assert.match(page, /SPRITE_SWIPE_BACK/);
assert.match(page, /SPRITE_SWIPE_FORWARD/);
assert.match(page, /SPRITE_DOUBLE_TAP/);
assert.match(page, /camera\.takePhoto\(\{ quality: 'low' \}\)/);
assert.match(page, /<camera[\s\S]*id="photo-camera"[\s\S]*binderror="handleCameraError"/);
assert.match(page, /<scroll-view[^>]+scroll-y="true"/);
assert.match(page, /ink:for="\{\{ records \}\}"/);
assert.match(page, /<image ink:if="\{\{ item\.thumbnailUri \}\}"/);
assert.doesNotMatch(page, /wx:(if|else|for|key)/, 'InkView templates must use ink: directives');
assert.match(page, /\.actions[\s\S]*flex-direction: row/);
assert.match(page, /\.action[\s\S]*flex-grow: 1[\s\S]*flex-basis: 0/);
assert.match(page, /primaryActionLabel/);
assert.match(page, /secondaryActionLabel/);
assert.match(page, /handlePrimaryTap\(\)/);
assert.match(page, /handleSecondaryTap\(\)/);
const actions = page.match(/<view class="actions">([\s\S]*?)<\/view>\n\n    <view class="footer">/);
assert.ok(actions, 'the action bar should be present');
assert.equal((actions[1].match(/<button/g) || []).length, 2, 'only two action buttons may be rendered');
assert.doesNotMatch(actions[1], /ink:if=/, 'the two action buttons must remain mounted in every view');
assert.match(page, /queueCount/);
assert.match(page, /linkLabel/);
assert.match(page, /runtimeLabel/);
assert.doesNotMatch(page, /width:\s*448px|height:\s*352px/);
assert.doesNotMatch(page, /setInterval|setTimeout/);
assert.doesNotMatch(page, /cursor|mouse/i);
assert.doesNotMatch(page, /Bearer [A-Za-z0-9_-]{16,}/);

const storage = new Map([['rokid_shared_token', 'test-token']]);
const photoRequests = [];
const tinyJpeg = Uint8Array.from([0xff, 0xd8, 0xff, 0xd9]).buffer;
const wx = {
  media: {
    createCameraContext() {
      return {
        async takePhoto() {
          return { data: tinyJpeg.slice(0), mimeType: 'image/jpeg' };
        }
      };
    }
  },
  request(options) {
    if (options.url.endsWith('/v1/ask/health')) {
      options.success({
        statusCode: 200,
        data: JSON.stringify({
          status: 'codex',
          runtime: {
            model: 'gpt-5.5',
            reasoningEffort: 'high',
            models: ['gpt-5.5', 'gpt-5.6'],
            reasoningEfforts: ['low', 'high']
          }
        })
      });
      return;
    }
    if (options.url.endsWith('/v1/ask/photo')) {
      photoRequests.push(options);
      return;
    }
    options.fail(new Error('Unexpected request in AIUI check.'));
  },
  arrayBufferToBase64(value) {
    return Buffer.from(value).toString('base64');
  },
  getStorageSync(key) {
    return storage.get(key);
  },
  setStorageSync(key, value) {
    storage.set(key, value);
  }
};

const runtimeContext = vm.createContext({ console });
const wxModule = new vm.SyntheticModule(
  ['default'],
  function setWxExport() {
    this.setExport('default', wx);
  },
  { context: runtimeContext }
);
const executablePage = new vm.SourceTextModule(scriptSetup[1], { context: runtimeContext });
await executablePage.link((specifier) => {
  if (specifier === 'wx') return wxModule;
  throw new Error(`Unexpected module: ${specifier}`);
});
await executablePage.evaluate();

const pageDefinition = executablePage.namespace.default;
const pageInstance = Object.assign(
  {
    data: JSON.parse(JSON.stringify(pageDefinition.data)),
    setData(patch) {
      this.data = { ...this.data, ...patch };
    }
  },
  pageDefinition
);

async function settle() {
  for (let index = 0; index < 8; index += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
}

function completePhoto(clarityState = 'clear') {
  const request = photoRequests.shift();
  assert.ok(request, 'a queued photo request should exist');
  const model = request.data.model;
  const reasoningEffort = request.data.reasoningEffort;
  request.success({
    statusCode: 200,
    data: JSON.stringify({
      status: 'done',
      trace_id: `trace-${request.data.clientRequestId}`,
      question: '模拟题干',
      short_answer: '模拟结论',
      full_answer: '模拟完整解答',
      steps: ['步骤一', '步骤二'],
      clarity: {
        state: clarityState,
        reason: clarityState === 'uncertain' ? '文字边缘模糊，请重拍。' : ''
      },
      runtime: {
        model,
        reasoningEffort,
        models: ['gpt-5.5', 'gpt-5.6'],
        reasoningEfforts: ['low', 'high']
      }
    })
  });
}

pageInstance.onLoad();
pageInstance.onReady();
await settle();
assert.equal(pageInstance.data.cameraReady, true, 'camera should be initialized');
assert.equal(pageInstance.data.selectedModel, 'gpt-5.5', 'health should publish model options');
assert.equal(pageInstance.data.selectedReasoningEffort, 'high', 'health should publish reasoning options');
assert.equal(pageInstance.data.primaryActionLabel, '拍新题', 'capture should start with one clear primary action');
assert.equal(pageInstance.data.secondaryActionLabel, '查看答案', 'capture should start with one secondary action');
pageInstance.onKeyUp({ keyCode: 20, preventDefault() {} });
assert.equal(pageInstance.data.captureFocus, 1, 'down should move focus to the answer button');
assert.equal(pageInstance.data.secondaryActionFocused, true, 'the secondary action should carry the visible focus');
pageInstance.onKeyUp({ keyCode: 66, preventDefault() {} });
assert.equal(pageInstance.data.viewMode, 'answers', 'confirm should open the answer center');
assert.equal(pageInstance.data.primaryActionLabel, '返回拍照', 'answers should keep the same two-button layout');
assert.equal(pageInstance.data.secondaryActionLabel, '清空记录', 'answers should expose one destructive secondary action');
assert.equal(pageInstance.data.primaryActionFocused, false, 'settings focus must not highlight the return action');
assert.equal(pageInstance.data.secondaryActionFocused, false, 'settings focus must not highlight the clear action');
pageInstance.setViewState({ answerFocus: 4 });
assert.equal(pageInstance.data.secondaryActionFocused, true, 'the clear action may only highlight when it has focus');
pageInstance.onKeyUp({ keyCode: 4, preventDefault() {} });
assert.equal(pageInstance.data.viewMode, 'capture', 'back should always return to capture');
pageInstance.onKeyUp({ code: 'SPRITE_SWIPE_FORWARD', preventDefault() {} });
assert.equal(pageInstance.data.captureFocus, 1, 'temple forward swipe should move focus');
pageInstance.onKeyUp({ code: 'SPRITE_DOUBLE_TAP', preventDefault() {} });
assert.equal(pageInstance.data.viewMode, 'answers', 'temple double tap should confirm the focused action');
pageInstance.setData({ answerFocus: 1 });
pageInstance.onKeyUp({ code: 'SPRITE_SWIPE_BACK', preventDefault() {} });
assert.equal(pageInstance.data.answerFocus, 0, 'temple back swipe should move answer focus up');
pageInstance.onKeyUp({ keyCode: 4, preventDefault() {} });
assert.equal(pageInstance.data.viewMode, 'capture');

await pageInstance.captureAndEnqueue('new');
const firstId = pageInstance.data.records[0].id;
assert.equal(photoRequests.length, 1, 'the first photo should start immediately');
pageInstance.cycleModel();
assert.equal(pageInstance.data.selectedModel, 'gpt-5.6', 'model changes should apply to future tasks');
await pageInstance.captureAndEnqueue('new');
const secondId = pageInstance.data.records[0].id;
assert.equal(pageInstance.data.queueCount, 2, 'one active and one queued photo should be counted');
assert.equal(photoRequests.length, 1, 'the worker should serialize VPS calls');

completePhoto('clear');
await settle();
assert.equal(photoRequests.length, 1, 'the next queued photo should start after the prior response');
completePhoto('clear');
await settle();
assert.equal(pageInstance.data.queueCount, 0, 'queue count should return to zero');
assert.equal(pageInstance.data.records.find((record) => record.id === firstId).runtime.model, 'gpt-5.5');
assert.equal(pageInstance.data.records.find((record) => record.id === secondId).runtime.model, 'gpt-5.6');

await pageInstance.captureAndEnqueue('new');
completePhoto('uncertain');
await settle();
const retakeId = pageInstance.data.retakeTargetId;
assert.ok(retakeId, 'an unclear result should become the manual retake target');
assert.equal(pageInstance.data.captureMode, 'retake');
assert.equal(pageInstance.data.primaryActionLabel, '重拍', 'an unclear result should make the primary action explicit');
const recordCountBeforeRetake = pageInstance.data.records.length;

await pageInstance.captureAndEnqueue('retake');
completePhoto('clear');
await settle();
const retakenRecord = pageInstance.data.records.find((record) => record.id === retakeId);
assert.equal(pageInstance.data.records.length, recordCountBeforeRetake, 'retake should replace instead of duplicate');
assert.equal(retakenRecord.retakeCount, 1, 'retake count should be recorded');
assert.equal(retakenRecord.phase, 'done');
assert.match(retakenRecord.status, /已重拍/);

const storedRecords = storage.get('photo_ask_records_v2');
assert.ok(Array.isArray(storedRecords), 'terminal records should be persisted');
assert.ok(storedRecords.every((record) => !('imageBase64' in record)), 'raw image data must not be persisted');

console.log('AIUI photo ask prototype check passed.');
