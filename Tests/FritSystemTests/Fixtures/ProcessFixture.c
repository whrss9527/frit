// 在独立 C 进程内 fork/setsid，避免测试在 Swift 多线程进程内 fork 后执行运行时。
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static pid_t child = 0;
static void record(const char *root, const char *name) {
    char path[4096], temporary[4096];
    snprintf(path, sizeof(path), "%s/%s", root, name);
    snprintf(temporary, sizeof(temporary), "%s/%s.tmp", root, name);
    FILE *f = fopen(temporary, "w");
    if (!f) _exit(90);
    fprintf(f, "%d %d\n", (int)getpid(), (int)getpgrp());
    fclose(f);
    if (rename(temporary, path)) _exit(96);
}
static void terminate(int signal_number) {
    (void)signal_number;
    if (child > 0) {
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    _exit(0);
}
static void heartbeat(const char *root, unsigned long value) {
    char path[4096], temporary[4096];
    snprintf(path, sizeof(path), "%s/heartbeat", root);
    snprintf(temporary, sizeof(temporary), "%s/heartbeat.tmp", root);
    FILE *f = fopen(temporary, "w");
    if (!f) _exit(97);
    fprintf(f, "%lu", value); fclose(f);
    if (rename(temporary, path)) _exit(98);
}
static void write_all(int fd, const char *p, size_t n) {
    while (n) {
        ssize_t r = write(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) _exit(91);
        p += r; n -= (size_t)r;
    }
}
int main(int argc, char **argv) {
    if (argc < 3) return 92;
    const char *mode = argv[1], *root = argv[2];
    // 模拟原生 runner 上的冷启动；生命周期测试先确认就绪，再验证后代清理。
    if (argc > 3 && !strcmp(argv[3], "delayed-start")) {
        struct timespec delay = {0, 250000000};
        while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
    }
    if (!strcmp(mode, "race")) {
        record(root, "parent.pid");
        struct timespec delay = {0, 20000000};
        nanosleep(&delay, NULL);
        write_all(STDOUT_FILENO, "done", 4);
        return 0;
    }
    if (!strcmp(mode, "invalid-exact") || !strcmp(mode, "invalid-small")) {
        char block[65536]; memset(block, 0xff, sizeof(block));
        int count = !strcmp(mode, "invalid-exact") ? 128 : 48;
        for (int i = 0; i < count; i++) write_all(STDOUT_FILENO, block, sizeof(block));
        return 7;
    }
    if (!strcmp(mode, "large") || !strcmp(mode, "invalid")) {
        char block[65535];
        // 每块为完整 UTF-8，读取和 8 MiB 裁剪仍会切在字符中间。
        for (size_t i = 0; i < sizeof(block); i += 3) memcpy(block + i, "中", 3);
        if (!strcmp(mode, "invalid")) memset(block, 0xff, sizeof(block));
        const char *stream = argc > 3 ? argv[3] : "both";
        for (int i = 0; i < 160; i++) {
            int fd = !strcmp(stream, "out") ? STDOUT_FILENO : !strcmp(stream, "err") ? STDERR_FILENO : i % 2 ? STDERR_FILENO : STDOUT_FILENO;
            write_all(fd, block, sizeof(block));
        }
        write_all(STDOUT_FILENO, "stdout-tail\n", 12);
        write_all(STDERR_FILENO, "stderr-tail\n", 12);
        return 7;
    }
    if (!strcmp(mode, "small")) {
        for (int i = 0; i < 16; i++) {
            write_all(STDOUT_FILENO, "stdout 中文\n", strlen("stdout 中文\n"));
            write_all(STDERR_FILENO, "stderr 中文\n", strlen("stderr 中文\n"));
        }
        return 7;
    }
    signal(SIGTERM, SIG_IGN);
    if (!strcmp(mode, "owned") || !strcmp(mode, "owned-exit") || !strcmp(mode, "escape-out") || !strcmp(mode, "escape-err")) {
        int handshake[2];
        if (pipe(handshake)) return 93;
        child = fork();
        if (child < 0) return 94;
        if (!child) {
            close(handshake[0]);
            if (strncmp(mode, "escape-", 7) == 0) {
                if (setsid() < 0) _exit(95);
                close(!strcmp(mode, "escape-out") ? STDERR_FILENO : STDOUT_FILENO);
            }
            record(root, "child.pid");
            write_all(handshake[1], "!", 1);
            close(handshake[1]);
            if (strncmp(mode, "escape-", 7) == 0 || !strcmp(mode, "owned-exit")) {
                unsigned long count = 0;
                struct timespec delay = {0, 20000000};
                while (1) { heartbeat(root, ++count); nanosleep(&delay, NULL); }
            }
            while (1) pause();
        }
        close(handshake[1]);
        char ready;
        while (read(handshake[0], &ready, 1) < 0 && errno == EINTR) {}
        close(handshake[0]);
        if (!strcmp(mode, "owned")) signal(SIGTERM, terminate);
        record(root, "parent.pid");
        if (!strcmp(mode, "owned-exit")) record(root, "parent.exiting");
        if (strncmp(mode, "escape-", 7) == 0 || !strcmp(mode, "owned-exit")) return 0;
    } else {
        record(root, "parent.pid");
    }
    if (!strcmp(mode, "flood")) {
        char block[65536]; memset(block, 'x', sizeof(block));
        while (1) {
            write_all(STDOUT_FILENO, block, sizeof(block));
            write_all(STDERR_FILENO, block, sizeof(block));
        }
    }
    while (1) pause();
}
