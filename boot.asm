bits 16
org 0x7C00

STAGE2_OFFSET  equ 0x8000
STAGE2_SECTORS equ 96

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [boot_drive], dl

    mov si, boot_msg
    call print_string

    ; BIOS extended disk read:
    ; load STAGE2_SECTORS from LBA 1 into 0000:8000
    mov byte [dap], 0x10
    mov byte [dap+1], 0
    mov word [dap+2], STAGE2_SECTORS
    mov word [dap+4], STAGE2_OFFSET
    mov word [dap+6], 0x0000
    mov dword [dap+8], 1
    mov dword [dap+12], 0

    mov ah, 0x42
    mov dl, [boot_drive]
    mov si, dap
    int 0x13
    jc disk_error

    jmp 0x0000:STAGE2_OFFSET

disk_error:
    mov si, disk_msg
    call print_string

hang:
    cli
    hlt
    jmp hang

print_string:
    lodsb
    cmp al, 0
    je .done

    mov ah, 0x0E
    int 0x10
    jmp print_string

.done:
    ret

boot_drive db 0

boot_msg db "Loading MicroOS...",13,10,0
disk_msg db "Disk read failed.",13,10,0

dap times 16 db 0

times 510-($-$$) db 0
dw 0xAA55
