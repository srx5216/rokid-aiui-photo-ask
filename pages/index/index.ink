<script def>
{
  "navigationBarTitleText": "拍照识题",
  "description": "面向 Rokid AI Glass 的镜腿触控拍照识题：支持连续拍摄、逐题答案、手动重拍和 VPS 状态。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {}
    }
  }
}
</script>

<script setup>
import wx from 'wx';

const BASE_URL = 'https://rokid.87-106-233-249.sslip.io';
const TOKEN_KEY = 'rokid_shared_token';
const RECORDS_KEY = 'photo_ask_records_v2';
const RECORD_LIMIT = 20;
const MAX_PENDING_JOBS = 5;
const MAX_IMAGE_BASE64_LENGTH = 1500000;
const MAX_THUMBNAIL_BASE64_LENGTH = 70000;
const ANSWER_SCROLL_STEP = 260;

function requestJson({ url, method = 'GET', data, token, timeout = 15000 }) {
  return new Promise((resolve, reject) => {
    const header = {
      accept: 'application/json',
      'content-type': 'application/json'
    };
    if (token) header.authorization = `Bearer ${token}`;

    wx.request({
      url,
      method,
      header,
      data,
      dataType: 'json',
      responseType: 'text',
      timeout,
      success: resolve,
      fail: reject
    });
  });
}

function requestHealth(token) {
  return requestJson({
    url: `${BASE_URL}/v1/ask/health`,
    token,
    timeout: 10000
  });
}

function requestPhotoAnswer({ imageBase64, token, model, reasoningEffort, clientRequestId }) {
  return requestJson({
    url: `${BASE_URL}/v1/ask/photo`,
    method: 'POST',
    token,
    timeout: 70000,
    data: {
      imageBase64,
      ...(model ? { model } : {}),
      ...(reasoningEffort ? { reasoningEffort } : {}),
      clientRequestId
    }
  });
}

function responsePayload(response) {
  const source = response?.data;
  if (typeof source === 'string') {
    try {
      return JSON.parse(source);
    } catch {
      return {};
    }
  }
  return source && typeof source === 'object' ? source : {};
}

function normalizeOptions(value) {
  const entries = Array.isArray(value) ? value : [];
  return [...new Set(entries.map((entry) => String(entry || '').trim()).filter(Boolean))];
}

function normalizeRuntime(value, fallback = {}) {
  const model = String(value?.model || value?.selectedModel || fallback.model || '').trim();
  const reasoningEffort = String(
    value?.reasoningEffort || value?.selectedReasoningEffort || fallback.reasoningEffort || ''
  ).trim();
  return {
    model,
    reasoningEffort,
    models: normalizeOptions(value?.models),
    reasoningEfforts: normalizeOptions(value?.reasoningEfforts)
  };
}

function normalizeClarity(value) {
  const candidate = String(value?.state || 'unknown').trim();
  return {
    state: ['clear', 'uncertain', 'unknown'].includes(candidate) ? candidate : 'unknown',
    reason: String(value?.reason || '').trim()
  };
}

function answerFrom(response) {
  const payload = responsePayload(response);
  const shortAnswer = String(payload?.short_answer || payload?.error || '服务没有返回可显示内容。').trim();
  const fullAnswer = String(payload?.full_answer || shortAnswer).trim();
  return {
    ok: response.statusCode >= 200 && response.statusCode < 300,
    statusCode: Number(response.statusCode || 0),
    question: String(payload?.question || '未能识别题干。').trim(),
    shortAnswer,
    fullAnswer,
    steps: Array.isArray(payload?.steps) ? payload.steps.map((step) => String(step)).filter(Boolean) : [],
    clarity: normalizeClarity(payload?.clarity),
    runtime: normalizeRuntime(payload?.runtime),
    traceId: String(payload?.trace_id || '').trim()
  };
}

function healthFrom(response) {
  const payload = responsePayload(response);
  return {
    ok: response.statusCode >= 200 && response.statusCode < 300,
    statusCode: Number(response.statusCode || 0),
    status: String(payload?.status || '').trim(),
    runtime: normalizeRuntime(payload?.runtime)
  };
}

function createCameraContext() {
  if (typeof wx.media?.createCameraContext === 'function') {
    return wx.media.createCameraContext();
  }
  return typeof wx.createCameraContext === 'function'
    ? wx.createCameraContext('photo-camera')
    : null;
}

