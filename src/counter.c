#include <arpa/inet.h>
#include <netdb.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#define BUF 512

static int to_int(const char *s) { return (int)strtol(s, NULL, 10); }

static void die(const char *msg)
{
    perror(msg);
    exit(1);
}

static int bind_udp(const char *port)
{
    int sock;
    int yes = 1;
    int no = 0;
    struct sockaddr_in addr;

    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0)
        die("socket");

    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)to_int(port));

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        die("bind");

    return sock;
}

static void resolve_udp(const char *host, const char *port, struct sockaddr_storage *addr,
                        socklen_t *addr_len)
{
    struct addrinfo hints;
    struct addrinfo *res;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;

    if (getaddrinfo(host, port, &hints, &res) != 0)
    {
        fprintf(stderr, "could not resolve %s:%s\n", host, port);
        exit(1);
    }

    memcpy(addr, res->ai_addr, res->ai_addrlen);
    *addr_len = (socklen_t)res->ai_addrlen;
    freeaddrinfo(res);
}

static int send_udp(const char *host, const char *port, const char *msg)
{
    int sock;
    struct sockaddr_storage addr;
    socklen_t addr_len;

    resolve_udp(host, port, &addr, &addr_len);
    sock = socket(addr.ss_family, SOCK_DGRAM, 0);
    if (sock < 0)
        die("socket");

    if (sendto(sock, msg, strlen(msg), 0, (struct sockaddr *)&addr, addr_len) < 0)
    {
        close(sock);
        return -1;
    }

    close(sock);
    return 0;
}

static int request_udp(const char *host, const char *port, const char *msg, char *reply,
                       int timeout_ms)
{
    int sock;
    fd_set reads;
    struct timeval timeout;
    struct sockaddr_storage addr;
    socklen_t addr_len;
    ssize_t n;

    resolve_udp(host, port, &addr, &addr_len);
    sock = socket(addr.ss_family, SOCK_DGRAM, 0);
    if (sock < 0)
        die("socket");

    if (sendto(sock, msg, strlen(msg), 0, (struct sockaddr *)&addr, addr_len) < 0)
    {
        close(sock);
        return -1;
    }

    FD_ZERO(&reads);
    FD_SET(sock, &reads);
    timeout.tv_sec = timeout_ms / 1000;
    timeout.tv_usec = (timeout_ms % 1000) * 1000;

    if (select(sock + 1, &reads, NULL, NULL, &timeout) <= 0)
    {
        close(sock);
        return -1;
    }

    n = recvfrom(sock, reply, BUF - 1, 0, NULL, NULL);
    if (n < 0)
    {
        close(sock);
        return -1;
    }

    reply[n] = '\0';
    close(sock);
    return 0;
}

static void send_reply(int sock, struct sockaddr *peer, socklen_t peer_len, const char *fmt, ...)
{
    char msg[BUF];
    va_list args;

    va_start(args, fmt);
    vsnprintf(msg, sizeof(msg), fmt, args);
    va_end(args);

    sendto(sock, msg, strlen(msg), 0, peer, peer_len);
}

static int node(int argc, char **argv)
{
    const char *name;
    const char *port;
    int counter;
    int sock;

    if (argc != 5)
    {
        fprintf(stderr, "usage: %s node NAME PORT INITIAL\n", argv[0]);
        return 1;
    }

    name = argv[2];
    port = argv[3];
    counter = to_int(argv[4]);
    sock = bind_udp(port);

    printf("node %s listening on udp/%s with counter=%d\n", name, port, counter);
    fflush(stdout);

    while (1)
    {
        char buf[BUF];
        char txid[128], host[256], peer_port[32], from[64];
        int amount;
        ssize_t n;
        struct sockaddr_storage peer;
        socklen_t peer_len = sizeof(peer);

        n = recvfrom(sock, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&peer, &peer_len);
        if (n < 0)
            continue;
        buf[n] = '\0';

        if (strncmp(buf, "STATE", 5) == 0)
        {
            send_reply(sock, (struct sockaddr *)&peer, peer_len, "STATE %s counter=%d", name,
                       counter);
        }
        else if (sscanf(buf, "CREDIT %127s %63s %d", txid, from, &amount) == 3)
        {
            counter += amount;
            printf("%s CREDIT tx=%s from=%s amount=%d counter=%d\n", name, txid, from, amount,
                   counter);
            fflush(stdout);
            send_reply(sock, (struct sockaddr *)&peer, peer_len, "OK CREDIT %s", txid);
        }
        else if (sscanf(buf, "TRANSFER %127s %255s %31s %d", txid, host, peer_port, &amount) == 4)
        {
            char credit[BUF];

            counter -= amount;
            printf("%s DEBIT tx=%s to=%s:%s amount=%d counter=%d\n", name, txid, host, peer_port,
                   amount, counter);
            fflush(stdout);

            snprintf(credit, sizeof(credit), "CREDIT %s %s %d", txid, name, amount);
            send_udp(host, peer_port, credit);

            send_reply(sock, (struct sockaddr *)&peer, peer_len, "OK TRANSFER %s", txid);
        }
        else if (sscanf(buf, "RESET %d", &amount) == 1)
        {
            counter = amount;
            printf("%s RESET amount=%d counter=%d\n", name, amount, counter);
            fflush(stdout);
            send_reply(sock, (struct sockaddr *)&peer, peer_len, "OK RESET");
        }
        else
        {
            send_reply(sock, (struct sockaddr *)&peer, peer_len, "ERR");
        }
    }
}

