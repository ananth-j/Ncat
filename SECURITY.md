# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

---

## Reporting a Vulnerability

The Wcat team takes the security of our application and its users seriously. If you discover a security vulnerability or suspect an issue that compromises the security of Wcat or host systems, please report it privately.

**Please DO NOT open a public issue.**

To report a vulnerability:
1. Open a confidential report via **GitHub Security Advisories** on the repository, or
2. Email security concerns directly to the project maintainers.

Please include:
- A description of the vulnerability and its potential impact.
- Steps to reproduce or a proof of concept (PoC).
- The operating system and Flutter / Dart version tested.

We will acknowledge receipt within 48 hours and work with you on a timeline for remediation and public disclosure.

---

## Security Model & Hardening

Wcat interacts with host operating system tools (`adb`, `scrcpy`) to stream Android system logs, video frames, and inject input events. Because it provides privileged communication with attached physical and virtual devices, Wcat implements the following layered security controls:

### 1. Loopback-Only Binding
The Dart bridge server strictly binds to the IPv4 loopback address (`127.0.0.1`). It refuses connections from external network interfaces (`0.0.0.0`), preventing unauthorized network-adjacent devices from accessing ADB or log streams.

### 2. Origin Header Validation (CSWSH Protection)
To protect against **Cross-Site WebSocket Hijacking (CSWSH)** and unauthorized browser-based requests, the server checks the HTTP `Origin:` header on WebSocket upgrade (`/ws`, `/stream`) and HTTP endpoints.
Requests originating from external domains (e.g. `https://malicious-website.com`) are immediately rejected with `403 Forbidden`. Only local loopback origins (`localhost`, `127.0.0.1`, `::1`) and native non-browser clients (which omit `Origin`) are accepted.

### 3. Session Token Authentication
For multi-user environments or shared workstations, the bridge server can be started with token authentication:
```sh
dart run bin/server.dart --auth
# or with an explicit token:
dart run bin/server.dart --token <your-secret-token>
```
When enabled, all HTTP API and WebSocket requests must supply the authentication token via:
- Query parameter: `?token=<secret>`
- HTTP Header: `X-Auth-Token: <secret>`
- HTTP Header: `Authorization: Bearer <secret>`

Unauthenticated requests receive `401 Unauthorized`. Static web assets (HTML/JS/WASM) remain accessible so the client UI can load and negotiate the session token.

### 4. Device Serial Validation & Flag-Injection Protection
All device serial numbers received via HTTP parameters or WebSocket messages are strictly validated:
- Must match pattern: `^[a-zA-Z0-9._:-]{1,64}$`
- Must **not** start with a dash (`-`), preventing command-line argument/flag injection into subcommands like `adb -s <serial>`.
- Invalid serials are rejected with `400 Bad Request` or dropped before process invocation.

### 5. Shell Command Sanitization for Input Injection
Text typed into the mirror view is sent to the device shell via `DeviceSession.sendInputText`:
- All ASCII and unicode control characters (including `\r`, `\n`, `\0`, `\x1B`) are stripped to prevent splitting or injecting additional shell commands.
- Spaces are encoded as `%s` according to Android's `input text` syntax.
- All single quotes are escaped with `'\''`, and the final string is single-quoted for POSIX shell execution.

### 6. Resource Limits & Denial-of-Service Defenses
- Hard cap of 2 concurrent real-time video streams (`kMaxConcurrentStreams = 2`) to protect host CPU and device battery.
- Logcat ring buffer is capped at 100,000 entries with automatic FIFO pruning and StringPool deduplication to prevent out-of-memory crashes.
- Disconnected devices immediately trigger `DeviceSession.dispose()`, cleanly shutting down child ADB and shell processes.
