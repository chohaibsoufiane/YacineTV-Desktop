#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include "WebView2.h"
#include "include/CWebView2Bridge.h"

#include <atomic>
#include <functional>
#include <string>
#include <vector>

namespace {

static std::wstring utf8_to_wide(const char* s) {
    if (!s || !*s) return L"";
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    if (len <= 1) return L"";
    std::wstring out(static_cast<size_t>(len - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, -1, out.data(), len);
    return out;
}

static std::string wide_to_utf8(const wchar_t* s) {
    if (!s || !*s) return "";
    int len = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 1) return "";
    std::string out(static_cast<size_t>(len - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s, -1, out.data(), len, nullptr, nullptr);
    return out;
}

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[7];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
                break;
        }
    }
    return out;
}

template <typename TInterface, typename... TArgs>
class ComCallback final : public TInterface {
public:
    using Fn = std::function<HRESULT(TArgs...)>;

    explicit ComCallback(Fn fn) : m_fn(std::move(fn)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppvObject) override {
        if (!ppvObject) return E_POINTER;
        *ppvObject = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(TInterface)) {
            *ppvObject = static_cast<TInterface*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return ++m_refCount;
    }

    ULONG STDMETHODCALLTYPE Release() override {
        ULONG rc = --m_refCount;
        if (rc == 0) {
            delete this;
        }
        return rc;
    }

    HRESULT STDMETHODCALLTYPE Invoke(TArgs... args) override {
        return m_fn(args...);
    }

private:
    ~ComCallback() = default;
    std::atomic<ULONG> m_refCount{1};
    Fn m_fn;
};

struct VirtualHostEntry {
    std::wstring host;
    std::wstring folder;
};

} // namespace

struct WV2Handle {
    HWND parentHwnd = nullptr;
    std::wstring userDataDir;
    RECT bounds{0, 0, 0, 0};
    bool visible = true;
    bool allowDevTools = false;
    bool blockNewWindows = true;
    bool destroyed = false;
    bool ready = false;
    WV2Callbacks callbacks{};

    ICoreWebView2Environment* env = nullptr;
    ICoreWebView2Controller* controller = nullptr;
    ICoreWebView2* webview = nullptr;

    // Pending / active state
    bool hasPendingUrl = false;
    std::wstring pendingUrl;
    std::wstring pendingReferer;
    bool hasPendingHtml = false;
    std::wstring pendingHtml;
    bool hasPendingUa = false;
    std::wstring pendingUa;
    bool hasPendingDocScript = false;
    std::wstring pendingDocScript;
    std::wstring currentDocScriptId;
    bool hasPendingBgColor = false;
    COREWEBVIEW2_COLOR pendingBgColor{255, 16, 16, 20};
    int preferredColorScheme = 0; // 0=Auto, 1=Light, 2=Dark
    std::vector<VirtualHostEntry> pendingVirtualHosts;
};

static void apply_color_scheme(WV2Handle* h) {
    if (!h || !h->webview) return;
    ICoreWebView2_13* wv13 = nullptr;
    if (SUCCEEDED(h->webview->QueryInterface(__uuidof(ICoreWebView2_13), reinterpret_cast<void**>(&wv13))) && wv13) {
        ICoreWebView2Profile* profile = nullptr;
        if (SUCCEEDED(wv13->get_Profile(&profile)) && profile) {
            COREWEBVIEW2_PREFERRED_COLOR_SCHEME scheme = COREWEBVIEW2_PREFERRED_COLOR_SCHEME_AUTO;
            if (h->preferredColorScheme == 1) scheme = COREWEBVIEW2_PREFERRED_COLOR_SCHEME_LIGHT;
            else if (h->preferredColorScheme == 2) scheme = COREWEBVIEW2_PREFERRED_COLOR_SCHEME_DARK;
            profile->put_PreferredColorScheme(scheme);
            profile->Release();
        }
        wv13->Release();
    }
}

static void apply_background_color(WV2Handle* h) {
    if (!h || !h->controller || !h->hasPendingBgColor) return;
    ICoreWebView2Controller2* ctrl2 = nullptr;
    if (SUCCEEDED(h->controller->QueryInterface(__uuidof(ICoreWebView2Controller2), reinterpret_cast<void**>(&ctrl2))) && ctrl2) {
        ctrl2->put_DefaultBackgroundColor(h->pendingBgColor);
        ctrl2->Release();
    }
}

