// Native streaming HTTP transport for Linux.
// TLS verification stays enabled and redirects are not followed so an
// Authorization header is never forwarded to another host.

#include <curl/curl.h>

#include <cstdlib>
#include <cstring>
#include <mutex>
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

struct Context {
    DcadHttpChunkFn onChunk;
    DcadHttpCancelFn cancelled;
    void* userData;
    bool aborted;
};

char* copy_error(const char* text) {
    if (text == nullptr) return nullptr;
    const size_t length = std::strlen(text);
    char* buffer = static_cast<char*>(std::malloc(length + 1));
    if (buffer == nullptr) return nullptr;
    std::memcpy(buffer, text, length + 1);
    return buffer;
}

size_t write_chunk(char* bytes, size_t size, size_t count, void* userdata) {
    auto* context = static_cast<Context*>(userdata);
    const size_t length = size * count;
    if (length == 0) return 0;
    if (context->onChunk != nullptr && context->onChunk(bytes, length, context->userData) != 0) {
        context->aborted = true;
        return 0;
    }
    if (context->cancelled != nullptr && context->cancelled(context->userData) != 0) {
        context->aborted = true;
        return 0;
    }
    return length;
}

int check_cancel(void* userdata, curl_off_t, curl_off_t, curl_off_t, curl_off_t) {
    auto* context = static_cast<Context*>(userdata);
    if (context->cancelled != nullptr && context->cancelled(context->userData) != 0) {
        context->aborted = true;
        return 1;
    }
    return 0;
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

    static std::once_flag init;
    std::call_once(init, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });

    CURL* curl = curl_easy_init();
    if (curl == nullptr) {
        resultOut->error = copy_error("curl initialization failed");
        return -1;
    }

    Context context{onChunk, cancelled, userData, false};
    curl_slist* headers = nullptr;
    for (int i = 0; i < request->headerCount; ++i) {
        const auto& header = request->headers[i];
        if (header.name == nullptr || header.value == nullptr) continue;
        const std::string line = std::string(header.name) + ": " + header.value;
        headers = curl_slist_append(headers, line.c_str());
    }

    char errorBuffer[CURL_ERROR_SIZE] = {};
    curl_easy_setopt(curl, CURLOPT_URL, request->url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request->body != nullptr ? request->body : "");
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE,
                     static_cast<curl_off_t>(request->bodyLength));
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_chunk);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &context);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, errorBuffer);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, check_cancel);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &context);
    const long timeout = request->timeoutSeconds > 0 ? request->timeoutSeconds : 120;
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout);

    const CURLcode code = curl_easy_perform(curl);
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    resultOut->status = static_cast<int>(status);

    if (context.aborted) {
        resultOut->status = 0;
        resultOut->error = copy_error("cancelled");
    } else if (code != CURLE_OK) {
        resultOut->status = 0;
        const char* detail = errorBuffer[0] != '\0' ? errorBuffer : curl_easy_strerror(code);
        resultOut->error = copy_error(detail);
    } else if (status < 200 || status >= 300) {
        resultOut->error = copy_error("HTTP " + std::to_string(status));
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return 0;
}

void dcad_http_free_result(DcadHttpResult* result) {
    if (result == nullptr) return;
    std::free(result->error);
    result->error = nullptr;
    result->status = 0;
}

} // extern "C"
