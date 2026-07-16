<script def>
{
  "navigationBarTitleText": "拍照识题",
  "description": "拍摄眼前的题目，显示 VPS Codex 返回的中文答案和最近记录。",
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
const HISTORY_KEY = 'photo_ask_history';
const HISTORY_LIMIT = 20;
const MAX_IMAGE_BASE64_LENGTH = 1500000;

function requestPhotoAnswer(imageBase64, token) {
  return new Promise((resolve, reject) => {
    wx.request({
      url: `${BASE_URL}/v1/ask/photo`,
      method: 'POST',
      header: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json'
      },
      data: { imageBase64 },
      dataType: 'json',
      responseType: 'text',
      timeout: 70000,
      success: resolve,
      fail: reject
    });
  });
}

function answerFrom(response) {
  const payload = typeof response.data === 'string'
    ? JSON.parse(response.data)
    : response.data;
  return {
    ok: response.statusCode >= 200 && response.statusCode < 300,
    statusCode: response.statusCode,
    answer: String(payload?.short_answer || payload?.error || '服务没有返回可显示内容。'),
    traceId: String(payload?.trace_id || '')
  };
}

function historyEntryText(item) {
  return `${item.at}\n\n${item.answer}`;
}

function createCameraContext() {
  if (typeof wx.media?.createCameraContext === 'function') {
    return wx.media.createCameraContext();
  }
  return typeof wx.createCameraContext === 'function'
    ? wx.createCameraContext('photo-camera')
    : null;
}

function isConfirmKey(event, code) {
  const keyCode = Number(event?.keyCode ?? event?.which ?? 0);
  return ['GlobalHook', 'Enter', 'NumpadEnter', 'OK', 'Confirm'].includes(code)
    || keyCode === 23
    || keyCode === 66;
}

export default {
  data: {
    busy: false,
    status: '对准题目后按拍照',
    answer: '等待拍照',
    showingHistory: false,
    showingPreview: true,
    history: [],
    historyIndex: -1,
    selectedAction: 0,
    scrollTop: 0
  },

  onLoad() {
    try {
      const storedHistory = wx.getStorageSync(HISTORY_KEY) || [];
      const history = Array.isArray(storedHistory)
        ? storedHistory.slice(0, HISTORY_LIMIT)
        : [];
      this.setData({ history });
    } catch {
      this.setData({ status: '本地记录不可用' });
    }
  },

  onReady() {
    this.camera = createCameraContext();
    if (!this.camera) {
      this.setData({
        status: '相机不可用',
        answer: '当前 AIUI 运行环境没有提供相机能力。',
        showingPreview: false
      });
    }
  },

  onKeyUp(event) {
    const code = String(event?.code || event?.key || '');
    const keyCode = Number(event?.keyCode ?? event?.which ?? 0);
    if (code === 'ArrowUp' || code === 'ArrowDown' || keyCode === 19 || keyCode === 20) {
      if (event.preventDefault) event.preventDefault();
      this.moveActionFocus();
      return;
    }
    if (!isConfirmKey(event, code)) return;
    if (event.preventDefault) event.preventDefault();
    this.activateSelectedAction();
  },

  moveActionFocus() {
    if (this.data.busy) return;
    this.setData({ selectedAction: this.data.selectedAction === 0 ? 1 : 0 });
  },

  activateSelectedAction() {
    if (this.data.selectedAction === 0) {
      this.captureAndAsk();
      return;
    }
    this.showNextHistory();
  },

  handleCapture() {
    this.setData({ selectedAction: 0, showingPreview: true });
    this.captureAndAsk();
  },

  handleCameraError(event) {
    this.camera = null;
    const message = String(event?.detail?.errMsg || '无法启动眼镜相机。');
    this.setData({ status: '相机不可用', answer: message, showingPreview: false });
  },

  showNextHistory() {
    const history = this.data.history;
    if (!history.length) {
      this.setData({
        selectedAction: 1,
        showingHistory: true,
        showingPreview: false,
        historyIndex: -1,
        status: '暂无历史',
        answer: '先拍一道题，答案会自动保存。',
        scrollTop: 0
      });
      return;
    }
    const historyIndex = this.data.showingHistory
      ? (this.data.historyIndex + 1) % history.length
      : 0;
    const item = history[historyIndex];
    this.setData({
      selectedAction: 1,
      showingHistory: true,
      showingPreview: false,
      historyIndex,
      status: `历史 ${historyIndex + 1}/${history.length}`,
      answer: historyEntryText(item),
      scrollTop: 0
    });
  },

  async captureAndAsk() {
    if (this.data.busy) return;
    if (!this.camera) {
      this.setData({
        status: '相机不可用',
        answer: '请重开应用；若仍失败，请在 AIUI Studio 允许相机权限。',
        showingPreview: false
      });
      return;
    }

    let token = '';
    try {
      token = wx.getStorageSync(TOKEN_KEY) || '';
    } catch {
      this.setData({ status: '本地配置不可用' });
      return;
    }
    if (!token) {
      this.setData({
        status: '尚未配对',
        answer: '请先在 AIUI DevTools 中写入本机连接令牌。'
      });
      return;
    }

    this.setData({
      busy: true,
      showingHistory: false,
      showingPreview: true,
      historyIndex: -1,
      selectedAction: 0,
      status: '正在拍照',
      answer: '请保持画面稳定'
    });

    try {
      const photo = await this.camera.takePhoto({ quality: 'low' });
      const imageBase64 = wx.arrayBufferToBase64(photo.data);
      if (imageBase64.length > MAX_IMAGE_BASE64_LENGTH) {
        throw new Error('低画质拍照后图片仍超过上传限制。');
      }

      this.setData({ showingPreview: false, status: '正在解题', answer: '等待 VPS Codex 返回' });
      const result = answerFrom(await requestPhotoAnswer(imageBase64, token));
      if (!result.ok) {
        this.setData({
          busy: false,
          showingPreview: false,
          status: result.statusCode === 401 ? '未授权' : '服务异常',
          answer: result.answer,
          scrollTop: 0
        });
        return;
      }
      const history = [{
        at: new Date().toISOString().slice(5, 16).replace('T', ' '),
        answer: result.answer,
        traceId: result.traceId
      }, ...this.data.history].slice(0, HISTORY_LIMIT);
      wx.setStorageSync(HISTORY_KEY, history);
      this.setData({
        busy: false,
        showingPreview: false,
        status: result.ok ? '完成' : '服务异常',
        answer: result.answer,
        history,
        historyIndex: -1,
        scrollTop: 0
      });
    } catch (error) {
      const reason = String(error?.message || error || '无法连接后台服务。');
      this.setData({
        busy: false,
        showingPreview: false,
        status: '连接失败',
        answer: `${reason}\n\n请检查眼镜 Wi-Fi，或确认 Hi Rokid 已通过蓝牙连接 iPhone。`,
        scrollTop: 0
      });
    }
  }
};
</script>