function controlFromEvent(event) {
  const code = String(event?.code || event?.key || '');
  const keyCode = Number(event?.keyCode ?? event?.which ?? 0);
  const namedControls = [event?.code, event?.key]
    .map((value) => String(value || '').replace(/[\s-]/g, '_').toUpperCase());
  const hasNamedControl = (...names) => names.some((name) => namedControls.includes(name));

  if (hasNamedControl('SPRITE_SWIPE_BACK', 'SPRITESWIPEBACK')) return 'up';
  if (hasNamedControl('SPRITE_SWIPE_FORWARD', 'SPRITESWIPEFORWARD')) return 'down';
  if (hasNamedControl('SPRITE_DOUBLE_TAP', 'SPRITEDOUBLETAP')) return 'confirm';
  if (['ArrowUp', 'Up', 'DPAD_UP'].includes(code) || keyCode === 19) return 'up';
  if (['ArrowDown', 'Down', 'DPAD_DOWN'].includes(code) || keyCode === 20) return 'down';
  if (['ArrowLeft', 'Left', 'DPAD_LEFT'].includes(code) || keyCode === 21) return 'left';
  if (['ArrowRight', 'Right', 'DPAD_RIGHT'].includes(code) || keyCode === 22) return 'right';
  if (['GlobalHook', 'Enter', 'NumpadEnter', 'OK', 'Confirm'].includes(code) || keyCode === 23 || keyCode === 66) {
    return 'confirm';
  }
  if (['Back', 'BrowserBack', 'Escape'].includes(code) || keyCode === 4) return 'back';
  return '';
}

