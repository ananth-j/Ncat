# Wcat Communication Protocol Specification

**Current Protocol Version**: `1`

The Wcat protocol defines the communication contract between the Flutter UI client and the Dart Bridge Server.

---

## 1. Transport Layers & Endpoints

All communication takes place over loopback (`127.0.0.1`).

| Endpoint | Method / Protocol | Description | Authentication |
|---|---|---|---|
| `/ws` | WebSocket | Bidirectional JSON for log streaming and device commands. | Optional token via query parameter or header. |
| `/stream` | WebSocket (Binary) | Dedicated binary frame stream for real-time video mirroring. | Optional token. |
| `/api/stream` | HTTP GET | Multipart/x-mixed-replace MJPEG stream for screen mirroring. | Optional token. |
| `/api/screenshot` | HTTP GET | Returns raw `image/png` bytes directly from `screencap -p`. | Optional token. |
| `/api/record/start` | HTTP POST | Initiates native hardware `screenrecord` on the device. | Optional token. |
| `/api/record/stop` | HTTP POST | Sends SIGINT to screenrecord on device, pulls MP4, cleans up temp file. | Optional token. |
| `/api/scrcpy/launch`| HTTP POST | Spawns zero-host-CPU external `scrcpy` window. | Optional token. |
| `/api/input` | HTTP POST | Injects tap, swipe, keyevent, or text into the persistent device shell. | Optional token. |

---

## 2. Authentication & Origin Security

When token authentication is enabled (`--auth` or `--token <secret>`):
1. **Query Parameter**: `?token=<secret>`
2. **HTTP Header**: `X-Auth-Token: <secret>`
3. **HTTP Header**: `Authorization: Bearer <secret>`

Requests from external web browsers with an untrusted `Origin:` header receive `403 Forbidden`. Requests without valid tokens receive `401 Unauthorized`.

---

## 3. Handshake & Version Negotiation

Upon connecting to `/ws`, the bridge server immediately emits:
```json
{
  "type": "handshake",
  "protocolVersion": 1,
  "serverVersion": "1.0.0"
}
```

Clients may transmit a `hello` handshake command to negotiate capabilities:
```json
{
  "cmd": "hello",
  "protocolVersion": 1,
  "client": "wcat-flutter-v1"
}
```

---

## 4. Server to Client Messages (`BridgeMessage`)

Every message optionally contains a `serial` field to identify the origin device session during multi-device operation.

### A. `status`
Broadcast when server state, active device, package PID, or connected devices change.
```json
{
  "type": "status",
  "status": "connected",
  "protocolVersion": 1,
  "serial": "emulator-5554",
  "package": "com.example.app",
  "pid": 12345,
  "device": "emulator-5554",
  "isRecording": false,
  "isStreaming": false,
  "devices": [
    {
      "serial": "emulator-5554",
      "model": "sdk_gphone64_arm64",
      "authorized": true
    }
  ]
}
```

### B. `lines` (Batch Ingestion)
Batched log lines flushed periodically (every 100ms) to avoid single-line WebSocket overhead.
```json
{
  "type": "lines",
  "serial": "emulator-5554",
  "lines": [
    {
      "seq": 1042,
      "time": "10-18 12:45:00.123",
      "pid": 12345,
      "tid": 12345,
      "level": "I",
      "tag": "MainActivity",
      "msg": "Application initialized",
      "pkg": "com.example.app"
    }
  ]
}
```

### C. `history`
Sent immediately to newly connected clients containing recent log buffer history.
```json
{
  "type": "history",
  "serial": "emulator-5554",
  "lines": [ ... ]
}
```

### D. `clear`
Instructs the client to reset its log view for a given device.
```json
{
  "type": "clear",
  "serial": "emulator-5554"
}
```

---

## 5. Client to Server Commands (`BridgeCommand`)

Commands may include an optional `"serial"` field to target a specific connected device. If omitted, the command applies to the currently active device.

### A. `filter`
Sets or clears the application package filter.
```json
{
  "cmd": "filter",
  "package": "com.example.app",
  "serial": "emulator-5554"
}
```

### B. `device`
Selects the active device.
```json
{
  "cmd": "device",
  "serial": "emulator-5554"
}
```

### C. `clear`
Clears device logcat buffer (`adb logcat -c`) and server in-memory ring buffer.
```json
{
  "cmd": "clear",
  "serial": "emulator-5554"
}
```

### D. `restart`
Restarts the underlying `adb logcat` process for the specified device.
```json
{
  "cmd": "restart",
  "serial": "emulator-5554"
}
```

### E. `scrcpy`
Launches an external `scrcpy` window for the device.
```json
{
  "cmd": "scrcpy",
  "serial": "emulator-5554"
}
```

### F. `input`
Injects user input events into the device shell via stdin.

- **Tap**:
  ```json
  {
    "cmd": "input",
    "action": "tap",
    "x": 540,
    "y": 960,
    "serial": "emulator-5554"
  }
  ```

- **Swipe / Drag**:
  ```json
  {
    "cmd": "input",
    "action": "swipe",
    "x1": 540,
    "y1": 1500,
    "x2": 540,
    "y2": 500,
    "durationMs": 300,
    "serial": "emulator-5554"
  }
  ```

- **Key Event**:
  ```json
  {
    "cmd": "input",
    "action": "key",
    "keyCode": 4,
    "serial": "emulator-5554"
  }
  ```
  *(4 = Back, 3 = Home, 187 = App Switcher, 24 = Vol+, 25 = Vol-, 26 = Power)*

- **Text**:
  ```json
  {
    "cmd": "input",
    "action": "text",
    "text": "Hello Android",
    "serial": "emulator-5554"
  }
  ```

---

## 6. HTTP Media & Capture Endpoints

### `GET /api/screenshot?serial=<serial>`
Returns raw PNG bytes. HTTP 200 with `Content-Type: image/png`.

### `POST /api/record/start?serial=<serial>&bitRate=<bitRate>`
Starts native hardware recording.
**Response**:
```json
{
  "status": "recording",
  "serial": "emulator-5554",
  "startedAt": "2026-10-18T12:00:00.000Z"
}
```

### `POST /api/record/stop?serial=<serial>`
Stops recording via SIGINT, pulls the video file, cleans up on-device storage, and returns raw MP4 bytes with `Content-Type: video/mp4` and `Content-Disposition: attachment; filename="wcat_<serial>_<timestamp>.mp4"`.

### `GET /api/stream?serial=<serial>&fps=<fps>`
Provides an HTTP MJPEG stream with boundary separator `--frame`. Clamped to 1–30 FPS.