static void apply_user_agent(WV2Handle* h) {
    if (!h || !h->webview || !h->hasPendingUa) return;
    ICoreWebView2Settings* settings = nullptr;
    if (SUCCEEDED(h->webview->get_Settings(&settings)) && settings) {
        ICoreWebView2Settings2* settings2 = nullptr;
        if (SUCCEEDED(settings->QueryInterface(__uuidof(ICoreWebView2Settings2), reinterpret_cast<void**>(&settings2))) && settings2) {
            settings2->put_UserAgent(h->pendingUa.c_str());
            settings2->Release();
        }
        settings->Release();
    }
}

static void apply_doc_script(WV2Handle* h) {
    if (!h || !h->webview || !h->hasPendingDocScript) return;
    if (!h->currentDocScriptId.empty()) {
        h->webview->RemoveScriptToExecuteOnDocumentCreated(h->currentDocScriptId.c_str());
        h->currentDocScriptId.clear();
    }
    if (h->pendingDocScript.empty()) return;
    auto* cb = new ComCallback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, HRESULT, LPCWSTR>(
        [h](HRESULT err, LPCWSTR id) -> HRESULT {
            if (!h->destroyed && SUCCEEDED(err) && id) {
                h->currentDocScriptId = id;
            }
            return S_OK;
        }
    );
    h->webview->AddScriptToExecuteOnDocumentCreated(h->pendingDocScript.c_str(), cb);
    cb->Release();
}

static void apply_virtual_hosts(WV2Handle* h) {
    if (!h || !h->webview || h->pendingVirtualHosts.empty()) return;
    ICoreWebView2_3* wv3 = nullptr;
    if (SUCCEEDED(h->webview->QueryInterface(__uuidof(ICoreWebView2_3), reinterpret_cast<void**>(&wv3))) && wv3) {
        for (const auto& entry : h->pendingVirtualHosts) {
            wv3->SetVirtualHostNameToFolderMapping(
                entry.host.c_str(),
                entry.folder.c_str(),
                COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW
            );
        }
        h->pendingVirtualHosts.clear();
        wv3->Release();
    }
}

static void navigate_internal(WV2Handle* h, const std::wstring& wurl, const std::wstring& wref) {
    if (!h || !h->webview || wurl.empty()) return;
    if (!wref.empty() && h->env) {
        ICoreWebView2Environment2* env2 = nullptr;
        ICoreWebView2_2* wv2 = nullptr;
        if (SUCCEEDED(h->env->QueryInterface(__uuidof(ICoreWebView2Environment2), reinterpret_cast<void**>(&env2))) && env2 &&
            SUCCEEDED(h->webview->QueryInterface(__uuidof(ICoreWebView2_2), reinterpret_cast<void**>(&wv2))) && wv2) {
            std::wstring headers = L"Referer: " + wref + L"\r\n";
            ICoreWebView2WebResourceRequest* req = nullptr;
            if (SUCCEEDED(env2->CreateWebResourceRequest(wurl.c_str(), L"GET", nullptr, headers.c_str(), &req)) && req) {
                HRESULT hr = wv2->NavigateWithWebResourceRequest(req);
                req->Release();
                wv2->Release();
                env2->Release();
                if (SUCCEEDED(hr)) return;
            }
        }
        if (wv2) wv2->Release();
        if (env2) env2->Release();
    }
    h->webview->Navigate(wurl.c_str());
}

