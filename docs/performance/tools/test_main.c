#include <stdio.h>
#include <stdint.h>
#include <string.h>

extern int prepoll_test(void* server);

typedef struct { uint64_t fd; uint16_t events; uint16_t revents; uint16_t pad; } pollfd_t;

/* fake CExtendedSocket: vtable at +0, GetPacketsToSend() returns &queue (fake at +0x40) */
typedef struct {
    void* vtable;          /* +0x00 */
    void* pad[7];
    void* queue_begin;     /* +0x40 */
    void* queue_end;       /* +0x48 */
    void* queue_cap;       /* +0x50 */
    uint64_t fd;           /* +0x58 (test-only fd marker) */
} fake_socket_t;

/* fake CTCPServer: m_Clients +0x40/+0x48, m_fds +0x68/+0x70 */
typedef struct {
    uint8_t pad0[0x40];
    void**  clients_begin;  /* +0x40 */
    void**  clients_end;    /* +0x48 */
    uint8_t pad1[0x18];
    pollfd_t* fds_begin;    /* +0x68 */
    pollfd_t* fds_end;      /* +0x70 */
} fake_server_t;

extern void* mock_get_queue(fake_socket_t* s);

static int failures = 0;
static void check(const char* what, int got, int want) {
    if (got != want) { printf("  FAIL %-46s got %#x want %#x\n", what, got, want); failures++; }
    else             printf("  ok   %-46s %#x\n", what, got);
}

int main(void)
{
    setbuf(stdout, NULL);
    /* build a fake vtable with slot 0xc0 = mock_get_queue */
    static void* vt[0x20];
    for (int i = 0; i < 0x20; i++) vt[i] = (void*)mock_get_queue;

    fake_socket_t s1 = {0}, s2 = {0}, s3 = {0};
    s1.vtable = vt; s1.fd = 100;
    s2.vtable = vt; s2.fd = 101;
    s3.vtable = vt; s3.fd = 102;

    void* clients[3] = { &s1, &s2, &s3 };
    pollfd_t fds[4];   /* [0] = listening socket, [1..3] = clients */
    memset(fds, 0xAB, sizeof(fds));   /* garbage, to prove it is overwritten */
    fds[0].fd = 9;                    /* listen socket */
    fds[1].fd = 100; fds[2].fd = 101; fds[3].fd = 102;

    fake_server_t srv; memset(&srv, 0, sizeof(srv));
    srv.clients_begin = clients; srv.clients_end = clients + 3;
    srv.fds_begin = fds; srv.fds_end = fds + 4;

    printf("case 1: nothing pending -> all client fds read-only\n");
    s1.queue_begin = s1.queue_end = NULL;
    s2.queue_begin = s2.queue_end = NULL;
    s3.queue_begin = s3.queue_end = NULL;
    int t = prepoll_test(&srv);
    check("timeout (ms)", t, 1);
    check("listen socket untouched (still 0xABAB)", fds[0].events, 0xABAB);
    check("fd 100 events", fds[1].events, 0x100); check("fd 100 revents", fds[1].revents, 0);
    check("fd 101 events", fds[2].events, 0x100); check("fd 101 revents", fds[2].revents, 0);
    check("fd 102 events", fds[3].events, 0x100); check("fd 102 revents", fds[3].revents, 0);

    printf("case 2: client 2 has a queued packet -> writable mask for it only\n");
    s2.queue_begin = (void*)0x1234; s2.queue_end = (void*)0x1238;
    t = prepoll_test(&srv);
    check("timeout (ms)", t, 1);
    check("fd 100 events (empty queue)", fds[1].events, 0x100);
    check("fd 101 events (packet queued)", fds[2].events, 0x110);
    check("fd 101 revents cleared", fds[2].revents, 0);
    check("fd 102 events (empty queue)", fds[3].events, 0x100);

    printf("case 3: first client has a queue -> early exit + correct masks\n");
    s1.queue_begin = (void*)0x10; s1.queue_end = (void*)0x18;
    s2.queue_begin = s2.queue_end = NULL;
    t = prepoll_test(&srv);
    check("timeout (ms)", t, 1);
    check("fd 100 events (packet queued)", fds[1].events, 0x110);
    check("fd 101 events (empty queue)", fds[2].events, 0x100);
    check("fd 102 events (empty queue)", fds[3].events, 0x100);

    printf("case 4: no clients at all (idle server)\n");
    fake_server_t empty; memset(&empty, 0, sizeof(empty));
    empty.fds_begin = fds; empty.fds_end = fds + 1;
    t = prepoll_test(&empty);
    check("timeout (ms)", t, 1);
    check("listen socket untouched (still 0xABAB)", fds[0].events, 0xABAB);

    printf("case 5: client socket not found in m_Clients -> read-only (no spin)\n");
    fds[3].fd = 999;   /* no client with this fd */
    s1.queue_begin = (void*)0x10; s1.queue_end = (void*)0x18;
    t = prepoll_test(&srv);
    check("fd 102 events (unknown socket)", fds[3].events, 0x100);

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL TESTS PASSED", failures, failures==1?"":"s");
    return failures ? 1 : 0;
}
