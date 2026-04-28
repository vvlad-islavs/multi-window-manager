//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <multi_window_manager/multi_window_manager_plugin.h>
#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <tray_manager/tray_manager_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  MultiWindowManagerPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MultiWindowManagerPlugin"));
  ScreenRetrieverWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ScreenRetrieverWindowsPluginCApi"));
  TrayManagerPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("TrayManagerPlugin"));
}
