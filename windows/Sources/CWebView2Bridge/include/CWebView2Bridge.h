#ifndef CWEBVIEW2_BRIDGE_H
#define CWEBVIEW2_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WV2Handle WV2Handle;

typedef void (*WV2ReadyCallback)(void* ctx, bool ok);
typedef void (*WV2MessageCallback)(void* ctx, const char* jsonUtf8);
typedef void (*WV2NavCallback)(void* ctx, bool ok, const char* urlUtf8);
typedef void (*WV2NewWindowCallback)(void* ctx, const char* urlUtf8);
typedef void (*WV2CookiesCallback)(void* ctx, uint64_t requestId, const char* jsonUtf8);
typedef void (*WV2FullscreenCallback)(void* ctx, bool isFullscreen);
typedef bool (*WV2KeyDownCallback)(void* ctx, uint32_t virtualKey);

typedef struct WV2Callbacks {
    void* ctx;
    WV2ReadyCallback onReady;
    WV2MessageCallback onMessage;
    WV2NavCallback onNavigationCompleted;
    WV2NewWindowCallback onNewWindowRequested;
    WV2FullscreenCallback onFullscreenChanged;
    WV2KeyDownCallback onKeyDown;
} WV2Callbacks;

WV2Handle* wv2_create(
    void* parentHwnd,
    const char* userDataDirUtf8,
    int x,
    int y,
    int width,
    int height,
    bool visible,
    bool allowDevTools,
    bool blockNewWindows,
    WV2Callbacks callbacks
);

void wv2_destroy(WV2Handle* handle);
void wv2_set_bounds(WV2Handle* handle, int x, int y, int width, int height);
void wv2_set_visible(WV2Handle* handle, bool visible);
void wv2_notify_parent_window_position_changed(WV2Handle* handle);
void wv2_focus(WV2Handle* handle);
void wv2_navigate(WV2Handle* handle, const char* urlUtf8);
void wv2_navigate_with_referer(WV2Handle* handle, const char* urlUtf8, const char* refererUtf8);
void wv2_navigate_to_string(WV2Handle* handle, const char* htmlUtf8);
void wv2_post_web_message_json(WV2Handle* handle, const char* jsonUtf8);
void wv2_execute_script(WV2Handle* handle, const char* jsUtf8);
void wv2_set_doc_script(WV2Handle* handle, const char* jsUtf8);
void wv2_set_user_agent(WV2Handle* handle, const char* uaUtf8);
void wv2_set_background_color(WV2Handle* handle, uint8_t a, uint8_t r, uint8_t g, uint8_t b);
void wv2_set_preferred_color_scheme(WV2Handle* handle, int scheme); // 0=Auto, 1=Light, 2=Dark
void wv2_get_cookies(WV2Handle* handle, const char* uriUtf8, uint64_t requestId, WV2CookiesCallback cb, void* ctx);
void wv2_set_virtual_host_mapping(WV2Handle* handle, const char* hostUtf8, const char* folderPathUtf8);

#ifdef __cplusplus
}
#endif

#endif // CWEBVIEW2_BRIDGE_H
