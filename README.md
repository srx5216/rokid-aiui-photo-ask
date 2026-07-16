# Rokid AIUI Photo Ask Prototype

这是给 Rokid AI Glass 的 AIUI 初号机源码：大画面拍照、连续拍题、竖向答案中心、手动重拍、模型/推理档位和真实 VPS 延迟状态。

## 眼镜操作

无需手机、鼠标或指针。

- 拍照页：确认键执行当前按钮；方向键切换“拍新题 / 答案”。连续拍摄不会等待上一题答案，最多保留 5 个待处理任务。
- 模型认为图片不清晰或请求失败时，拍照按钮默认变为“重拍”。焦点在此按钮时左右方向可切换“重拍 / 拍新题”。
- 答案页：上方依次是模型、推理档位、答案滚动区；模型和推理档位只影响之后新拍的题。答案区用上下方向滚动，左右方向离开答案区。
- 返回键始终回到拍照页。

代码已映射 Android 输入键码：返回 4、方向 19–22、确认 23/66。镜腿手势与这些键码的最终对应关系仍必须在目标真机上采样确认。

## 隐私与状态

- 原图只存在于内存中的待处理队列；任务结束后会清空，不写入 AIUI 本地存储。
- 最多保留 20 条完成记录：题干、完整答案、清晰度、每题模型/推理档位和缩略图。
- 缩略图只在运行时支持标准 Canvas 压缩时保存；不支持时显示“题图”占位，绝不退化为持久化原图。
- 底栏显示实际 /v1/ask/health 往返延迟、后端公布的模型/推理档位和队列数。没有已验证的 RSSI API，因此不会伪造信号格。
- 健康检查仅在启动、恢复、提交结果或失败后触发，不做轮询。

## 本地检查

~~~
cd clients/aiui-photo-ask-prototype
npm run check
~~~

检查会模拟两题串行 VPS 请求、模型切换、模糊题重拍、原图不落盘和键控结构。

## 私有设备配置

不要把令牌写进 AIX 源码。仅在私有 AIUI DevTools 会话中写入：

~~~
wx.setStorageSync('rokid_shared_token', 'YOUR_PRIVATE_TOKEN')
~~~

在 AIUI Studio 导入本目录前，先在 Rizon 网络域名白名单加入实际 HTTPS 后端域名。导入后运行预览，确认相机权限；生成 .aix 后再由你提交审核。本项目不会自动部署、上传或提审。

## VPS 模型配置

后端通过 /v1/ask/health 向眼镜公布真实可用选项。VPS 仅应配置 Codex CLI 实际支持的模型和推理档位，例如：

~~~
ASK_USE_MOCK=0
ASK_CODEX_MODELS=gpt-5.5,gpt-5.6
ASK_CODEX_DEFAULT_MODEL=gpt-5.5
ASK_CODEX_REASONING_EFFORTS=low,medium,high
ASK_CODEX_DEFAULT_REASONING_EFFORT=high
~~~

上例只是部署示例；UI 不会自行生成 5.5、5.6 或推理强度选项。