function newRecordId() {
  return `photo-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function captureTime() {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return `${pad(now.getHours())}:${pad(now.getMinutes())}`;
}

function isTerminalRecord(record) {
  return ['done', 'uncertain', 'failed'].includes(record?.phase);
}

function isSafeThumbnail(value) {
  return typeof value === 'string'
    && value.startsWith('data:image/jpeg;base64,')
    && value.length <= MAX_THUMBNAIL_BASE64_LENGTH + 32;
}

function toPersistentRecord(record) {
  return {
    id: String(record.id || ''),
    capturedAt: String(record.capturedAt || ''),
    phase: String(record.phase || 'done'),
    status: String(record.status || ''),
    question: String(record.question || ''),
    shortAnswer: String(record.shortAnswer || ''),
    fullAnswer: String(record.fullAnswer || ''),
    steps: Array.isArray(record.steps) ? record.steps.map((step) => String(step)) : [],
    clarity: normalizeClarity(record.clarity),
    runtime: normalizeRuntime(record.runtime),
    traceId: String(record.traceId || ''),
    retakeCount: Number(record.retakeCount || 0),
    thumbnailUri: isSafeThumbnail(record.thumbnailUri) ? record.thumbnailUri : ''
  };
}

function normalizeStoredRecord(value) {
  const record = toPersistentRecord(value && typeof value === 'object' ? value : {});
  return record.id ? record : null;
}

function retainRecords(records) {
  let terminalCount = 0;
  return records.filter((record) => {
    if (!isTerminalRecord(record)) return true;
    terminalCount += 1;
    return terminalCount <= RECORD_LIMIT;
  });
}

function chooseOption(current, options, advertised) {
  if (options.includes(current)) return current;
  if (options.includes(advertised)) return advertised;
  return options[0] || '';
}

function runtimeLabelFor(model, reasoningEffort) {
  return model && reasoningEffort ? `${model} / ${reasoningEffort}` : '模型待同步';
}

function phaseStatus(clarity, retakeCount) {
  if (clarity.state === 'uncertain') {
    return retakeCount ? '可能不清晰（已重拍）' : '可能不清晰';
  }
  return retakeCount ? '已完成（已重拍）' : '已完成';
}

async function createThumbnail(data, mimeType) {
  try {
    if (
      typeof OffscreenCanvas !== 'function'
      || typeof createImageBitmap !== 'function'
      || typeof Blob !== 'function'
    ) {
      return '';
    }

    const source = new Blob([data], { type: mimeType || 'image/jpeg' });
    const bitmap = await createImageBitmap(source);
    const scale = Math.min(112 / bitmap.width, 84 / bitmap.height, 1);
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext('2d');
    if (!context || typeof canvas.convertToBlob !== 'function') return '';

    context.drawImage(bitmap, 0, 0, width, height);
    bitmap.close?.();
    const thumbnailBlob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.7 });
    const encoded = wx.arrayBufferToBase64(await thumbnailBlob.arrayBuffer());
    if (!encoded || encoded.length > MAX_THUMBNAIL_BASE64_LENGTH) return '';
    return `data:image/jpeg;base64,${encoded}`;
  } catch {
    return '';
  }
}

export default {
  data: {
    viewMode: 'capture',
    captureFocus: 0,
    answerFocus: 0,
    captureMode: 'new',
    captureHint: '连接 VPS 后，按确认拍照',
    cameraReady: false,
    records: [],
    answerScrollTop: 0,
    queueCount: 0,
    retakeTargetId: '',
    modelOptions: [],
    reasoningOptions: [],
    selectedModel: '',
    selectedReasoningEffort: '',
    linkLabel: 'VPS 未检测',
    runtimeLabel: '模型待同步'
  },

  onLoad() {
    this.jobs = [];
    this.activeJob = null;
    this.processing = false;
    this.capturing = false;
    this.healthBusy = false;
    this.camera = null;

    const records = this.loadRecords();
    this.setData({
      records,
      captureHint: records.length ? '可继续拍题；答案在答案中心' : '连接 VPS 后，按确认拍照'
    });
    this.refreshHealth();
  },

  onShow() {
    this.refreshHealth();
  },

  onReady() {
    this.camera = createCameraContext();
    if (!this.camera) {
      this.setData({
        cameraReady: false,
        captureHint: '相机不可用：请在 AIUI Studio 允许相机权限'
      });
      return;
    }
    this.setData({ cameraReady: true });
  },

  onUnload() {
    for (const job of this.jobs || []) {
      job.imageBase64 = '';
      job.token = '';
    }
    if (this.activeJob) {
      this.activeJob.imageBase64 = '';
      this.activeJob.token = '';
    }
    this.jobs = [];
    this.activeJob = null;
    this.camera = null;
  },

  onKeyUp(event) {
    const control = controlFromEvent(event);
    if (!control) return;
    if (event.preventDefault) event.preventDefault();

    if (control === 'back') {
      this.showCapture();
      return;
    }
    if (control === 'confirm') {
      this.activateFocusedControl();
      return;
    }
    if (this.data.viewMode === 'capture') {
      this.handleCaptureDirection(control);
      return;
    }
    this.handleAnswerDirection(control);
  },

  handleCameraError(event) {
    this.camera = null;
    const message = String(event?.detail?.errMsg || '无法启动眼镜相机。');
    this.setData({
      cameraReady: false,
      captureHint: `相机不可用：${message}`
    });
  },

  handleCaptureTap() {
    this.setData({ captureFocus: 0 });
    this.captureAndEnqueue(this.data.captureMode);
  },

  handleAnswersTap() {
    this.showAnswers();
  },

  handleCameraTap() {
    this.showCapture();
  },

  handleClearTap() {
    this.clearCompletedRecords();
  },

  activateFocusedControl() {
    if (this.data.viewMode === 'capture') {
      if (this.data.captureFocus === 0) {
        this.captureAndEnqueue(this.data.captureMode);
      } else {
        this.showAnswers();
      }
      return;
    }

    if (this.data.answerFocus === 0) {
      this.cycleModel();
      return;
    }
    if (this.data.answerFocus === 1) {
      this.cycleReasoning();
      return;
    }
    if (this.data.answerFocus === 2) {
      this.setData({ captureHint: '答案区：上下滚动，左右切换焦点' });
      return;
    }
    if (this.data.answerFocus === 3) {
      this.showCapture();
      return;
    }
    this.clearCompletedRecords();
  },

  handleCaptureDirection(control) {
    if (
      (control === 'left' || control === 'right')
      && this.data.captureFocus === 0
      && this.data.retakeTargetId
    ) {
      this.toggleCaptureMode();
      return;
    }
    this.setData({ captureFocus: this.data.captureFocus === 0 ? 1 : 0 });
  },

  handleAnswerDirection(control) {
    const focus = this.data.answerFocus;
    if (focus === 2) {
      if (control === 'up') {
        this.scrollAnswers(-1);
        return;
      }
      if (control === 'down') {
        this.scrollAnswers(1);
        return;
      }
      this.setData({ answerFocus: control === 'left' ? 1 : 3 });
      return;
    }

    if ((control === 'left' || control === 'right') && focus === 0) {
      this.cycleModel();
      return;
    }
    if ((control === 'left' || control === 'right') && focus === 1) {
      this.cycleReasoning();
      return;
    }
    if (control === 'left' || control === 'right') {
      this.setData({ answerFocus: focus === 3 ? 4 : 3 });
      return;
    }

    const nextFocus = Math.max(0, Math.min(4, focus + (control === 'up' ? -1 : 1)));
    this.setData({ answerFocus: nextFocus });
  },

  toggleCaptureMode() {
    if (!this.data.retakeTargetId) return;
    const captureMode = this.data.captureMode === 'retake' ? 'new' : 'retake';
    this.setData({
      captureMode,
      captureHint: captureMode === 'retake'
        ? '将替换最近的模糊/失败题；左右可切换拍新题'
        : '将拍新题；左右可切换重拍'
    });
  },

  showAnswers() {
    this.setData({
      viewMode: 'answers',
      answerFocus: 0,
      answerScrollTop: 0,
      captureHint: '模型设置只影响之后新拍的题目'
    });
  },

  showCapture() {
    this.setData({
      viewMode: 'capture',
      captureFocus: 0,
      captureMode: this.data.retakeTargetId ? 'retake' : 'new',
      captureHint: this.data.retakeTargetId
        ? '默认重拍；左右切换为拍新题'
        : '对准题目后按确认拍照'
    });
  },

  scrollAnswers(direction) {
    const current = Number(this.data.answerScrollTop || 0);
    this.setData({
      answerScrollTop: Math.max(0, current + direction * ANSWER_SCROLL_STEP)
    });
  },

  cycleModel() {
    const options = this.data.modelOptions;
    if (!options.length) {
      this.setData({ captureHint: '模型列表尚未从 VPS 获取' });
      this.refreshHealth();
      return;
    }
    const index = options.indexOf(this.data.selectedModel);
    const selectedModel = options[(index + 1 + options.length) % options.length];
    this.setData({
      selectedModel,
      runtimeLabel: runtimeLabelFor(selectedModel, this.data.selectedReasoningEffort),
      captureHint: '模型设置将应用到之后新拍的题目'
    });
  },

  cycleReasoning() {
    const options = this.data.reasoningOptions;
    if (!options.length) {
      this.setData({ captureHint: '推理档位尚未从 VPS 获取' });
      this.refreshHealth();
      return;
    }
    const index = options.indexOf(this.data.selectedReasoningEffort);
    const selectedReasoningEffort = options[(index + 1 + options.length) % options.length];
    this.setData({
      selectedReasoningEffort,
      runtimeLabel: runtimeLabelFor(this.data.selectedModel, selectedReasoningEffort),
      captureHint: '推理档位将应用到之后新拍的题目'
    });
  },

  async refreshHealth() {
    if (this.healthBusy) return;
    this.healthBusy = true;
    try {
      const token = this.readToken();
      if (!token) {
        this.setData({ linkLabel: 'VPS 未配对', runtimeLabel: '模型待同步' });
        return;
      }

      const startedAt = Date.now();
      const result = healthFrom(await requestHealth(token));
      if (!result.ok) {
        this.setData({
          linkLabel: result.statusCode === 401 ? 'VPS 未授权' : 'VPS 不可达'
        });
        return;
      }

      const latency = Math.max(0, Date.now() - startedAt);
      const modelOptions = result.runtime.models;
      const reasoningOptions = result.runtime.reasoningEfforts;
      const selectedModel = chooseOption(
        this.data.selectedModel,
        modelOptions,
        result.runtime.model
      );
      const selectedReasoningEffort = chooseOption(
        this.data.selectedReasoningEffort,
        reasoningOptions,
        result.runtime.reasoningEffort
      );
      this.setData({
        modelOptions,
        reasoningOptions,
        selectedModel,
        selectedReasoningEffort,
        linkLabel: result.status === 'mock' ? `VPS 模拟 ${latency}ms` : `VPS ${latency}ms`,
        runtimeLabel: runtimeLabelFor(selectedModel, selectedReasoningEffort)
      });
    } catch {
      this.setData({ linkLabel: 'VPS 连接失败' });
    } finally {
      this.healthBusy = false;
    }
  },

  readToken() {
    try {
      return String(wx.getStorageSync(TOKEN_KEY) || '').trim();
    } catch {
      return '';
    }
  },

  loadRecords() {
    try {
      const stored = wx.getStorageSync(RECORDS_KEY);
      if (!Array.isArray(stored)) return [];
      return retainRecords(stored.map(normalizeStoredRecord).filter(Boolean));
    } catch {
      return [];
    }
  },

  persistRecords() {
    try {
      const records = this.data.records
        .filter(isTerminalRecord)
        .slice(0, RECORD_LIMIT)
        .map(toPersistentRecord);
      wx.setStorageSync(RECORDS_KEY, records);
    } catch {
      this.setData({ captureHint: '本地保存失败；本次答案仍可查看' });
    }
  },

  updateRecord(id, patch) {
    const records = retainRecords(
      this.data.records.map((record) => record.id === id ? { ...record, ...patch } : record)
    );
    this.setData({ records });
    return records.find((record) => record.id === id) || null;
  },

  appendRecord(record) {
    const records = retainRecords([record, ...this.data.records]);
    this.setData({ records });
  },

  findRecord(id) {
    return this.data.records.find((record) => record.id === id) || null;
  },

  queueSize() {
    return (this.jobs?.length || 0) + (this.activeJob ? 1 : 0);
  },

  updateQueueCount() {
    this.setData({ queueCount: this.queueSize() });
  },

  clearCompletedRecords() {
    const records = this.data.records.filter((record) => !isTerminalRecord(record));
    const targetStillExists = records.some((record) => record.id === this.data.retakeTargetId);
    this.setData({
      records,
      retakeTargetId: targetStillExists ? this.data.retakeTargetId : '',
      captureMode: targetStillExists ? this.data.captureMode : 'new',
      captureHint: '已清空已完成的答案记录'
    });
    this.persistRecords();
  },

  async captureAndEnqueue(mode) {
    if (this.capturing) return;
    if (this.queueSize() >= MAX_PENDING_JOBS) {
      this.setData({ captureHint: `队列已满（${MAX_PENDING_JOBS}），请等待一题完成` });
      return;
    }
    if (!this.camera || !this.data.cameraReady) {
      this.setData({ captureHint: '相机不可用：请检查 AIUI 相机权限' });
      return;
    }

    const token = this.readToken();
    if (!token) {
      this.setData({ captureHint: '尚未配对：请先写入本机连接令牌' });
      return;
    }
    const model = this.data.selectedModel;
    const reasoningEffort = this.data.selectedReasoningEffort;
    if (!model || !reasoningEffort) {
      this.setData({ captureHint: '正在同步 VPS 模型，请稍后再拍' });
      this.refreshHealth();
      return;
    }

    const target = mode === 'retake' ? this.findRecord(this.data.retakeTargetId) : null;
    this.capturing = true;
    this.setData({
      captureFocus: 0,
      captureHint: target ? '正在重拍' : '正在拍照'
    });

    let imageBase64 = '';
    try {
      const photo = await this.camera.takePhoto({ quality: 'low' });
      imageBase64 = wx.arrayBufferToBase64(photo.data);
      if (!imageBase64 || imageBase64.length > MAX_IMAGE_BASE64_LENGTH) {
        throw new Error('图片超过上传限制，请重新对准题目后拍摄。');
      }
      const thumbnailUri = await createThumbnail(photo.data, photo.mimeType || 'image/jpeg');
      const capturedAt = captureTime();
      let recordId = '';
      let retakeCount = 0;

      if (target) {
        recordId = target.id;
        retakeCount = Number(target.retakeCount || 0) + 1;
        this.updateRecord(recordId, {
          capturedAt,
          phase: 'queued',
          status: '重拍排队',
          question: '正在识别题干。',
          shortAnswer: '',
          fullAnswer: '',
          steps: [],
          clarity: { state: 'unknown', reason: '' },
          runtime: { model, reasoningEffort, models: [], reasoningEfforts: [] },
          traceId: '',
          thumbnailUri,
          retakeCount
        });
        this.setData({ retakeTargetId: '', captureMode: 'new' });
      } else {
        recordId = newRecordId();
        this.appendRecord({
          id: recordId,
          capturedAt,
          phase: 'queued',
          status: '待上传',
          question: '正在识别题干。',
          shortAnswer: '',
          fullAnswer: '',
          steps: [],
          clarity: { state: 'unknown', reason: '' },
          runtime: { model, reasoningEffort, models: [], reasoningEfforts: [] },
          traceId: '',
          thumbnailUri,
          retakeCount: 0
        });
      }

      this.persistRecords();
      this.jobs.push({
        id: recordId,
        imageBase64,
        token,
        model,
        reasoningEffort,
        retakeCount
      });
      imageBase64 = '';
      this.updateQueueCount();
      this.setData({
        captureHint: `已加入队列（${this.data.queueCount}/${MAX_PENDING_JOBS}），可继续拍下一题`
      });
      this.processQueue();
    } catch (error) {
      const reason = String(error?.message || error || '拍照失败。');
      this.setData({ captureHint: reason });
    } finally {
      this.capturing = false;
      imageBase64 = '';
    }
  },

  async processQueue() {
    if (this.processing) return;
    const job = this.jobs.shift();
    if (!job) {
      this.updateQueueCount();
      return;
    }

    this.processing = true;
    this.activeJob = job;
    this.updateQueueCount();
    this.updateRecord(job.id, { phase: 'processing', status: '解题中' });

    try {
      const result = answerFrom(await requestPhotoAnswer(job));
      if (!result.ok) {
        this.finishJobFailure(
          job,
          result.statusCode === 401 ? '未授权，请重新配对后重拍。' : result.fullAnswer
        );
      } else {
        const phase = result.clarity.state === 'uncertain' ? 'uncertain' : 'done';
        this.updateRecord(job.id, {
          phase,
          status: phaseStatus(result.clarity, job.retakeCount),
          question: result.question,
          shortAnswer: result.shortAnswer,
          fullAnswer: result.fullAnswer,
          steps: result.steps,
          clarity: result.clarity,
          runtime: normalizeRuntime(result.runtime, {
            model: job.model,
            reasoningEffort: job.reasoningEffort
          }),
          traceId: result.traceId,
          retakeCount: job.retakeCount
        });
        this.persistRecords();
        if (phase === 'uncertain') {
          this.setData({
            retakeTargetId: job.id,
            captureMode: 'retake',
            captureHint: '这题可能不清晰；拍照按钮默认重拍，左右可切换拍新题'
          });
        } else {
          this.setData({ captureHint: '已完成；可继续拍下一题或打开答案中心' });
        }
      }
      this.refreshHealth();
    } catch (error) {
      const reason = String(error?.message || error || '无法连接后台服务。');
      this.finishJobFailure(job, `${reason}。请检查眼镜链路后重拍。`);
      this.refreshHealth();
    } finally {
      job.imageBase64 = '';
      job.token = '';
      this.activeJob = null;
      this.processing = false;
      this.updateQueueCount();
      if (this.jobs.length) this.processQueue();
    }
  },

  finishJobFailure(job, message) {
    this.updateRecord(job.id, {
      phase: 'failed',
      status: job.retakeCount ? '重拍失败' : '失败',
      question: this.findRecord(job.id)?.question || '未能识别题干。',
      shortAnswer: String(message || '服务暂时无法回答。'),
      fullAnswer: String(message || '服务暂时无法回答。'),
      steps: [],
      clarity: { state: 'unknown', reason: '本次请求未完成。' },
      runtime: {
        model: job.model,
        reasoningEffort: job.reasoningEffort,
        models: [],
        reasoningEfforts: []
      }
    });
    this.persistRecords();
    this.setData({
      retakeTargetId: job.id,
      captureMode: 'retake',
      captureHint: '本题失败；拍照按钮默认重拍，左右可切换拍新题'
    });
  }
};
</script>

<page>
  <view class="screen">
    <view class="topbar">
      <text class="title">{{ viewMode === 'capture' ? '拍照识题' : '答案中心' }}</text>
      <text class="hint">{{ captureHint }}</text>
    </view>

    <view class="main">
      <view class="capture-panel {{ viewMode === 'capture' ? '' : 'panel-hidden' }}">
        <camera
          id="photo-camera"
          class="capture-camera"
          device-position="back"
          flash="off"
          binderror="handleCameraError"
        />
        <view class="camera-overlay">
          <text class="camera-copy">对准题目 · 按确认拍照</text>
          <text class="camera-copy-small">{{ queueCount ? '后台正在处理，可继续拍' : '图片只在解题队列中暂存' }}</text>
        </view>
      </view>

      <scroll-view
        class="answer-scroll {{ viewMode === 'answers' ? '' : 'panel-hidden' }}"
        scroll-y="true"
        scroll-top="{{ answerScrollTop }}"
      >
        <view class="settings-card">
          <view class="setting {{ answerFocus === 0 ? 'selected' : '' }}">
            <text class="setting-label">模型</text>
            <text class="setting-value">{{ selectedModel || '同步中' }}</text>
          </view>
          <view class="setting {{ answerFocus === 1 ? 'selected' : '' }}">
            <text class="setting-label">推理</text>
            <text class="setting-value">{{ selectedReasoningEffort || '同步中' }}</text>
          </view>
          <view class="setting {{ answerFocus === 2 ? 'selected' : '' }}">
            <text class="setting-label">答案</text>
            <text class="setting-value">上下滚动</text>
          </view>
        </view>

        <view wx:if="{{ records.length === 0 }}" class="empty-card">
          <text class="empty-title">还没有题目</text>
          <text class="empty-copy">返回拍照后按确认；每题的完整答案会留在这里。</text>
        </view>

        <view wx:for="{{ records }}" wx:key="id" class="answer-card">
          <view class="card-head">
            <image wx:if="{{ item.thumbnailUri }}" class="thumbnail" src="{{ item.thumbnailUri }}" mode="aspectFill" />
            <view wx:else class="thumbnail-placeholder">
              <text>题图</text>
            </view>
            <view class="card-meta">
              <text class="record-status">{{ item.status }}</text>
              <text class="record-time">{{ item.capturedAt }} · {{ item.runtime.model }} / {{ item.runtime.reasoningEffort }}</text>
            </view>
          </view>
          <text class="question">{{ item.question }}</text>
          <text wx:if="{{ item.shortAnswer }}" class="short-answer">{{ item.shortAnswer }}</text>
          <text class="full-answer">{{ item.fullAnswer || '正在等待结果…' }}</text>
          <view wx:if="{{ item.steps.length }}" class="steps">
            <text wx:for="{{ item.steps }}" wx:for-item="step" wx:key="*this" class="step">• {{ step }}</text>
          </view>
          <text wx:if="{{ item.clarity.reason }}" class="clarity">{{ item.clarity.reason }}</text>
        </view>
      </scroll-view>
    </view>

    <view class="actions">
      <button
        wx:if="{{ viewMode === 'capture' }}"
        class="action {{ captureFocus === 0 ? 'selected' : '' }}"
        bindtap="handleCaptureTap"
      >{{ captureMode === 'retake' ? '重拍' : '拍新题' }}</button>
      <button
        wx:if="{{ viewMode === 'capture' }}"
        class="action {{ captureFocus === 1 ? 'selected' : '' }}"
        bindtap="handleAnswersTap"
      >答案 {{ records.length }}</button>
      <button
        wx:if="{{ viewMode === 'answers' }}"
        class="action {{ answerFocus === 3 ? 'selected' : '' }}"
        bindtap="handleCameraTap"
      >拍照</button>
      <button
        wx:if="{{ viewMode === 'answers' }}"
        class="action {{ answerFocus === 4 ? 'selected' : '' }}"
        bindtap="handleClearTap"
      >清空完成</button>
    </view>

    <view class="footer">
      <text class="footer-text">{{ linkLabel }} · {{ runtimeLabel }} · 队列 {{ queueCount }}/5</text>
    </view>
  </view>
</page>

<style>
.screen {
  width: 100vw;
  height: 100vh;
  min-height: 100%;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  padding: 12px;
  background-color: var(--color-background, #000000);
  color: var(--color-text-primary, #40ff5e);
}

.topbar {
  flex-shrink: 0;
  padding-bottom: 8px;
  border-bottom: 2px solid var(--color-border, rgba(64, 255, 94, 0.45));
}

.title {
  display: block;
  font-size: 24px;
  line-height: 30px;
  color: var(--color-text-primary, #40ff5e);
}

.hint {
  display: block;
  margin-top: 4px;
  font-size: 18px;
  line-height: 24px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.78));
}

.main {
  flex: 1;
  min-height: 0;
  margin: 10px 0;
  position: relative;
}

.capture-panel,
.answer-scroll {
  width: 100%;
  height: 100%;
  box-sizing: border-box;
}

.panel-hidden {
  display: none;
}

.capture-panel {
  position: relative;
  overflow: hidden;
  border: 2px solid var(--color-primary, #40ff5e);
  border-radius: 10px;
  background-color: #0b130d;
}

.capture-camera {
  width: 100%;
  height: 100%;
}

.camera-overlay {
  position: absolute;
  left: 12px;
  right: 12px;
  bottom: 12px;
  padding: 8px;
  background-color: rgba(0, 0, 0, 0.64);
}

.camera-copy {
  display: block;
  font-size: 22px;
  line-height: 28px;
  color: #ffffff;
}

.camera-copy-small {
  display: block;
  margin-top: 2px;
  font-size: 18px;
  line-height: 24px;
  color: rgba(255, 255, 255, 0.82);
}

.answer-scroll {
  padding-right: 2px;
}

.settings-card,
.answer-card,
.empty-card {
  box-sizing: border-box;
  margin-bottom: 10px;
  padding: 10px;
  border: 2px solid var(--color-border, rgba(64, 255, 94, 0.45));
  border-radius: 10px;
  background-color: rgba(18, 38, 21, 0.55);
}

.setting {
  display: flex;
  justify-content: space-between;
  align-items: center;
  min-height: 38px;
  margin: 3px 0;
  padding: 2px 6px;
  border: 1px solid transparent;
}

.setting-label,
.setting-value {
  font-size: 19px;
  line-height: 26px;
}

.setting-value {
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.78));
}

.selected {
  color: #000000 !important;
  border-color: var(--color-primary, #40ff5e) !important;
  background-color: var(--color-primary, #40ff5e) !important;
}

.selected .setting-value {
  color: #000000;
}

.empty-title {
  display: block;
  font-size: 22px;
  line-height: 30px;
}

.empty-copy {
  display: block;
  margin-top: 6px;
  font-size: 18px;
  line-height: 26px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.78));
}

.card-head {
  display: flex;
  flex-direction: row;
  align-items: center;
}

.thumbnail,
.thumbnail-placeholder {
  width: 92px;
  height: 70px;
  flex-shrink: 0;
  border: 1px solid var(--color-border, rgba(64, 255, 94, 0.45));
  border-radius: 6px;
}

.thumbnail-placeholder {
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 18px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.78));
}

.card-meta {
  flex: 1;
  min-width: 0;
  margin-left: 10px;
}

.record-status,
.record-time {
  display: block;
}

.record-status {
  font-size: 21px;
  line-height: 28px;
}

.record-time {
  margin-top: 2px;
  font-size: 18px;
  line-height: 23px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.78));
}

.question,
.short-answer,
.full-answer,
.clarity,
.step {
  display: block;
  white-space: pre-wrap;
  word-break: break-word;
}

.question {
  margin-top: 10px;
  font-size: 21px;
  line-height: 30px;
  color: #ffffff;
}

.short-answer {
  margin-top: 7px;
  font-size: 21px;
  line-height: 29px;
  color: var(--color-primary, #40ff5e);
}

.full-answer {
  margin-top: 7px;
  font-size: 19px;
  line-height: 28px;
  color: var(--color-text-primary, #40ff5e);
}

.steps {
  margin-top: 7px;
}

.step,
.clarity {
  font-size: 18px;
  line-height: 26px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.78));
}

.clarity {
  margin-top: 7px;
}

.actions {
  flex-shrink: 0;
  display: flex;
  flex-direction: row;
  gap: 10px;
}

.action {
  flex-grow: 1;
  flex-basis: 0;
  height: 48px;
  box-sizing: border-box;
  border: 2px solid var(--color-primary, #40ff5e);
  border-radius: 8px;
  font-size: 21px;
  line-height: 28px;
  text-align: center;
  color: var(--color-primary, #40ff5e);
  background-color: var(--color-background, #000000);
}

.footer {
  flex-shrink: 0;
  margin-top: 8px;
  overflow: hidden;
}

.footer-text {
  display: block;
  overflow: hidden;
  font-size: 18px;
  line-height: 24px;
  white-space: nowrap;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.78));
}
</style>
