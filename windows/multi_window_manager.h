#ifndef MULTI_WINDOW_MANAGER_PLUGIN_MULTI_WINDOW_MANAGER_H_
#define MULTI_WINDOW_MANAGER_PLUGIN_MULTI_WINDOW_MANAGER_H_

#include <shobjidl_core.h>

#include "include/multi_window_manager/multi_window_manager_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <codecvt>
#include <dwmapi.h>
#include <map>
#include <memory>
#include <sstream>

#define STATE_NORMAL 0
#define STATE_MAXIMIZED 1
#define STATE_MINIMIZED 2
#define STATE_FULLSCREEN_ENTERED 3
#define STATE_DOCKED 4

namespace multi_window_manager {

    class MultiWindowManager {
    public:
        MultiWindowManager();

        virtual ~MultiWindowManager();

        inline static int64_t autoincrementId_ = 0;
        inline static std::map<int64_t, std::shared_ptr<FlutterWindow>> windows_ = {};
        inline static std::map<int64_t, std::shared_ptr<MultiWindowManager>>
                windowManagers_ = {};


        // IDs of windows whose FlutterWindow must be released on the main thread.
        // Populated in the plugin destructor (called during engine shutdown while
        // Win32Window::Destroy() is on the call stack), cleaned up on the next
        // main-thread call to avoid destructing Win32Window re-entrantly.
        inline static std::vector<int64_t> pendingWindowCleanup_ = {};

        std::unique_ptr<
        flutter::MethodChannel<flutter::EncodableValue>,
        std::default_delete<flutter::MethodChannel<flutter::EncodableValue>>>
        static_channel = nullptr;

        std::unique_ptr<
        flutter::MethodChannel<flutter::EncodableValue>,
        std::default_delete<flutter::MethodChannel<flutter::EncodableValue>>>
        channel = nullptr;

        int64_t id = -1;
        HWND native_window;
        int last_state = STATE_NORMAL;
        bool has_shadow_ = false;
        bool is_always_on_bottom_ = false;
        bool is_frameless_ = false;
        bool is_prevent_close_ = false;
        // When true, WM_CLOSE triggers hide+notify instead of a real destroy.
        // Set via ensureInitialized(isEnabledReuse: true) from Dart.
        // Operates independently from is_prevent_close_ so nested widgets can
        // still use setPreventClose freely.
        bool is_reuse_enabled_ = false;
        // True between a successful claimWindow() call and the next Show().
        // Prevents two concurrent createWindowOrReuse() callers from claiming
        // the same hidden window before it becomes visible again.
        bool is_being_reused_ = false;
        // Set to true when the window enters the hidden reuse pool (via WM_CLOSE).
        // Prevents hot-restart from re-showing the window via the standard
        // init -> show() / focus() path.
        // Reset to false when the window is legitimately reclaimed via
        // claimWindow() + Show().
        bool is_in_reuse_pool_ = false;
        double aspect_ratio_ = 0;
        POINT minimum_size_ = {0, 0};
        POINT maximum_size_ = {-1, -1};
        double pixel_ratio_ = 1;
        bool is_resizable_ = true;
        int is_docked_ = 0;
        bool is_registered_for_docking_ = false;
        bool is_skip_taskbar_ = true;
        std::string title_bar_style_ = "normal";
        double opacity_ = 1;

        bool is_resizing_ = false;
        bool is_moving_ = false;