<page>
  <view class="screen">
    <view class="status-row">
      <text class="status">{{ status }}</text>
    </view>

    <view class="content">
      <camera
        id="photo-camera"
        class="capture-camera {{ showingPreview ? 'capture-camera-preview' : 'capture-camera-hidden' }}"
        device-position="back"
        flash="off"
        binderror="handleCameraError"
      />
      <scroll-view class="answer {{ showingPreview ? 'answer-hidden' : '' }}" scroll-y="true" scroll-top="{{ scrollTop }}">
        <text class="answer-text">{{ answer }}</text>
      </scroll-view>
    </view>

    <view class="actions">
      <button
        class="action {{ selectedAction === 0 ? 'selected' : '' }}"
        bindtap="handleCapture"
      >{{ busy ? '处理中' : '拍照' }}</button>
      <button
        class="action {{ selectedAction === 1 ? 'selected' : '' }}"
        bindtap="showNextHistory"
      >历史</button>
    </view>
  </view>
</page>

<style>
.screen {
  width: 448px;
  height: 352px;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  padding: 10px;
  background-color: var(--color-background, #000000);
  color: var(--color-text-primary, #40ff5e);
}

.content {
  height: 240px;
  flex-shrink: 0;
  order: 1;
  position: relative;
  margin: 6px 0;
}

.capture-camera,
.answer {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 240px;
}

.capture-camera-preview {
  opacity: 1;
}

.capture-camera-hidden {
  opacity: 0;
  pointer-events: none;
}

.status-row {
  height: 28px;
  flex-shrink: 0;
  order: 0;
  display: flex;
  align-items: center;
  border-bottom: 2px solid var(--color-border, rgba(64, 255, 94, 0.45));
}

.status {
  font-size: 18px;
  line-height: 24px;
  color: var(--color-text-secondary, rgba(64, 255, 94, 0.72));
}

.answer {
  box-sizing: border-box;
  padding: 12px 2px;
  background-color: var(--color-background, #000000);
}

.answer-hidden {
  visibility: hidden;
}

.answer-text {
  width: 100%;
  font-size: 21px;
  line-height: 30px;
  white-space: pre-wrap;
  word-break: break-word;
  color: var(--color-text-primary, #40ff5e);
}

.actions {
  height: 42px;
  flex-shrink: 0;
  order: 2;
  display: flex;
  flex-direction: row;
  gap: 12px;
}

.action {
  flex-grow: 1;
  flex-basis: 0;
  height: 42px;
  box-sizing: border-box;
  border: 2px solid var(--color-primary, #40ff5e);
  border-radius: 8px;
  font-size: 18px;
  line-height: 22px;
  text-align: center;
  color: var(--color-primary, #40ff5e);
  background-color: var(--color-background, #000000);
}

.selected {
  color: var(--color-background, #000000);
  background-color: var(--color-primary, #40ff5e);
}
</style>
