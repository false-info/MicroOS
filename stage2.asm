bits 16
org 0x8000

CODE32 equ 0x08
DATA32 equ 0x10
CODE64 equ 0x18
DATA64 equ 0x20
FONT8X8_ADDR equ 0x7000
FB_INFO      equ 0x7900


start:
    cli

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    call copy_bios_font_8x8
    call set_vbe_1024x768x32

    call enable_a20

    lgdt [gdt_descriptor]

    ; enter protected mode
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE32:protected_start


copy_bios_font_8x8:
    ; Copy BIOS 8x8 font to 0000:7000.
    ; Kernel will use this to draw text in graphics mode.

    push ax
    push bx
    push cx
    push si
    push di
    push ds
    push es
    push bp

    mov ax, 0x1130
    mov bh, 0x03
    int 0x10

    push es
    pop ds
    mov si, bp

    xor ax, ax
    mov es, ax
    mov di, FONT8X8_ADDR

    mov cx, 2048
    cld
    rep movsb

    pop bp
    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret


set_vbe_1024x768x32:
    mov cx, 0x144
    call try_vbe32_mode
    cmp al, 1
    je .done

.fail:
    mov byte [FB_INFO+0], 'N'
    mov byte [FB_INFO+1], 'O'
    mov byte [FB_INFO+2], 'F'
    mov byte [FB_INFO+3], 'B'

    mov ax, 0x0003
    int 0x10

.done:
    ret


try_vbe32_mode:
    ; input:
    ;   CX = VBE mode
    ; output:
    ;   AL = 1 success, 0 fail

    mov [FB_INFO+16], cx

    push bx
    push cx
    push di
    push es

    xor ax, ax
    mov es, ax
    mov di, vbe_mode_info

    ; get mode info
    mov ax, 0x4F01
    mov cx, [FB_INFO+16]
    int 0x10

    cmp ax, 0x004F
    jne .fail

    cmp word [vbe_mode_info + 0x12], 1024
    jne .fail

    cmp word [vbe_mode_info + 0x14], 768
    jne .fail

    cmp byte [vbe_mode_info + 0x19], 32
    jne .fail

    ; set same mode with linear framebuffer bit
    mov ax, 0x4F02
    mov bx, [FB_INFO+16]
    or bx, 0x4000
    int 0x10

    cmp ax, 0x004F
    jne .fail

    mov byte [FB_INFO+0], 'G'
    mov byte [FB_INFO+1], 'F'
    mov byte [FB_INFO+2], 'X'
    mov byte [FB_INFO+3], '!'

    mov ax, [vbe_mode_info + 0x12]
    mov [FB_INFO+4], ax

    mov ax, [vbe_mode_info + 0x14]
    mov [FB_INFO+6], ax

    mov ax, [vbe_mode_info + 0x10]
    mov [FB_INFO+8], ax

    mov al, [vbe_mode_info + 0x19]
    mov [FB_INFO+10], al

    mov eax, [vbe_mode_info + 0x28]
    mov [FB_INFO+12], eax

    mov al, 1
    jmp .done

.fail:
    xor al, al

.done:
    pop es
    pop di
    pop cx
    pop bx
    ret


align 16
vbe_mode_info times 256 db 0

enable_a20:
    in al, 0x92
    or al, 00000010b
    out 0x92, al
    ret

bits 32

protected_start:
    mov ax, DATA32
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    mov esp, 0x90000

    call setup_page_tables
    call enable_long_mode

    ; enable paging
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax

    jmp CODE64:long_mode_start

setup_page_tables:
    ; Identity-map first 4GB using 2MB pages.
    ; This lets the kernel write to the high VBE framebuffer.

    ; PML4  = 0x1000
    ; PDPT  = 0x2000
    ; PD0   = 0x3000
    ; PD1   = 0x4000
    ; PD2   = 0x5000
    ; PD3   = 0x6000

    ; clear 0x1000 - 0x6FFF
    mov edi, 0x1000
    xor eax, eax
    mov ecx, 6144
    rep stosd

    ; PML4[0] -> PDPT
    mov dword [0x1000], 0x2003
    mov dword [0x1004], 0

    ; PDPT[0..3] -> four page directories
    mov dword [0x2000], 0x3003
    mov dword [0x2004], 0

    mov dword [0x2008], 0x4003
    mov dword [0x200C], 0

    mov dword [0x2010], 0x5003
    mov dword [0x2014], 0

    mov dword [0x2018], 0x6003
    mov dword [0x201C], 0

    ; fill 2048 entries
    ; 2048 * 2MB = 4GB
    mov edi, 0x3000
    xor ebx, ebx
    mov ecx, 2048

.map_loop:
    mov eax, ebx
    or eax, 0x83          ; present | writable | 2MB page
    mov [edi], eax
    mov dword [edi+4], 0

    add ebx, 0x200000
    add edi, 8
    loop .map_loop

    ; load PML4
    mov eax, 0x1000
    mov cr3, eax

    ; enable PAE
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ret

enable_long_mode:
    ; set EFER.LME bit
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr
    ret

bits 64

long_mode_start:
    mov ax, DATA64
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    mov rsp, 0x90000

    call kernel_start

.hang:
    hlt
    jmp .hang

; -------------------------
; GDT
; -------------------------

gdt_start:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
    dq 0x00209A0000000000
    dq 0x0000920000000000
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

%include "kernel64.asm"
