#ifndef LOGGER_H
#define LOGGER_H

#include <stdio.h>
#include <stdarg.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline void Logger_Timestamp(char* buffer, size_t size) {
    time_t now = time(NULL);
    struct tm tm_now;
#if defined(_WIN32) || defined(_WIN64)
    localtime_s(&tm_now, &now);
#else
    localtime_r(&now, &tm_now);
#endif
    strftime(buffer, size, "%Y-%m-%d %H:%M:%S", &tm_now);
}

static inline void Logger_Error(const char* fmt, ...) {
    char ts[32]; Logger_Timestamp(ts, sizeof(ts));
    fprintf(stderr, "[ERROR] [%s] ", ts);
    va_list args; va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
}

static inline void Logger_Debug(const char* fmt, ...) {
    char ts[32]; Logger_Timestamp(ts, sizeof(ts));
    fprintf(stdout, "[DEBUG] [%s] ", ts);
    va_list args; va_start(args, fmt);
    vfprintf(stdout, fmt, args);
    va_end(args);
    fprintf(stdout, "\n");
}

#ifdef __cplusplus
}
#endif

#endif // LOGGER_H