static int state(int argc, char **argv)
{
    char reply[BUF];

    if (argc != 4)
    {
        fprintf(stderr, "usage: %s state HOST PORT\n", argv[0]);
        return 1;
    }

    if (request_udp(argv[2], argv[3], "STATE", reply, 1000) != 0)
        return 1;

    puts(reply);
    return 0;
}

// transfer AMOUNT from A to B, where A and B are identified by HOST:PORT
static int transfer(int argc, char **argv)
{
    char msg[BUF];
    char reply[BUF];

    if (argc != 7)
    {
        fprintf(stderr, "usage: %s transfer FROM_HOST FROM_PORT TO_HOST TO_PORT AMOUNT\n", argv[0]);
        return 1;
    }

    // ADDED PLACEHOLDER "tx123" AS THE FIRST PARAMETER AFTER TRANSFER
    // fix later
    snprintf(msg, sizeof(msg), "TRANSFER tx123 %s %s %d", argv[4], argv[5], to_int(argv[6]));

    if (request_udp(argv[2], argv[3], msg, reply, 1000) != 0)
        return 1;

    puts(reply);
    return strncmp(reply, "OK", 2) == 0 ? 0 : 1;
}

static int reset_counter(int argc, char **argv)
{
    char msg[BUF];
    char reply[BUF];

    if (argc != 5)
    {
        fprintf(stderr, "usage: %s reset HOST PORT AMOUNT\n", argv[0]);
        return 1;
    }

    snprintf(msg, sizeof(msg), "RESET %d", to_int(argv[4]));

    if (request_udp(argv[2], argv[3], msg, reply, 1000) != 0)
        return 1;

    puts(reply);
    return strncmp(reply, "OK", 2) == 0 ? 0 : 1;
}

static int get_counter(const char *host, const char *port, int *value)
{
    char reply[BUF];
    char *p;

    if (request_udp(host, port, "STATE", reply, 500) != 0)
        return -1;

    p = strstr(reply, "counter=");
    if (!p)
        return -1;

    *value = to_int(p + strlen("counter="));
    return 0;
}

// sum of the counters
static int sum(int argc, char **argv)
{
    int expected;
    int timeout_ms;
    int stable_needed;
    int elapsed = 0;
    int stable = 0;

    if (argc != 11)
    {
        fprintf(stderr,
                "usage: %s sum A_HOST A_PORT B_HOST B_PORT C_HOST C_PORT EXPECTED TIMEOUT_MS "
                "STABLE_POLLS\n",
                argv[0]);
        return 1;
    }

    expected = to_int(argv[8]);
    timeout_ms = to_int(argv[9]);
    stable_needed = to_int(argv[10]);

    while (elapsed <= timeout_ms)
    {
        int a = 0, b = 0, c = 0;
        int ok_a = get_counter(argv[2], argv[3], &a);
        int ok_b = get_counter(argv[4], argv[5], &b);
        int ok_c = get_counter(argv[6], argv[7], &c);

        if (ok_a == 0 && ok_b == 0 && ok_c == 0)
        {
            int total = a + b + c;
            printf("SUM a=%d b=%d c=%d total=%d expected=%d %s\n", a, b, c, total, expected,
                   (total == expected) ? "PASS" : "FAIL");

            stable = (total == expected) ? stable + 1 : 0;
            if (stable >= stable_needed)
                return 0;
        }
        else
        {
            printf("SUM waiting for nodes: a=%d b=%d c=%d\n", ok_a, ok_b, ok_c);
            stable = 0;
        }

        usleep(100000);
        elapsed += 100;
    }

    return 1;
}

int main(int argc, char **argv)
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s node|state|transfer|reset|sum ...\n", argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "node") == 0)
        return node(argc, argv);
    if (strcmp(argv[1], "state") == 0)
        return state(argc, argv);
    if (strcmp(argv[1], "transfer") == 0)
        return transfer(argc, argv);
    if (strcmp(argv[1], "reset") == 0)
        return reset_counter(argc, argv);
    if (strcmp(argv[1], "sum") == 0)
        return sum(argc, argv);

    fprintf(stderr, "unknown command: %s\n", argv[1]);
    return 1;
}
