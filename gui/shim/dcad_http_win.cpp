// Native streaming HTTP transport for Windows.
// WinHTTP is an OS component and keeps the shim compatible with /MT.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {

typedef struct DcadHttpHeader {
    const char* name;
    const char* value;
} DcadHttpHeader;

typedef struct DcadHttpRequest {
    const char* url;
    const DcadHttpHeader* headers;
    int headerCount;
    const char* body;
    size_t bodyLength;
    int timeoutSeconds;
} DcadHttpRequest;

typedef struct DcadHttpResult {
    int status;
    char* error;
} DcadHttpResult;

typedef int (*DcadHttpChunkFn)(const char* bytes, size_t length, void* userData);
typedef int (*DcadHttpCancelFn)(void* userData);

namespace {

char* copy_error(const char* text) {
    if (text == nullptr) return nullptr;
    const size_t length = std::strlen(text);
    char* buffer = static_cast<char*>(std::malloc(length + 1));
    if (buffer == nullptr) return nullptr;
    std::memcpy(buffer, text, length + 1);
    return buffer;
}

char* last_error() {
    const DWORD code = GetLastError();
    if (code == 0) return copy_error("WinHTTP request failed");
    LPWSTR message = nullptr;
    const DWORD size = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<LPWSTR>(&message), 0, nullptr);
    if (size == 0 || message == nullptr) {
        if (message != nullptr) LocalFree(message);
        return copy_error("WinHTTP request failed");
    }
    const int needed = WideCharToMultiByte(CP_UTF8, 0, message,
        static_cast<int>(size), nullptr, 0, nullptr, nullptr);
    std::string text(needed > 0 ? needed : 0, '\0');
    if (needed > 0)
        WideCharToMultiByte(CP_UTF8, 0, message, static_cast<int>(size),
                            &text[0], needed, nullptr, nullptr);
    LocalFree(message);
    while (!text.empty() && (text.back() == '\r' || text.back() == '\n'))
        text.pop_back();
    return copy_error(text.c_str());
}

std::wstring widen(const char* text) {
    if (text == nullptr || *text == '\0') return std::wstring();
    const int needed = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
    if (needed <= 0) return std::wstring();
    std::wstring result(needed, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text, -1, &result[0], needed);
    result.resize(needed - 1);
    return result;
}

} // namespace

int dcad_http_post_stream(const DcadHttpRequest* request,
                          DcadHttpChunkFn onChunk,
                          DcadHttpCancelFn cancelled,
                          void* userData,
                          DcadHttpResult* resultOut) {
    if (resultOut == nullptr) return -1;
    resultOut->status = 0;
    resultOut->error = nullptr;
    if (request == nullptr || request->url == nullptr) {
        resultOut->error = copy_error("invalid HTTP request");
        return -1;
    }

    URL_COMPONENTS parts = {};
    parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = 1;
    parts.dwHostNameLength = 1;
    parts.dwUrlPathLength = 1;
    parts.dwExtraInfoLength = 1;
    const std::wstring url = widen(request->url);
    if (url.empty() || !WinHttpCrackUrl(url.c_str(), 0, 0, &parts)) {
        resultOut->error = last_error();
        return -1;
    }

    HINTERNET session = WinHttpOpen(L"dcad-agent/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS, 0);
    if (session == nullptr) {
        resultOut->error = last_error();
        return -1;
    }

    const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    HINTERNET connection = WinHttpConnect(session, host.c_str(),
                                          parts.nPort, 0);
    if (connection == nullptr) {
        resultOut->error = last_error();
        WinHttpCloseHandle(session);
        return -1;
    }

    const std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    const DWORD flags = parts.nScheme == INTERNET_SCHEME_HTTPS
        ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET handle = WinHttpOpenRequest(connection, L"POST", path.c_str(),
        nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (handle == nullptr) {
        resultOut->error = last_error();
        WinHttpCloseHandle(connection);
        WinHttpCloseHandle(session);
        return -1;
    }

    const DWORD timeout = request->timeoutSeconds > 0
        ? static_cast<DWORD>(request->timeoutSeconds) * 1000 : 120000;
    WinHttpSetTimeouts(handle, static_cast<int>(timeout), static_cast<int>(timeout),
                       static_cast<int>(timeout), static_cast<int>(timeout));

    for (int i = 0; i < request->headerCount; ++i) {
        const auto& header = request->headers[i];
        if (header.name == nullptr || header.value == nullptr) continue;
        const std::wstring line = widen((std::string(header.name) + ": " + header.value).c_str());
        WinHttpAddRequestHeaders(handle, line.c_str(),
            static_cast<DWORD>(line.length()),
            WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    }

    if (!WinHttpSendRequest(handle, WINHTTP_NO_HEADERS, 0,
                            const_cast<char*>(request->body),
                            static_cast<DWORD>(request->bodyLength),
                            static_cast<DWORD>(request->bodyLength), 0)) {
        resultOut->error = last_error();
        WinHttpCloseHandle(handle);
        WinHttpCloseHandle(connection);
        WinHttpCloseHandle(session);
        return -1;
    }

    if (!WinHttpReceiveResponse(handle, nullptr)) {
        resultOut->error = last_error();
        WinHttpCloseHandle(handle);
        WinHttpCloseHandle(connection);
        WinHttpCloseHandle(session);
        return -1;
    }

    DWORD status = 0;
    DWORD statusLength = sizeof(status);
    WinHttpQueryHeaders(handle,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusLength,
        WINHTTP_NO_HEADER_INDEX);
    resultOut->status = static_cast<int>(status);

    bool aborted = false;
    char buffer[8192];
    for (;;) {
        if (cancelled != nullptr && cancelled(userData) != 0) {
            aborted = true;
            break;
        }
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(handle, &available)) {
            resultOut->error = last_error();
            break;
        }
        if (available == 0) break;
        DWORD read = 0;
        if (!WinHttpReadData(handle, buffer,
                static_cast<DWORD>(sizeof(buffer)), &read)) {
            resultOut->error = last_error();
            break;
        }
        if (read == 0) break;
        if (onChunk != nullptr && onChunk(buffer, read, userData) != 0) {
            aborted = true;
            break;
        }
    }

    if (aborted) {
        resultOut->status = 0;
        resultOut->error = copy_error("cancelled");
    } else if (resultOut->error == nullptr &&
               (status < 200 || status >= 300)) {
        resultOut->error = copy_error(
            ("HTTP " + std::to_string(status)).c_str());
    }

    WinHttpCloseHandle(handle);
    WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    return 0;
}

void dcad_http_free_result(DcadHttpResult* result) {
    if (result == nullptr) return;
    std::free(result->error);
    result->error = nullptr;
    result->status = 0;
}

} // extern "C"
