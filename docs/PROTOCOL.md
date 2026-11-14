# ThruWire Communication Protocol Specification

**Current Protocol Version**: `1`

The ThruWire protocol defines the communication contract between the Flutter UI client and the Dart Bridge Server.

---

## 1. Transport Layers & Endpoints

All communication takes place over loopback (`127.0.0.1`).

| Endpoint | Method / Protocol | Description | Authentication |
|---|---|---|---|
| `/ws` | WebSocket | Bidirectional JSON for log streaming and device commands. | Optional token via query parameter or header. |
| `/api/screenshot` | HTTP GET | Returns raw `image/png` bytes directly from `screencap -p`. | Optional token. |
| `/api/record/start` | HTTP POST | Initiates native hardware `screenrecord` on the device. | Optional token. |
| `/api/record/stop` | HTTP POST | Sends SIGINT to screenrecord on device, pulls MP4, cleans up temp file. | Optional token. |
| `/api/scrcpy/launch`| HTTP POST | Launches the native `scrcpy` client for the selected device. | Optional token. |
| `/api/scrcpy/stop` | HTTP POST | Stops the scrcpy process for the selected device. | Optional token. |
| `/api/scrcpy/status` | HTTP GET | Queries whether scrcpy binary is installed on host with version info. | Optional token. |
| `/api/scrcpy/install` | HTTP POST | Automatically downloads and installs scrcpy to local user tools directory. | Optional token. |
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
  "client": "ThruWire-flutter-v1"
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
Launches scrcpy for the device. The desktop frontend embeds its native window on Windows.
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

## 6. HTTP Media, Control & Capture Endpoints

All HTTP endpoints support optional token authentication via query parameter `?token=<secret>` or HTTP header `X-Auth-Token: <secret>`.

### 6.1 Screenshots: `GET /api/screenshot`
Captures an uncompressed, lossless screenshot directly from the device via `adb exec-out screencap -p`.

- **Query Parameters**:
  - `serial` *(optional)*: Target device serial. Defaults to the active device.
- **Success Response**: HTTP `200 OK`
  - `Content-Type: image/png`
  - Body: Binary PNG image bytes.
- **Error Responses**:
  - `400 Bad Request`: Device serial missing or invalid format.
  - `500 Internal Server Error`: `screencap` command failed on device.

---

### 6.2 Hardware Video Recording: `POST /api/record/start`
Starts native hardware-accelerated H.264 recording directly on the Android device via `screenrecord` without host CPU re-encoding overhead.

- **Query Parameters**:
  - `serial` *(optional)*: Target device serial.
  - `bitRate` *(optional)*: Video bit rate in bits per second (default: `6000000` = 6 Mbps).
- **Success Response**: HTTP `200 OK`
  ```json
  {
    "status": "recording",
    "serial": "emulator-5554",
    "startedAt": "2026-11-14T12:00:00.000Z"
  }
  ```

---

### 6.3 Video Finalization & Pull: `POST /api/record/stop`
Stops an in-progress hardware screen recording by sending `SIGINT` (`pkill -2 screenrecord`) on the device. Waits for the MP4 `moov` atom container to finalize cleanly, pulls the completed MP4 to the host via `adb pull`, deletes the temporary file on `/sdcard/`, and streams the video bytes to the client.

- **Query Parameters**:
  - `serial` *(optional)*: Target device serial.
- **Success Response**: HTTP `200 OK`
  - `Content-Type: video/mp4`
  - `Content-Disposition: attachment; filename="thruwire_<serial>_<timestamp>.mp4"`
  - Body: Complete MP4 video bytes.
- **Error Responses**:
  - `500 Internal Server Error`: No active recording session or failed to pull finalized MP4 file.

---

### 6.4 External Scrcpy Launch: `POST /api/scrcpy/launch`
Launches the native `scrcpy` client for the target device. On Windows, ThruWire embeds the native scrcpy window directly into the mirror pane; on macOS and Linux, it launches as a standalone window.

- **Query Parameters**:
  - `serial` *(optional)*: Target device serial.
- **Success Response**: HTTP `200 OK`
  ```json
  {
    "status": "ok",
    "serial": "emulator-5554",
    "mode": "embedded"
  }
  ```
- **Error Responses**:
  - `500 Internal Server Error`: scrcpy executable not found on host system:
    ```json
    {
      "status": "not_installed",
      "message": "scrcpy executable not found on system PATH"
    }
    ```

---

### 6.5 Scrcpy Process Stop: `POST /api/scrcpy/stop`
Terminates an active scrcpy process instance for the given device.

- **Query Parameters**:
  - `serial` *(optional)*: Target device serial.
- **Success Response**: HTTP `200 OK`
  ```json
  {
    "status": "stopped"
  }
  ```

---

### 6.6 Scrcpy Binary Status: `GET /api/scrcpy/status`
Queries the host system to determine if `scrcpy` is available on the `PATH` or in local app cache directories.

- **Success Response**: HTTP `200 OK`
  ```json
  {
    "installed": true,
    "path": "C:\\Users\\User\\AppData\\Local\\ThruWire\\tools\\scrcpy\\scrcpy.exe",
    "version": "v3.1"
  }
  ```

---

### 6.7 Scrcpy Auto-Installer: `POST /api/scrcpy/install`
Automatically downloads the official pre-built `scrcpy` binary release archive from GitHub, verifies extraction, and configures the executable in the local tools cache (`%LOCALAPPDATA%\ThruWire\tools\scrcpy`).

- **Success Response**: HTTP `200 OK`
  ```json
  {
    "status": "ok",
    "path": "C:\\Users\\User\\AppData\\Local\\ThruWire\\tools\\scrcpy\\scrcpy.exe",
    "version": "v3.1"
  }
  ```

---

### 6.8 Shell Input Forwarding: `POST /api/input`
Injects interactive touch, swipe, key, or text events into the persistent `adb shell` process for sub-millisecond response latency (< 1ms).

- **Payload** (JSON body or query parameters):
  - **Tap**: `{"action": "tap", "x": 540, "y": 960, "serial": "emulator-5554"}`
  - **Swipe**: `{"action": "swipe", "x1": 540, "y1": 1500, "x2": 540, "y2": 500, "durationMs": 300, "serial": "emulator-5554"}`
  - **Key**: `{"action": "key", "keyCode": 4, "serial": "emulator-5554"}`
  - **Text**: `{"action": "text", "text": "Hello", "serial": "emulator-5554"}`
- **Success Response**: HTTP `200 OK` (`"OK"`)

---

## 7. HTTP Status & Error Codes

| Status Code | Meaning | Cause |
|---|---|---|
| `200 OK` | Success | Request succeeded and returned expected data. |
| `400 Bad Request` | Invalid Arguments | Missing or malformed device serial, or unparseable input coordinates. |
| `401 Unauthorized` | Auth Required | Server started with `--auth` / `--token`, but request lacked valid token credentials. |
| `403 Forbidden` | Origin Rejected | Browser `Origin:` header check failed (CSWSH defense). |
| `404 Not Found` | Unknown Endpoint | Requested URI path is not registered on the bridge server. |
| `500 Internal Error` | Execution Failure | Subprocess failure, ADB communication error, or scrcpy binary missing. |
