#include "flutter_window.h"

#include <optional>
#include <cstdint>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  scrcpy_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ThruWire/scrcpy_embed",
      &flutter::StandardMethodCodec::GetInstance());
  scrcpy_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "attach") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("bad_args", "Expected a map of window bounds");
            return;
          }
          const auto get_number = [args](const char* key) -> int {
            const auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return 0;
            if (const auto* value = std::get_if<int32_t>(&it->second)) {
              return *value;
            }
            if (const auto* value = std::get_if<int64_t>(&it->second)) {
              return static_cast<int>(*value);
            }
            return 0;
          };
          const auto it = args->find(flutter::EncodableValue("title"));
          if (it == args->end() ||
              !std::holds_alternative<std::string>(it->second)) {
            result->Error("bad_args", "Expected scrcpy window title");
            return;
          }
          const auto title = std::get<std::string>(it->second);
          const auto wide_title = std::wstring(title.begin(), title.end());
          HWND target = FindWindowW(nullptr, wide_title.c_str());
          if (!target) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          if (scrcpy_windows_[wide_title] != target) {
            scrcpy_windows_[wide_title] = target;
            SetParent(target, flutter_controller_->view()->GetNativeWindow());
            const LONG_PTR style = GetWindowLongPtrW(target, GWL_STYLE);
            SetWindowLongPtrW(target, GWL_STYLE,
                              (style | WS_CHILD) &
                                  ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME));
          }
          const int x = get_number("x");
          const int y = get_number("y");
          const int width = get_number("width");
          const int height = get_number("height");
          SetWindowPos(target, HWND_TOP, x, y, width, height,
                       SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "detach") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args) {
            const auto it = args->find(flutter::EncodableValue("title"));
            if (it != args->end() &&
                std::holds_alternative<std::string>(it->second)) {
              const auto title = std::get<std::string>(it->second);
              const auto wide_title = std::wstring(title.begin(), title.end());
              const auto window_it = scrcpy_windows_.find(wide_title);
              if (window_it != scrcpy_windows_.end()) {
                if (IsWindow(window_it->second)) {
                  PostMessageW(window_it->second, WM_CLOSE, 0, 0);
                }
                scrcpy_windows_.erase(window_it);
              }
            }
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  for (const auto& entry : scrcpy_windows_) {
    const auto window = entry.second;
    if (IsWindow(window)) {
      PostMessageW(window, WM_CLOSE, 0, 0);
    }
  }
  scrcpy_windows_.clear();
  scrcpy_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