        HWND GetMainWindow();
        void MultiWindowManager::ForceRefresh();
        void MultiWindowManager::ForceChildRefresh();
        void MultiWindowManager::SetAsFrameless();
        void MultiWindowManager::WaitUntilReadyToShow();
        void MultiWindowManager::Destroy();
        void MultiWindowManager::Close();
        bool MultiWindowManager::IsPreventClose();
        void MultiWindowManager::SetPreventClose(const flutter::EncodableMap& args);
        void MultiWindowManager::Focus();
        void MultiWindowManager::Blur();
        bool MultiWindowManager::IsFocused();
        void MultiWindowManager::Show();
        void MultiWindowManager::Hide();
        bool MultiWindowManager::IsVisible();
        bool MultiWindowManager::IsMaximized();
        void MultiWindowManager::Maximize(const flutter::EncodableMap& args);
        void MultiWindowManager::Unmaximize();
        bool MultiWindowManager::IsMinimized();
        void MultiWindowManager::Minimize();
        void MultiWindowManager::Restore();
        bool MultiWindowManager::IsDockable();
        int MultiWindowManager::IsDocked();
        void MultiWindowManager::Dock(const flutter::EncodableMap& args);
        bool MultiWindowManager::Undock();
        bool MultiWindowManager::IsFullScreen();
        void MultiWindowManager::SetFullScreen(const flutter::EncodableMap& args);
        void MultiWindowManager::SetAspectRatio(const flutter::EncodableMap& args);
        void MultiWindowManager::SetBackgroundColor(const flutter::EncodableMap& args);
        flutter::EncodableMap MultiWindowManager::GetBounds(
                const flutter::EncodableMap& args);
        void MultiWindowManager::SetBounds(const flutter::EncodableMap& args);
        void MultiWindowManager::SetMinimumSize(const flutter::EncodableMap& args);
        void MultiWindowManager::SetMaximumSize(const flutter::EncodableMap& args);
        bool MultiWindowManager::IsResizable();
        void MultiWindowManager::SetResizable(const flutter::EncodableMap& args);
        bool MultiWindowManager::IsMinimizable();
        void MultiWindowManager::SetMinimizable(const flutter::EncodableMap& args);
        bool MultiWindowManager::IsMaximizable();
        void MultiWindowManager::SetMaximizable(const flutter::EncodableMap& args);
        bool MultiWindowManager::IsClosable();
        void MultiWindowManager::SetClosable(const flutter::EncodableMap& args);
        bool MultiWindowManager::IsAlwaysOnTop();
        void MultiWindowManager::SetAlwaysOnTop(const flutter::EncodableMap& args);
        bool MultiWindowManager::IsAlwaysOnBottom();
        void MultiWindowManager::SetAlwaysOnBottom(const flutter::EncodableMap& args);
        std::string MultiWindowManager::GetTitle();
        void MultiWindowManager::SetTitle(const flutter::EncodableMap& args);
        void MultiWindowManager::SetTitleBarStyle(const flutter::EncodableMap& args);
        int MultiWindowManager::GetTitleBarHeight();
        bool MultiWindowManager::IsSkipTaskbar();
        void MultiWindowManager::SetSkipTaskbar(const flutter::EncodableMap& args);
        void MultiWindowManager::SetProgressBar(const flutter::EncodableMap& args);
        void MultiWindowManager::SetIcon(const flutter::EncodableMap& args);
        bool MultiWindowManager::HasShadow();
        void MultiWindowManager::SetHasShadow(const flutter::EncodableMap& args);
        double MultiWindowManager::GetOpacity();
        void MultiWindowManager::SetOpacity(const flutter::EncodableMap& args);
        void MultiWindowManager::SetBrightness(const flutter::EncodableMap& args);
        void MultiWindowManager::SetIgnoreMouseEvents(
                const flutter::EncodableMap& args);
        void MultiWindowManager::PopUpWindowMenu(const flutter::EncodableMap& args);
        void MultiWindowManager::StartDragging();
        void MultiWindowManager::StartResizing(const flutter::EncodableMap& args);

        static int64_t MultiWindowManager::createWindow(
                const std::vector<std::string>& args);

    private:
        static constexpr auto kFlutterViewWindowClassName = L"FLUTTERVIEW";
        bool g_is_window_fullscreen = false;
        std::string g_title_bar_style_before_fullscreen;
        RECT g_frame_before_fullscreen;
        bool g_maximized_before_fullscreen;
        LONG g_style_before_fullscreen;
        ITaskbarList3* taskbar_ = nullptr;
        double GetDpiForHwnd(HWND hWnd);
        BOOL MultiWindowManager::RegisterAccessBar(HWND hwnd, BOOL fRegister);
        void PASCAL MultiWindowManager::AppBarQuerySetPos(HWND hwnd,
        UINT uEdge,
                LPRECT lprc,
        PAPPBARDATA pabd);
        void MultiWindowManager::DockAccessBar(HWND hwnd, UINT edge, UINT windowWidth);
    };
}  // namespace multi_window_manager

#endif  // MULTI_WINDOW_MANAGER_PLUGIN_MULTI_WINDOW_MANAGER_H_