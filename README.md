# Rokid AIUI Photo Ask Prototype

Purpose: verify the AIUI-only path on real Rokid Glasses before replacing the
native Android client.

## What it tests

- The initial focus is Photo. One confirm action starts a camera capture, and
  another confirm after the answer starts the next capture.
- Up/down swipes switch focus between Photo and History without a cursor.
- The JPEG bytes are posted to the existing VPS `/v1/ask/photo` endpoint.
- The Chinese answer is shown in a vertical `scroll-view`.
- The latest 20 answers are kept in AIUI local storage. Each History activation
  shows the next saved answer and wraps after the oldest item.
- The app makes one normal `wx.request`. AIUI chooses glasses Wi-Fi when it is
  available, otherwise its runtime can proxy HTTPS through the Hi Rokid
  Bluetooth connection to iPhone.

The app does not poll health or keep a camera preview running.

## Local check

```powershell
cd D:\CodexProjects\rokid-codex-assistant-work\clients\aiui-photo-ask-prototype
npm run check
```

## Private test setup

Do not put the VPS token in the AIX source. Before a private device test, set it
in AIUI DevTools for this agent:

```javascript
wx.setStorageSync('rokid_shared_token', 'YOUR_PRIVATE_TOKEN')
```

Register `rokid.87-106-233-249.sslip.io` in the Rizon network-domain allowlist.

The official generator currently creates no working `npm start` script. AIX
packaging therefore requires the official Rust `aix-cli` or importing the
source into AIUI Studio, then uploading the generated `.aix` through Rizon.

## Pass criteria

1. The initial confirm action triggers a photo; repeated confirms trigger new
   photos and return different answers.
2. A normal question photo stays below the server's 1,500,000-base64 limit.
3. The request succeeds with glasses Wi-Fi off and Hi Rokid connected on iOS.
4. Up/down swipe changes the highlighted action with no pointer or cursor.
5. History cycles one answer at a time and remains available after reopening.