static void on_controller_created(WV2Handle* h, HRESULT result, ICoreWebView2Controller* controller) {
    if (h->destroyed || FAILED(result) || !controller) {
        if (!h->destroyed && h->callbacks.onReady) {
            h->callbacks.onReady(h->callbacks.ctx, false);
        }
        return;
    }

    h->controller = controller;
    h->controller->AddRef();

    h->controller->get_CoreWebView2(&h->webview);
    if (!h->webview) {
        if (h->callbacks.onReady) h->callbacks.onReady(h->callbacks.ctx, false);
        return;
    }

    ICoreWebView2Settings* settings = nullptr;
    if (SUCCEEDED(h->webview->get_Settings(&settings)) && settings) {
        settings->put_IsScriptEnabled(TRUE);
        settings->put_IsWebMessageEnabled(TRUE);
        settings->put_IsStatusBarEnabled(FALSE);
        settings->put_AreDefaultScriptDialogsEnabled(TRUE);
        settings->put_AreDevToolsEnabled(h->allowDevTools ? TRUE : FALSE);
        settings->put_AreDefaultContextMenusEnabled(h->allowDevTools ? TRUE : FALSE);
        settings->Release();
    }

    h->controller->put_Bounds(h->bounds);
    h->controller->put_IsVisible(h->visible ? TRUE : FALSE);

    apply_color_scheme(h);
    apply_background_color(h);
    apply_user_agent(h);
    apply_virtual_hosts(h);
    apply_doc_script(h);

    EventRegistrationToken token{};
    auto* msgHandler = new ComCallback<ICoreWebView2WebMessageReceivedEventHandler, ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs*>(
        [h](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
            if (h->destroyed || !args || !h->callbacks.onMessage) return S_OK;
            LPWSTR raw = nullptr;
            if (SUCCEEDED(args->get_WebMessageAsJson(&raw)) && raw) {
                std::string utf8 = wide_to_utf8(raw);
                CoTaskMemFree(raw);
                h->callbacks.onMessage(h->callbacks.ctx, utf8.c_str());
            }
            return S_OK;
        }
    );
    h->webview->add_WebMessageReceived(msgHandler, &token);
    msgHandler->Release();

    auto* navHandler = new ComCallback<ICoreWebView2NavigationCompletedEventHandler, ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs*>(
        [h](ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
            if (h->destroyed || !h->callbacks.onNavigationCompleted) return S_OK;
            BOOL ok = FALSE;
            if (args) args->get_IsSuccess(&ok);
            LPWSTR source = nullptr;
            std::string urlUtf8;
            if (sender && SUCCEEDED(sender->get_Source(&source)) && source) {
                urlUtf8 = wide_to_utf8(source);
                CoTaskMemFree(source);
            }
            h->callbacks.onNavigationCompleted(h->callbacks.ctx, ok == TRUE, urlUtf8.c_str());
            return S_OK;
        }
    );
    h->webview->add_NavigationCompleted(navHandler, &token);
    navHandler->Release();

    auto* newWinHandler = new ComCallback<ICoreWebView2NewWindowRequestedEventHandler, ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs*>(
        [h](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
            if (h->destroyed || !args) return S_OK;
            if (h->blockNewWindows) {
                args->put_Handled(TRUE);
            }
            if (h->callbacks.onNewWindowRequested) {
                LPWSTR uri = nullptr;
                std::string uriUtf8;
                if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                    uriUtf8 = wide_to_utf8(uri);
                    CoTaskMemFree(uri);
                }
                h->callbacks.onNewWindowRequested(h->callbacks.ctx, uriUtf8.c_str());
            }
            return S_OK;
        }
    );
    h->webview->add_NewWindowRequested(newWinHandler, &token);
    newWinHandler->Release();

    auto* fsHandler = new ComCallback<ICoreWebView2ContainsFullScreenElementChangedEventHandler, ICoreWebView2*, IUnknown*>(
        [h](ICoreWebView2* sender, IUnknown*) -> HRESULT {
            if (h->destroyed || !sender || !h->callbacks.onFullscreenChanged) return S_OK;
            BOOL fs = FALSE;
            if (SUCCEEDED(sender->get_ContainsFullScreenElement(&fs))) {
                h->callbacks.onFullscreenChanged(h->callbacks.ctx, fs == TRUE);
            }
            return S_OK;
        }
    );
    h->webview->add_ContainsFullScreenElementChanged(fsHandler, &token);
    fsHandler->Release();

    auto* keyHandler = new ComCallback<ICoreWebView2AcceleratorKeyPressedEventHandler, ICoreWebView2Controller*, ICoreWebView2AcceleratorKeyPressedEventArgs*>(
        [h](ICoreWebView2Controller*, ICoreWebView2AcceleratorKeyPressedEventArgs* args) -> HRESULT {
            if (h->destroyed || !args || !h->callbacks.onKeyDown) return S_OK;
            COREWEBVIEW2_KEY_EVENT_KIND kind = COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN;
            if (SUCCEEDED(args->get_KeyEventKind(&kind)) && kind == COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN) {
                UINT vk = 0;
                if (SUCCEEDED(args->get_VirtualKey(&vk))) {
                    if (h->callbacks.onKeyDown(h->callbacks.ctx, static_cast<uint32_t>(vk))) {
                        args->put_Handled(TRUE);
                    }
                }
            }
            return S_OK;
        }
    );
    h->controller->add_AcceleratorKeyPressed(keyHandler, &token);
    keyHandler->Release();

    h->ready = true;

    if (h->hasPendingHtml) {
        h->hasPendingHtml = false;
        h->webview->NavigateToString(h->pendingHtml.c_str());
        h->pendingHtml.clear();
    } else if (h->hasPendingUrl) {
        h->hasPendingUrl = false;
        std::wstring u = std::move(h->pendingUrl);
        std::wstring r = std::move(h->pendingReferer);
        h->pendingUrl.clear();
        h->pendingReferer.clear();
        navigate_internal(h, u, r);
    }

    if (h->callbacks.onReady) {
        h->callbacks.onReady(h->callbacks.ctx, true);
    }
}

