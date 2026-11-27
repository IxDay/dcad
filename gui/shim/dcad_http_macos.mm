// Native streaming HTTP transport for macOS.
// Uses NSURLSession/Foundation so the release payload does not need a curl dylib.
// Foundation delivers data on its own queue, so chunks are queued here and
// handed to the D callbacks only on the calling worker thread.

#import <Foundation/Foundation.h>

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

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

} // namespace

@interface DcadHttpDelegate : NSObject <NSURLSessionDataDelegate> {
@public
    std::mutex mutex;
    std::condition_variable condition;
    std::deque<std::vector<char>> chunks;
    int status;
    BOOL finished;
    std::string failureText;
}
@end

@implementation DcadHttpDelegate

- (void)URLSession:(NSURLSession*)session
           dataTask:(NSURLSessionDataTask*)dataTask
 didReceiveResponse:(NSURLResponse*)response
  completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    (void)dataTask;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if ([response isKindOfClass:[NSHTTPURLResponse class]])
            status = static_cast<int>([(NSHTTPURLResponse*)response statusCode]);
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession*)session
           dataTask:(NSURLSessionDataTask*)dataTask
     didReceiveData:(NSData*)data {
    (void)session;
    (void)dataTask;
    const char* bytes = static_cast<const char*>([data bytes]);
    const size_t length = [data length];
    std::vector<char> chunk;
    if (bytes != nullptr && length > 0)
        chunk.assign(bytes, bytes + length);
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (finished) return;
        chunks.push_back(std::move(chunk));
    }
    condition.notify_one();
}

- (void)URLSession:(NSURLSession*)session
               task:(NSURLSessionTask*)task
 willPerformHTTPRedirection:(NSHTTPURLResponse*)response
         newRequest:(NSURLRequest*)request
  completionHandler:(void (^)(NSURLRequest*))completionHandler {
    (void)session;
    (void)task;
    (void)response;
    (void)request;
    // Never forward Authorization to another host.
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession*)session
               task:(NSURLSessionTask*)task
 didCompleteWithError:(NSError*)error {
    (void)session;
    (void)task;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (error != nil) {
            const char* text = [[error localizedDescription] UTF8String];
            failureText = text != nullptr ? text : "NSURLSession request failed";
        }
        finished = YES;
    }
    condition.notify_all();
}

@end

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

    @autoreleasepool {
        NSString* urlText = [NSString stringWithUTF8String:request->url];
        NSURL* url = [NSURL URLWithString:urlText];
        if (url == nil) {
            resultOut->error = copy_error("invalid HTTP URL");
            return -1;
        }

        NSMutableURLRequest* requestObj = [NSMutableURLRequest requestWithURL:url];
        [requestObj setHTTPMethod:@"POST"];
        if (request->body != nullptr && request->bodyLength > 0)
            [requestObj setHTTPBody:[NSData dataWithBytes:request->body
                                                   length:request->bodyLength]];
        for (int i = 0; i < request->headerCount; ++i) {
            const auto& header = request->headers[i];
            if (header.name == nullptr || header.value == nullptr) continue;
            [requestObj setValue:[NSString stringWithUTF8String:header.value]
              forHTTPHeaderField:[NSString stringWithUTF8String:header.name]];
        }

        const auto seconds = request->timeoutSeconds > 0
            ? request->timeoutSeconds : 120;
        [requestObj setTimeoutInterval:seconds];

        DcadHttpDelegate* delegate = [[DcadHttpDelegate alloc] init];
        delegate->status = 0;
        delegate->finished = NO;

        NSURLSessionConfiguration* configuration =
            [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLSession* session = [NSURLSession sessionWithConfiguration:configuration
                                                              delegate:delegate
                                                         delegateQueue:nil];
        NSURLSessionDataTask* task = [session dataTaskWithRequest:requestObj];
        [task resume];

        const auto deadline = std::chrono::steady_clock::now()
            + std::chrono::seconds(seconds + 1);
        bool aborted = false;
        bool finished = false;
        int status = 0;
        std::string failure;

        while (!finished) {
            std::vector<char> chunk;
            {
                std::unique_lock<std::mutex> lock(delegate->mutex);
                const bool ready = delegate->condition.wait_for(
                    lock, std::chrono::milliseconds(20),
                    [delegate] { return !delegate->chunks.empty()
                                      || delegate->finished; });
                if (!ready && std::chrono::steady_clock::now() >= deadline) {
                    aborted = true;
                    break;
                }
                if (!delegate->chunks.empty()) {
                    chunk = std::move(delegate->chunks.front());
                    delegate->chunks.pop_front();
                } else if (delegate->finished) {
                    finished = true;
                }
            }
            if (!chunk.empty() && onChunk != nullptr &&
                onChunk(chunk.data(), chunk.size(), userData) != 0) {
                aborted = true;
                break;
            }
            if (cancelled != nullptr && cancelled(userData) != 0) {
                aborted = true;
                break;
            }
            if (std::chrono::steady_clock::now() >= deadline) {
                aborted = true;
                break;
            }
        }

        if (aborted || !finished) [task cancel];

        // A cancelled task still delivers didCompleteWithError. Wait for it so
        // the delegate is not released while Foundation may call into it.
        if (aborted || !finished) {
            std::unique_lock<std::mutex> lock(delegate->mutex);
            delegate->condition.wait_for(lock, std::chrono::seconds(2),
                                         [delegate] { return delegate->finished; });
        }

        {
            std::lock_guard<std::mutex> lock(delegate->mutex);
            status = delegate->status;
            failure = delegate->failureText;
        }

        resultOut->status = status;
        if (aborted) {
            resultOut->status = 0;
            resultOut->error = copy_error("cancelled");
        } else if (failure.length()) {
            resultOut->status = 0;
            resultOut->error = copy_error(failure.c_str());
        } else if (status < 200 || status >= 300) {
            resultOut->error = copy_error(
                ("HTTP " + std::to_string(status)).c_str());
        }

        [session finishTasksAndInvalidate];
        [delegate release];
    }
    return 0;
}

void dcad_http_free_result(DcadHttpResult* result) {
    if (result == nullptr) return;
    std::free(result->error);
    result->error = nullptr;
    result->status = 0;
}

} // extern "C"
