// Bridging header: finds the DNS server(s) iOS got from DHCP, via libresolv (linked with -lresolv).
#include <resolv.h>
#include <arpa/inet.h>
#include <string.h>

/// Writes a comma-separated list of resolver addresses into `out`. Returns how many were found (-1 on error).
static inline int wfs_dns_servers(char *out, int outlen) {
    struct __res_state st;
    memset(&st, 0, sizeof(st));
    if (outlen <= 0) return -1;
    out[0] = 0;
    if (res_ninit(&st) != 0) return -1;
    union res_sockaddr_union addrs[8];
    int n = res_getservers(&st, addrs, 8);
    int count = 0;
    for (int i = 0; i < n; i++) {
        char buf[INET6_ADDRSTRLEN];
        memset(buf, 0, sizeof(buf));
        if (addrs[i].sin.sin_family == AF_INET) {
            inet_ntop(AF_INET, &addrs[i].sin.sin_addr, buf, sizeof(buf));
        } else if (addrs[i].sin6.sin6_family == AF_INET6) {
            inet_ntop(AF_INET6, &addrs[i].sin6.sin6_addr, buf, sizeof(buf));
        } else {
            continue;
        }
        if ((int)(strlen(out) + strlen(buf) + 2) >= outlen) break;
        if (count++ > 0) strcat(out, ",");
        strcat(out, buf);
    }
    res_ndestroy(&st);
    return count;
}