extern "C" {

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
) {
    auto* h = new WV2Handle();
    h->parentHwnd = static_cast<HWND>(parentHwnd);
    h->userDataDir = utf8_to_wide(userDataDirUtf8);
    h->bounds = RECT{x, y, x + width, y + height};
    h->visible = visible;
    h->allowDevTools = allowDevTools;
    h->blockNewWindows = blockNewWindows;
    h->callbacks = callbacks;

    auto* envCompleted = new ComCallback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, HRESULT, ICoreWebView2Environment*>(
        [h](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
            if (h->destroyed || FAILED(result) || !env) {
                if (!h->destroyed && h->callbacks.onReady) {
                    h->callbacks.onReady(h->callbacks.ctx, false);
                }
                return S_OK;
            }
            h->env = env;
            h->env->AddRef();

            auto* ctrlCompleted = new ComCallback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, HRESULT, ICoreWebView2Controller*>(
                [h](HRESULT ctrlResult, ICoreWebView2Controller* ctrl) -> HRESULT {
                    on_controller_created(h, ctrlResult, ctrl);
                    return S_OK;
                }
            );
            HRESULT hrCtrl = env->CreateCoreWebView2Controller(h->parentHwnd, ctrlCompleted);
            ctrlCompleted->Release();
            if (FAILED(hrCtrl) && !h->destroyed && h->callbacks.onReady) {
                h->callbacks.onReady(h->callbacks.ctx, false);
            }
            return S_OK;
        }
    );

    const wchar_t* udf = h->userDataDir.empty() ? nullptr : h->userDataDir.c_str();
    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(nullptr, udf, nullptr, envCompleted);
    envCompleted->Release();
    if (FAILED(hr) && h->callbacks.onReady) {
        h->callbacks.onReady(h->callbacks.ctx, false);
    }
    return h;
}

void wv2_destroy(WV2Handle* h) {
    if (!h) return;
    h->destroyed = true;
    h->callbacks = {};
    if (h->controller) {
        h->controller->Close();
        h->controller->Release();
        h->controller = nullptr;
    }
    if (h->webview) {
        h->webview->Release();
        h->webview = nullptr;
    }
    if (h->env) {
        h->env->Release();
        h->env = nullptr;
    }
    delete h;
}

void wv2_set_bounds(WV2Handle* h, int x, int y, int width, int height) {
    if (!h) return;
    h->bounds = RECT{x, y, x + width, y + height};
    if (h->controller) {
        h->controller->put_Bounds(h->bounds);
    }
}

void wv2_set_visible(WV2Handle* h, bool visible) {
    if (!h) return;
    h->visible = visible;
    if (h->controller) {
        h->controller->put_IsVisible(visible ? TRUE : FALSE);
    }
}

void wv2_notify_parent_window_position_changed(WV2Handle* h) {
    if (!h || !h->controller) return;
    h->controller->NotifyParentWindowPositionChanged();
}

void wv2_focus(WV2Handle* h) {
    if (!h || !h->controller) return;
    h->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
}

void wv2_navigate(WV2Handle* h, const char* urlUtf8) {
    wv2_navigate_with_referer(h, urlUtf8, nullptr);
}

void wv2_navigate_with_referer(WV2Handle* h, const char* urlUtf8, const char* refererUtf8) {
    if (!h) return;
    std::wstring wurl = utf8_to_wide(urlUtf8);
    std::wstring wref = utf8_to_wide(refererUtf8);
    if (h->webview) {
        navigate_internal(h, wurl, wref);
    } else {
        h->pendingUrl = std::move(wurl);
        h->pendingReferer = std::move(wref);
        h->hasPendingUrl = true;
        h->hasPendingHtml = false;
    }
}

void wv2_navigate_to_string(WV2Handle* h, const char* htmlUtf8) {
    if (!h) return;
    std::wstring whtml = utf8_to_wide(htmlUtf8);
    if (h->webview) {
        h->webview->NavigateToString(whtml.c_str());
    } else {
        h->pendingHtml = std::move(whtml);
        h->hasPendingHtml = true;
        h->hasPendingUrl = false;
    }
}

void wv2_post_web_message_json(WV2Handle* h, const char* jsonUtf8) {
    if (!h || !h->webview || !jsonUtf8) return;
    std::wstring wjson = utf8_to_wide(jsonUtf8);
    h->webview->PostWebMessageAsJson(wjson.c_str());
}

void wv2_execute_script(WV2Handle* h, const char* jsUtf8) {
    if (!h || !h->webview || !jsUtf8) return;
    std::wstring wjs = utf8_to_wide(jsUtf8);
    h->webview->ExecuteScript(wjs.c_str(), nullptr);
}

void wv2_set_doc_script(WV2Handle* h, const char* jsUtf8) {
    if (!h) return;
    h->pendingDocScript = utf8_to_wide(jsUtf8);
    h->hasPendingDocScript = true;
    if (h->webview) {
        apply_doc_script(h);
    }
}

void wv2_set_user_agent(WV2Handle* h, const char* uaUtf8) {
    if (!h) return;
    h->pendingUa = utf8_to_wide(uaUtf8);
    h->hasPendingUa = !h->pendingUa.empty();
    if (h->webview) {
        apply_user_agent(h);
    }
}

void wv2_set_background_color(WV2Handle* h, uint8_t a, uint8_t r, uint8_t g, uint8_t b) {
    if (!h) return;
    h->pendingBgColor = COREWEBVIEW2_COLOR{a, r, g, b};
    h->hasPendingBgColor = true;
    apply_background_color(h);
}

void wv2_set_preferred_color_scheme(WV2Handle* h, int scheme) {
    if (!h) return;
    h->preferredColorScheme = scheme;
    apply_color_scheme(h);
}

void wv2_set_virtual_host_mapping(WV2Handle* h, const char* hostUtf8, const char* folderPathUtf8) {
    if (!h || !hostUtf8 || !folderPathUtf8) return;
    VirtualHostEntry entry{utf8_to_wide(hostUtf8), utf8_to_wide(folderPathUtf8)};
    if (h->webview) {
        h->pendingVirtualHosts.push_back(std::move(entry));
        apply_virtual_hosts(h);
    } else {
        h->pendingVirtualHosts.push_back(std::move(entry));
    }
}

void wv2_get_cookies(WV2Handle* h, const char* uriUtf8, uint64_t requestId, WV2CookiesCallback cb, void* ctx) {
    if (!cb) return;
    if (!h || !h->webview || h->destroyed) {
        cb(ctx, requestId, "[]");
        return;
    }

    ICoreWebView2_2* wv2 = nullptr;
    if (FAILED(h->webview->QueryInterface(__uuidof(ICoreWebView2_2), reinterpret_cast<void**>(&wv2))) || !wv2) {
        cb(ctx, requestId, "[]");
        return;
    }

    ICoreWebView2CookieManager* mgr = nullptr;
    if (FAILED(wv2->get_CookieManager(&mgr)) || !mgr) {
        wv2->Release();
        cb(ctx, requestId, "[]");
        return;
    }
    wv2->Release();

    std::wstring wuri = utf8_to_wide(uriUtf8);
    auto* done = new ComCallback<ICoreWebView2GetCookiesCompletedHandler, HRESULT, ICoreWebView2CookieList*>(
        [h, requestId, cb, ctx](HRESULT err, ICoreWebView2CookieList* list) -> HRESULT {
            if (!cb) return S_OK;
            if (h->destroyed || FAILED(err) || !list) {
                cb(ctx, requestId, "[]");
                return S_OK;
            }
            UINT count = 0;
            list->get_Count(&count);
            std::string json = "[";
            bool first = true;
            for (UINT i = 0; i < count; ++i) {
                ICoreWebView2Cookie* cookie = nullptr;
                if (SUCCEEDED(list->GetValueAtIndex(i, &cookie)) && cookie) {
                    LPWSTR wname = nullptr, wval = nullptr, wdom = nullptr;
                    cookie->get_Name(&wname);
                    cookie->get_Value(&wval);
                    cookie->get_Domain(&wdom);
                    std::string name = wname ? wide_to_utf8(wname) : "";
                    std::string val = wval ? wide_to_utf8(wval) : "";
                    std::string dom = wdom ? wide_to_utf8(wdom) : "";
                    if (wname) CoTaskMemFree(wname);
                    if (wval) CoTaskMemFree(wval);
                    if (wdom) CoTaskMemFree(wdom);
                    cookie->Release();
                    if (!name.empty()) {
                        if (!first) json += ",";
                        first = false;
                        json += "{\"name\":\"" + json_escape(name) + "\",";
                        json += "\"value\":\"" + json_escape(val) + "\",";
                        json += "\"domain\":\"" + json_escape(dom) + "\"}";
                    }
                }
            }
            json += "]";
            cb(ctx, requestId, json.c_str());
            return S_OK;
        }
    );

    HRESULT hr = mgr->GetCookies(wuri.empty() ? nullptr : wuri.c_str(), done);
    done->Release();
    mgr->Release();
    if (FAILED(hr)) {
        cb(ctx, requestId, "[]");
    }
}

} // extern "C"
