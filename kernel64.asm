bits 64
default abs

; -------------------------
; VBE graphics terminal
; 1024x768x32
; -------------------------

VGA_BASE     equ 0xB8000      ; legacy fallback / old mvim code
FONT8X8_ADDR equ 0x7000
FB_INFO      equ 0x7900

SCREEN_COLS equ 128           ; 1024 / 8
SCREEN_ROWS equ 96            ; 768 / 8

HEADER_ROWS equ 2

TERM_START  equ SCREEN_COLS * HEADER_ROWS
SCREEN_END  equ SCREEN_COLS * SCREEN_ROWS
LAST_ROW    equ SCREEN_COLS * (SCREEN_ROWS - 1)

ROW_BYTES   equ 160           ; legacy only

FS_MAGIC_LBA  equ 100
FS_SOURCE_LBA equ 101
FS_BACKUP_LBA equ 117
FS_PROG_LBA   equ 133

OP_HALT  equ 0
OP_PRINT equ 1
KEY_UP    equ 0x80
KEY_DOWN  equ 0x81
KEY_LEFT  equ 0x82
KEY_RIGHT equ 0x83
EDITOR_MAX      equ 8192
EDITOR_SECTORS  equ 16
MVIM_HEADER_LINES equ 4
MVIM_BODY_ROWS    equ SCREEN_ROWS - HEADER_ROWS - MVIM_HEADER_LINES
MCFS_TABLE_LBA   equ 134
MCFS_ENTRY_SIZE  equ 32
MCFS_MAX_ENTRIES equ 16

MCFS_TYPE_FILE   equ 1
MCFS_TYPE_DIR    equ 2

UPDATE_START_LBA equ 1
UPDATE_SECTORS   equ 96


; -------------------------
; Kernel start
; -------------------------

kernel_start:
    call screen_init

    mov rsi, boot_ready_msg
    call print_string


main_loop:
    mov rsi, prompt
    call print_string

    mov rax, [cursor]
    mov [line_start], rax

    mov r13, input_buffer
    xor r12, r12

.read_loop:
    call get_key

    cmp al, 0x80
    jae .read_loop

    cmp al, 13
    je .enter

    cmp al, 8
    je .backspace

    cmp al, 32
    jb .read_loop

    cmp r12, 255
    jae .read_loop

    mov [r13], al
    inc r13
    inc r12

    call print_char
    jmp .read_loop


.enter:
    mov byte [r13], 0

    mov al, 10
    call print_char

    call handle_command

    jmp main_loop

.backspace:
    cmp r12, 0
    je .read_loop

    dec r13
    dec r12
    mov byte [r13], 0

    call do_backspace
    jmp .read_loop


; -------------------------
; Keyboard input
; -------------------------

get_key:
.wait:
    in al, 0x64
    test al, 1
    jz .wait

    in al, 0x60
    mov bl, al

    cmp bl, 0xE0
    je .got_extended

    cmp byte [extended_prefix], 1
    je .handle_extended

    cmp bl, 0x2A
    je .shift_down
    cmp bl, 0x36
    je .shift_down

    cmp bl, 0xAA
    je .shift_up
    cmp bl, 0xB6
    je .shift_up

    test bl, 0x80
    jnz .wait

    movzx rbx, bl

    cmp byte [altgr_down], 1
    je .use_altgr

    cmp byte [shift_down], 1
    je .use_shift

    mov al, [keymap_normal + rbx]
    cmp al, 0
    je .wait
    ret

.use_shift:
    mov al, [keymap_shift + rbx]
    cmp al, 0
    je .wait
    ret

.use_altgr:
    mov al, [keymap_altgr + rbx]
    cmp al, 0
    je .wait
    ret

.got_extended:
    mov byte [extended_prefix], 1
    jmp .wait

.handle_extended:
    mov byte [extended_prefix], 0

    cmp bl, 0x38
    je .altgr_down

    cmp bl, 0xB8
    je .altgr_up

    cmp bl, 0x48
    je .arrow_up

    cmp bl, 0x50
    je .arrow_down

    cmp bl, 0x4B
    je .arrow_left

    cmp bl, 0x4D
    je .arrow_right

    jmp .wait

.arrow_up:
    mov al, KEY_UP
    ret

.arrow_down:
    mov al, KEY_DOWN
    ret

.arrow_left:
    mov al, KEY_LEFT
    ret

.arrow_right:
    mov al, KEY_RIGHT
    ret

.shift_down:
    mov byte [shift_down], 1
    jmp .wait

.shift_up:
    mov byte [shift_down], 0
    jmp .wait

.altgr_down:
    mov byte [altgr_down], 1
    jmp .wait

.altgr_up:
    mov byte [altgr_down], 0
    jmp .wait


; -------------------------
; VBE graphics terminal driver
; 1024x768x32, 8x8 font
; -------------------------

screen_init:
    call gfx_init

    cmp byte [fb_ready], 1
    je .ok

    call text_panic_no_gfx

.hang:
    hlt
    jmp .hang

.ok:
    call gfx_clear_all
    call draw_header

    mov qword [cursor], TERM_START
    mov qword [line_start], TERM_START
    mov qword [cursor_drawn], 0xFFFFFFFFFFFFFFFF
    call update_hardware_cursor
    ret


gfx_init:
    cmp byte [FB_INFO+0], 'G'
    jne .fail
    cmp byte [FB_INFO+1], 'F'
    jne .fail
    cmp byte [FB_INFO+2], 'X'
    jne .fail
    cmp byte [FB_INFO+3], '!'
    jne .fail

    mov ax, [FB_INFO+4]
    mov [fb_width], ax

    mov ax, [FB_INFO+6]
    mov [fb_height], ax

    mov ax, [FB_INFO+8]
    mov [fb_pitch], ax

    mov al, [FB_INFO+10]
    mov [fb_bpp], al

    mov eax, [FB_INFO+12]
    mov [fb_addr], rax

    mov byte [fb_ready], 1
    ret

.fail:
    mov byte [fb_ready], 0
    ret


text_panic_no_gfx:
    ; Minimal old text-mode panic if VBE failed.

    mov rdi, VGA_BASE
    mov rcx, 80 * 25
    mov ax, 0x4F20

.clear:
    mov [rdi], ax
    add rdi, 2
    loop .clear

    mov rdi, VGA_BASE
    mov rsi, panic_no_gfx_msg

.print:
    lodsb
    cmp al, 0
    je .done

    mov ah, 0x4F
    mov [rdi], ax
    add rdi, 2
    jmp .print

.done:
    ret


clear_screen:
    call gfx_clear_all
    call draw_header

    mov qword [cursor], TERM_START
    mov qword [line_start], TERM_START
    mov qword [cursor_drawn], 0xFFFFFFFFFFFFFFFF
    call update_hardware_cursor
    ret


clear_terminal:
    push rdi
    push rcx
    push rax
    push rbx

    mov rdi, [fb_addr]

    movzx rax, word [fb_pitch]
    mov rbx, HEADER_ROWS * 8
    mul rbx
    add rdi, rax

    movzx rax, word [fb_pitch]
    mov rbx, (SCREEN_ROWS - HEADER_ROWS) * 8
    mul rbx
    mov rcx, rax

    mov al, 1
    rep stosb

    mov qword [cursor], TERM_START
    mov qword [line_start], TERM_START
    mov qword [cursor_drawn], 0xFFFFFFFFFFFFFFFF
    call update_hardware_cursor

    pop rbx
    pop rax
    pop rcx
    pop rdi
    ret


gfx_clear_all:
    push rdi
    push rcx
    push rax
    push rbx

    mov rdi, [fb_addr]

    movzx rax, word [fb_pitch]
    movzx rbx, word [fb_height]
    mul rbx
    mov rcx, rax

    mov al, 1               ; dark blue-ish background
    rep stosb

    pop rbx
    pop rax
    pop rcx
    pop rdi
    ret


print_string:
    lodsb
    cmp al, 0
    je .done

    call print_char
    jmp print_string

.done:
    ret


print_char:
    cmp al, 10
    je .newline

    call gfx_erase_cursor

    push rax
    push rbx

    mov rbx, [cursor]
    call gfx_draw_cell

    inc qword [cursor]

    call scroll_if_needed
    call update_hardware_cursor

    pop rbx
    pop rax
    ret

.newline:
    call newline
    ret


newline:
    call gfx_erase_cursor

    push rax
    push rdx
    push rcx

    mov rax, [cursor]
    xor rdx, rdx
    mov rcx, SCREEN_COLS
    div rcx

    inc rax
    imul rax, SCREEN_COLS
    mov [cursor], rax

    call scroll_if_needed
    call update_hardware_cursor

    pop rcx
    pop rdx
    pop rax
    ret


scroll_if_needed:
    push rax
    push rcx
    push rsi
    push rdi
    push rbx

    mov rax, [cursor]
    cmp rax, SCREEN_END
    jb .done

    ; Scroll terminal pixel area up by 8 pixels.
    mov rsi, [fb_addr]
    mov rdi, [fb_addr]

    movzx rax, word [fb_pitch]
    mov rbx, (HEADER_ROWS + 1) * 8
    mul rbx
    add rsi, rax

    movzx rax, word [fb_pitch]
    mov rbx, HEADER_ROWS * 8
    mul rbx
    add rdi, rax

    movzx rax, word [fb_pitch]
    mov rbx, (SCREEN_ROWS - HEADER_ROWS - 1) * 8
    mul rbx
    mov rcx, rax

    cld
    rep movsb

    ; Clear last text row.
    mov rdi, [fb_addr]

    movzx rax, word [fb_pitch]
    mov rbx, (SCREEN_ROWS - 1) * 8
    mul rbx
    add rdi, rax

    movzx rcx, word [fb_pitch]
    imul rcx, 8

    mov al, 1
    rep stosb

    mov qword [cursor], LAST_ROW
    mov qword [line_start], LAST_ROW
    mov qword [cursor_drawn], 0xFFFFFFFFFFFFFFFF

.done:
    pop rbx
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret


do_backspace:
    mov rax, [cursor]
    cmp rax, [line_start]
    jbe .done

    call gfx_erase_cursor

    dec qword [cursor]

    push rax
    push rbx

    mov al, ' '
    mov rbx, [cursor]
    call gfx_draw_cell

    call update_hardware_cursor

    pop rbx
    pop rax

.done:
    ret


update_hardware_cursor:
    call gfx_draw_cursor
    ret


draw_header:
    mov qword [cursor], 0
    mov rsi, header_line1
    call print_string

    call newline

    mov rsi, header_line2
    call print_string

    ret


gfx_draw_cell:
    ; AL = character
    ; RBX = cell index

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    mov r10b, al

    ; row / col
    mov rax, rbx
    xor rdx, rdx
    mov rcx, SCREEN_COLS
    div rcx                 ; RAX = row, RDX = col

    ; pixel pointer = fb + row*8*pitch + col*8*4
    mov rdi, [fb_addr]

    mov r8, rax
    imul r8, 8

    movzx r9, word [fb_pitch]
    imul r8, r9
    add rdi, r8

    mov r9, rdx
    imul r9, 32             ; col * 8 pixels * 4 bytes
    add rdi, r9

    ; font pointer
    movzx rsi, r10b
    shl rsi, 3
    add rsi, FONT8X8_ADDR

    mov r11, 8

.row_loop:
    mov r13b, [rsi]
    mov rcx, 8

.col_loop:
    test r13b, 0x80
    jz .bg

    mov dword [rdi], 0x00FFFFFF
    jmp .next_pixel

.bg:
    mov dword [rdi], 0x00000040

.next_pixel:
    shl r13b, 1
    add rdi, 4
    loop .col_loop

    inc rsi

    movzx r12, word [fb_pitch]
    sub r12, 32
    add rdi, r12

    dec r11
    jnz .row_loop

    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


gfx_fill_cell_bg:
    ; RBX = cell index
    ; fills one 8x8 cell with background

    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov rax, rbx
    xor rdx, rdx
    mov rcx, SCREEN_COLS
    div rcx                 ; RAX=row, RDX=col

    mov rdi, [fb_addr]

    mov r8, rax
    imul r8, 8

    movzx r9, word [fb_pitch]
    imul r8, r9
    add rdi, r8

    mov r9, rdx
    imul r9, 32
    add rdi, r9

    mov r10, 8

.row_loop:
    mov rcx, 8

.col_loop:
    mov dword [rdi], 0x00000040
    add rdi, 4
    loop .col_loop

    movzx r11, word [fb_pitch]
    sub r11, 32
    add rdi, r11

    dec r10
    jnz .row_loop

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


gfx_erase_cursor:
    cmp qword [cursor_drawn], 0xFFFFFFFFFFFFFFFF
    je .done

    push rbx

    mov rbx, [cursor_drawn]
    call gfx_fill_cell_bg

    mov qword [cursor_drawn], 0xFFFFFFFFFFFFFFFF

    pop rbx

.done:
    ret


gfx_draw_cursor:
    call gfx_erase_cursor

    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9

    mov rbx, [cursor]
    mov [cursor_drawn], rbx

    ; calculate cell pixel pointer
    mov rax, rbx
    xor rdx, rdx
    mov rcx, SCREEN_COLS
    div rcx

    mov rdi, [fb_addr]

    mov r8, rax
    imul r8, 8

    movzx r9, word [fb_pitch]
    imul r8, r9
    add rdi, r8

    mov r9, rdx
    imul r9, 32
    add rdi, r9

    ; draw cursor as bottom 2 pixel rows
    movzx rax, word [fb_pitch]
    imul rax, 6
    add rdi, rax

    mov rcx, 16             ; 2 rows * 8 pixels

.loop:
    mov dword [rdi], 0x00FFFF00
    add rdi, 4

    ; after 8 pixels, jump to next scanline
    cmp rcx, 9
    jne .no_jump

    movzx rax, word [fb_pitch]
    sub rax, 32
    add rdi, rax

.no_jump:
    loop .loop

    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

split_command:
    ; input_buffer -> command_name + command_arg
    ; Supports:
    ;   ls
    ;   mkdir source
    ;   cd source

    push rsi
    push rdi
    push rcx
    push rax

    ; clear command_name
    mov rdi, command_name
    mov rcx, 32
    xor al, al
.clear_name:
    mov [rdi], al
    inc rdi
    loop .clear_name

    ; clear command_arg
    mov rdi, command_arg
    mov rcx, 64
    xor al, al
.clear_arg:
    mov [rdi], al
    inc rdi
    loop .clear_arg

    mov rsi, input_buffer
    mov rdi, command_name
    mov rcx, 31

.copy_name:
    mov al, [rsi]
    cmp al, 0
    je .done
    cmp al, ' '
    je .skip_spaces

    cmp rcx, 0
    je .skip_until_space

    mov [rdi], al
    inc rdi
    dec rcx
    inc rsi
    jmp .copy_name

.skip_until_space:
    mov al, [rsi]
    cmp al, 0
    je .done
    cmp al, ' '
    je .skip_spaces
    inc rsi
    jmp .skip_until_space

.skip_spaces:
    cmp byte [rsi], ' '
    jne .copy_arg
    inc rsi
    jmp .skip_spaces

.copy_arg:
    mov rdi, command_arg
    mov rcx, 63

.arg_loop:
    mov al, [rsi]
    cmp al, 0
    je .done

    cmp rcx, 0
    je .done

    mov [rdi], al
    inc rdi
    inc rsi
    dec rcx
    jmp .arg_loop

.done:
    pop rax
    pop rcx
    pop rdi
    pop rsi
    ret

; -------------------------
; Command handler
; -------------------------

handle_command:
    cmp byte [input_buffer], 0
    je .done

    call split_command

    mov rsi, command_name
    mov rdi, cmd_help
    call strcmp
    cmp al, 1
    je command_help

    mov rsi, command_name
    mov rdi, cmd_ver
    call strcmp
    cmp al, 1
    je command_ver

    mov rsi, command_name
    mov rdi, cmd_clear
    call strcmp
    cmp al, 1
    je command_clear

    ; FIX: status was missing from the dispatcher
    mov rsi, command_name
    mov rdi, cmd_status
    call strcmp
    cmp al, 1
    je command_status

    mov rsi, command_name
    mov rdi, cmd_format
    call strcmp
    cmp al, 1
    je command_format

    mov rsi, command_name
    mov rdi, cmd_ls
    call strcmp
    cmp al, 1
    je command_ls

    mov rsi, command_name
    mov rdi, cmd_mvim
    call strcmp
    cmp al, 1
    je command_mvim

        mov rsi, command_name
    mov rdi, cmd_pwd
    call strcmp
    cmp al, 1
    je command_pwd

    mov rsi, command_name
    mov rdi, cmd_cd
    call strcmp
    cmp al, 1
    je command_cd

    mov rsi, command_name
    mov rdi, cmd_mkdir
    call strcmp
    cmp al, 1
    je command_mkdir

    mov rsi, command_name
    mov rdi, cmd_new
    call strcmp
    cmp al, 1
    je command_new

    mov rsi, command_name
    mov rdi, cmd_rm
    call strcmp
    cmp al, 1
    je command_rm

    mov rsi, command_name
    mov rdi, cmd_show
    call strcmp
    cmp al, 1
    je command_show

    mov rsi, command_name
    mov rdi, cmd_save
    call strcmp
    cmp al, 1
    je command_save

    mov rsi, command_name
    mov rdi, cmd_load
    call strcmp
    cmp al, 1
    je command_load

    mov rsi, command_name
    mov rdi, cmd_backup
    call strcmp
    cmp al, 1
    je command_backup

    mov rsi, command_name
    mov rdi, cmd_build
    call strcmp
    cmp al, 1
    je command_build

    mov rsi, command_name
    mov rdi, cmd_run
    call strcmp
    cmp al, 1
    je command_run

    mov rsi, command_name
    mov rdi, cmd_update
    call strcmp
    cmp al, 1
    je command_update

    mov rsi, command_name
    mov rdi, cmd_reboot
    call strcmp
    cmp al, 1
    je command_reboot

    mov rsi, command_name
    mov rdi, cmd_snap
    call strcmp
    cmp al, 1
    je command_snap

    mov rsi, unknown_msg
    call print_string

.done:
    ret


command_help:
    mov rsi, help_msg
    call print_string
    ret

command_ver:
    mov rsi, ver_msg
    call print_string
    ret

command_clear:
    call clear_terminal
    ret

command_format:
    call fs_format
    mov rsi, format_done_msg
    call print_string
    ret

command_ls:
    call mcfs_load_table

    mov rsi, mcfs_ls_header_msg
    call print_string

    xor r12, r12          ; entry index
    xor r13, r13          ; shown count
    mov rbx, disk_buffer

.loop:
    cmp r12, MCFS_MAX_ENTRIES
    jae .done

    cmp byte [rbx+0], 1
    jne .next

    mov al, [current_dir]
    cmp [rbx+2], al
    jne .next

    cmp byte [rbx+1], MCFS_TYPE_DIR
    je .show_dir

    cmp byte [rbx+1], MCFS_TYPE_FILE
    je .show_file

    jmp .next

.show_dir:
    mov rsi, mcfs_dir_tag
    call print_string
    jmp .show_name

.show_file:
    mov rsi, mcfs_file_tag
    call print_string

.show_name:
    lea rsi, [rbx+4]
    call print_string

    mov al, 10
    call print_char

    inc r13

.next:
    add rbx, MCFS_ENTRY_SIZE
    inc r12
    jmp .loop

.done:
    cmp r13, 0
    jne .ret

    mov rsi, mcfs_empty_msg
    call print_string

.ret:
    ret

command_mvim:
    call editor
    ret

command_show:
    mov rsi, show_msg
    call print_string

    cmp byte [editor_buffer], 0
    je .empty

    mov rsi, editor_buffer
    call print_string

    mov al, 10
    call print_char
    ret

.empty:
    mov rsi, empty_msg
    call print_string
    ret

command_save:
    ; backup old saved source first
    mov eax, FS_SOURCE_LBA
    mov rdi, backup_buffer
    mov rcx, EDITOR_SECTORS
    call ata_read_many

    mov eax, FS_BACKUP_LBA
    mov rsi, backup_buffer
    mov rcx, EDITOR_SECTORS
    call ata_write_many

    ; copy editor source into disk_buffer
    mov rdi, disk_buffer
    call clear_editor_sized_buffer

    mov rsi, editor_buffer
    mov rdi, disk_buffer
    call copy_string

    ; write current editor source
    mov eax, FS_SOURCE_LBA
    mov rsi, disk_buffer
    mov rcx, EDITOR_SECTORS
    call ata_write_many

    mov rsi, save_done_msg
    call print_string
    ret

command_load:
    mov rdi, disk_buffer
    call clear_editor_sized_buffer

    mov eax, FS_SOURCE_LBA
    mov rdi, disk_buffer
    mov rcx, EDITOR_SECTORS
    call ata_read_many

    mov rsi, disk_buffer
    mov rdi, editor_buffer
    call copy_string

    mov rsi, load_done_msg
    call print_string
    ret

command_backup:
    mov rdi, disk_buffer
    call clear_editor_sized_buffer

    mov eax, FS_BACKUP_LBA
    mov rdi, disk_buffer
    mov rcx, EDITOR_SECTORS
    call ata_read_many

    mov rsi, disk_buffer
    mov rdi, editor_buffer
    call copy_string

    mov rsi, backup_done_msg
    call print_string
    ret

command_build:
    call tiny_compile
    cmp al, 1
    je .ok

    mov rsi, build_fail_msg
    call print_string
    ret

.ok:
    mov rsi, build_ok_msg
    call print_string
    ret

command_run:
    call tiny_run
    ret

command_update:
    ; Real MicroOS updater v0:
    ; copies UPDATE_SECTORS sectors from update disk slave LBA 1
    ; to main boot disk master LBA 1, then reboots.
    ;
    ; Host must run QEMU with:
    ;   -drive file=os.img,format=raw,if=ide,index=0
    ;   -drive file=update.img,format=raw,if=ide,index=1

    mov rsi, update_start_msg
    call print_string

    xor r12, r12              ; sector counter

.copy_loop:
    cmp r12, UPDATE_SECTORS
    jae .done

    ; read from update.img, slave disk
    mov eax, UPDATE_START_LBA
    add rax, r12

    mov rdi, disk_buffer
    call ata_read_sector_slave

    ; write to os.img, master disk
    mov eax, UPDATE_START_LBA
    add rax, r12

    mov rsi, disk_buffer
    call ata_write_sector

    inc r12
    jmp .copy_loop

.done:
    mov rsi, update_done_reboot_msg
    call print_string

    ; reboot through keyboard controller
    mov al, 0xFE
    out 0x64, al

.hang:
    hlt
    jmp .hang

command_reboot:
    mov rsi, reboot_msg
    call print_string

    mov al, 0xFE
    out 0x64, al

.hang:
    hlt
    jmp .hang


command_status:
    mov rsi, status_header_msg
    call print_string

    ; check TinyFS magic sector
    mov eax, FS_MAGIC_LBA
    mov rdi, disk_buffer
    call ata_read_sector

    mov rsi, status_fs_msg
    call print_string

    call check_tinyfs_magic
    cmp al, 1
    je .fs_yes

    mov rsi, no_msg
    call print_string
    jmp .check_source

.fs_yes:
    mov rsi, yes_msg
    call print_string


.check_source:
    mov eax, FS_SOURCE_LBA
    mov rdi, disk_buffer
    call ata_read_sector

    mov rsi, status_source_msg
    call print_string

    call sector_has_data
    cmp al, 1
    je .source_yes

    mov rsi, no_msg
    call print_string
    jmp .check_backup

.source_yes:
    mov rsi, yes_msg
    call print_string


.check_backup:
    mov eax, FS_BACKUP_LBA
    mov rdi, disk_buffer
    call ata_read_sector

    mov rsi, status_backup_msg
    call print_string

    call sector_has_data
    cmp al, 1
    je .backup_yes

    mov rsi, no_msg
    call print_string
    jmp .check_program

.backup_yes:
    mov rsi, yes_msg
    call print_string


.check_program:
    mov eax, FS_PROG_LBA
    mov rdi, disk_buffer
    call ata_read_sector

    mov rsi, status_program_msg
    call print_string

    call sector_has_data
    cmp al, 1
    je .program_yes

    mov rsi, no_msg
    call print_string
    ret

.program_yes:
    mov rsi, yes_msg
    call print_string
    ret


check_tinyfs_magic:
    cmp byte [disk_buffer+0], 'M'
    jne .no
    cmp byte [disk_buffer+1], 'O'
    jne .no
    cmp byte [disk_buffer+2], 'S'
    jne .no
    cmp byte [disk_buffer+3], 'F'
    jne .no
    cmp byte [disk_buffer+4], 'S'
    jne .no
    cmp byte [disk_buffer+5], '1'
    jne .no

    mov al, 1
    ret

.no:
    xor al, al
    ret


sector_has_data:
    cmp byte [disk_buffer], 0
    jne .yes

    xor al, al
    ret

.yes:
    mov al, 1
    ret

command_snap:
    ; save current editor buffer into backup sectors

    mov rdi, disk_buffer
    call clear_editor_sized_buffer

    mov rsi, editor_buffer
    mov rdi, disk_buffer
    call copy_string

    mov eax, FS_BACKUP_LBA
    mov rsi, disk_buffer
    mov rcx, EDITOR_SECTORS
    call ata_write_many

    mov rsi, snap_done_msg
    call print_string
    ret


command_pwd:
    mov rsi, mcfs_pwd_prefix
    call print_string

    cmp byte [current_dir], 0
    je .root

    call mcfs_print_current_dir
    ret

.root:
    mov rsi, mcfs_root_msg
    call print_string
    ret


command_cd:
    cmp byte [command_arg], 0
    je .missing

    ; cd ..
    cmp byte [command_arg+0], '.'
    jne .find
    cmp byte [command_arg+1], '.'
    jne .find
    cmp byte [command_arg+2], 0
    jne .find

    mov byte [current_dir], 0
    mov rsi, mcfs_cd_done_msg
    call print_string
    ret

.find:
    mov al, MCFS_TYPE_DIR
    call mcfs_find_in_current
    cmp al, 1
    jne .not_found

    ; result slot index is in R12
    mov rax, r12
    inc al
    mov [current_dir], al

    mov rsi, mcfs_cd_done_msg
    call print_string
    ret

.missing:
    mov rsi, mcfs_no_arg_msg
    call print_string
    ret

.not_found:
    mov rsi, mcfs_not_found_msg
    call print_string
    ret


command_mkdir:
    cmp byte [command_arg], 0
    je .missing

    mov al, MCFS_TYPE_DIR
    call mcfs_create_entry
    cmp al, 1
    je .ok
    cmp al, 2
    je .exists

    mov rsi, mcfs_full_msg
    call print_string
    ret

.ok:
    mov rsi, mcfs_mkdir_done_msg
    call print_string
    ret

.exists:
    mov rsi, mcfs_exists_msg
    call print_string
    ret

.missing:
    mov rsi, mcfs_no_arg_msg
    call print_string
    ret


command_new:
    cmp byte [command_arg], 0
    je .missing

    mov al, MCFS_TYPE_FILE
    call mcfs_create_entry
    cmp al, 1
    je .ok
    cmp al, 2
    je .exists

    mov rsi, mcfs_full_msg
    call print_string
    ret

.ok:
    mov rsi, mcfs_new_done_msg
    call print_string
    ret

.exists:
    mov rsi, mcfs_exists_msg
    call print_string
    ret

.missing:
    mov rsi, mcfs_no_arg_msg
    call print_string
    ret


command_rm:
    cmp byte [command_arg], 0
    je .missing

    call mcfs_remove_entry
    cmp al, 1
    jne .not_found

    mov rsi, mcfs_rm_done_msg
    call print_string
    ret

.missing:
    mov rsi, mcfs_no_arg_msg
    call print_string
    ret

.not_found:
    mov rsi, mcfs_not_found_msg
    call print_string
    ret


; -------------------------
; String helpers
; -------------------------

strcmp:
    push rsi
    push rdi
    push rbx

.loop:
    mov al, [rsi]
    mov bl, [rdi]

    cmp al, bl
    jne .not_equal

    cmp al, 0
    je .equal

    inc rsi
    inc rdi
    jmp .loop

.equal:
    pop rbx
    pop rdi
    pop rsi
    mov al, 1
    ret

.not_equal:
    pop rbx
    pop rdi
    pop rsi
    xor al, al
    ret


copy_string:
.loop:
    mov al, [rsi]
    mov [rdi], al

    cmp al, 0
    je .done

    inc rsi
    inc rdi
    jmp .loop

.done:
    ret


strlen:
    push rsi
    xor rax, rax

.loop:
    cmp byte [rsi], 0
    je .done

    inc rsi
    inc rax
    jmp .loop

.done:
    pop rsi
    ret


clear_sector_buffer:
    push rdi
    push rcx
    push rax

    mov rcx, 512
    xor al, al

.loop:
    mov [rdi], al
    inc rdi
    loop .loop

    pop rax
    pop rcx
    pop rdi
    ret

clear_editor_sized_buffer:
    ; RDI = buffer
    ; clears EDITOR_MAX bytes

    push rdi
    push rcx
    push rax

    mov rcx, EDITOR_MAX
    xor al, al

.loop:
    mov [rdi], al
    inc rdi
    loop .loop

    pop rax
    pop rcx
    pop rdi
    ret


; -------------------------
; RAM text editor
; -------------------------
; ESC exits.
; Enter inserts newline.
; Backspace deletes.

editor:
    ; mvim v1:
    ; real cursor inside editor_buffer
    ; arrows move cursor
    ; typing inserts at cursor
    ; backspace deletes before cursor

    mov rsi, editor_buffer
    call strlen

    mov [mvim_len], rax

    ; open at start like vim
    mov qword [mvim_cursor], 0
    mov qword [mvim_top_line], 0

    call mvim_render

.edit_loop:
    call get_key

    cmp al, KEY_UP
    je .arrow_up

    cmp al, KEY_DOWN
    je .arrow_down

    cmp al, KEY_LEFT
    je .arrow_left

    cmp al, KEY_RIGHT
    je .arrow_right

    cmp al, 27
    je .exit

    cmp al, 13
    je .enter

    cmp al, 8
    je .backspace

    cmp al, 32
    jb .edit_loop

    call mvim_insert_char
    call mvim_render
    jmp .edit_loop

.enter:
    mov al, 10
    call mvim_insert_char
    call mvim_render
    jmp .edit_loop

.backspace:
    call mvim_backspace
    call mvim_render
    jmp .edit_loop

.arrow_up:
    call mvim_move_up
    call mvim_render
    jmp .edit_loop

.arrow_down:
    call mvim_move_down
    call mvim_render
    jmp .edit_loop

.arrow_left:
    call mvim_move_left
    call mvim_render
    jmp .edit_loop

.arrow_right:
    call mvim_move_right
    call mvim_render
    jmp .edit_loop

.exit:
    call clear_screen

    mov rsi, editor_exit_msg
    call print_string
    ret

mvim_render:
    ; Graphics mvim renderer.
    ; Uses graphics terminal cells instead of old VGA text memory.

    call mvim_ensure_cursor_visible

    call clear_screen

    mov rsi, editor_header
    call print_string

    mov rax, [cursor]
    mov [mvim_text_start_cursor], rax

    ; --------------------------------
    ; Skip lines until mvim_top_line
    ; --------------------------------
    mov rsi, editor_buffer
    xor r13, r13              ; R13 = buffer index
    mov rcx, [mvim_top_line]  ; lines to skip

.skip_lines:
    cmp rcx, 0
    je .start_draw

    mov al, [rsi]
    cmp al, 0
    je .start_draw

    cmp al, 10
    jne .skip_next

    dec rcx

.skip_next:
    inc rsi
    inc r13
    jmp .skip_lines


.start_draw:
    xor r14, r14              ; visible row
    xor r15, r15              ; visible col

    ; default cursor position
    mov r12, [mvim_text_start_cursor]

.draw_loop:
    ; If current buffer index is cursor, remember screen cell.
    mov rax, [mvim_cursor]
    cmp r13, rax
    jne .not_cursor_here

    call mvim_calc_cell_pos
    mov r12, rbx

.not_cursor_here:
    cmp r14, MVIM_BODY_ROWS
    jae .finish

    mov al, [rsi]
    cmp al, 0
    je .finish

    cmp al, 10
    je .newline

    ; wrap if column reaches screen width
    cmp r15, SCREEN_COLS
    jb .draw_char

    xor r15, r15
    inc r14

    cmp r14, MVIM_BODY_ROWS
    jae .finish

.draw_char:
    ; AL = char
    ; gfx_draw_cell wants RBX = cell index
    call mvim_calc_cell_pos
    call gfx_draw_cell

    inc r15
    inc rsi
    inc r13
    jmp .draw_loop

.newline:
    xor r15, r15
    inc r14

    inc rsi
    inc r13
    jmp .draw_loop


.finish:
    ; Cursor can also be at end of buffer.
    mov rax, [mvim_cursor]
    cmp r13, rax
    jne .set_cursor

    call mvim_calc_cell_pos
    mov r12, rbx

.set_cursor:
    cmp r12, SCREEN_END
    jb .cursor_ok

    mov r12, LAST_ROW

.cursor_ok:
    mov [cursor], r12
    call update_hardware_cursor
    ret

mvim_calc_vga_pos:
    ; input:
    ;   R14 = visible row
    ;   R15 = visible col
    ; output:
    ;   RDI = VGA address

    push rax

    mov rdi, [mvim_text_start_cursor]

    mov rax, r14
    imul rax, ROW_BYTES
    add rdi, rax

    mov rax, r15
    shl rax, 1
    add rdi, rax

    pop rax
    ret


mvim_calc_cell_pos:
    ; input:
    ;   R14 = visible row
    ;   R15 = visible col
    ; output:
    ;   RBX = terminal cell index

    push rax

    mov rbx, [mvim_text_start_cursor]

    mov rax, r14
    imul rax, SCREEN_COLS
    add rbx, rax

    add rbx, r15

    pop rax
    ret


mvim_get_cursor_line:
    ; output:
    ;   RAX = line number of mvim_cursor

    push rsi
    push rcx

    mov rsi, editor_buffer
    mov rcx, [mvim_cursor]
    xor rax, rax

.loop:
    cmp rcx, 0
    je .done

    cmp byte [rsi], 10
    jne .next

    inc rax

.next:
    inc rsi
    dec rcx
    jmp .loop

.done:
    pop rcx
    pop rsi
    ret


mvim_ensure_cursor_visible:
    ; Keeps mvim_top_line adjusted so cursor line is visible.

    push rax
    push rbx

    call mvim_get_cursor_line
    ; RAX = cursor line

    mov rbx, [mvim_top_line]

    ; if cursor_line < top_line:
    ; top_line = cursor_line
    cmp rax, rbx
    jae .check_bottom

    mov [mvim_top_line], rax
    jmp .done

.check_bottom:
    ; bottom_visible = top_line + MVIM_BODY_ROWS - 1
    mov rbx, [mvim_top_line]
    add rbx, MVIM_BODY_ROWS
    dec rbx

    cmp rax, rbx
    jbe .done

    ; top_line = cursor_line - MVIM_BODY_ROWS + 1
    sub rax, MVIM_BODY_ROWS
    inc rax
    mov [mvim_top_line], rax

.done:
    pop rbx
    pop rax
    ret


mvim_insert_char:
    ; AL = char to insert at mvim_cursor

    push rax
    push rbx
    push rcx
    push rsi
    push rdi

    mov bl, al

    mov rax, [mvim_len]
    cmp rax, EDITOR_MAX - 1
    jae .done

    ; shift bytes right from cursor to end, including null terminator
    mov rcx, [mvim_len]
    sub rcx, [mvim_cursor]
    inc rcx

    mov rsi, editor_buffer
    add rsi, [mvim_len]

    mov rdi, rsi
    inc rdi

    std
    rep movsb
    cld

    ; write inserted char
    mov rdi, editor_buffer
    add rdi, [mvim_cursor]

    mov [rdi], bl

    inc qword [mvim_cursor]
    inc qword [mvim_len]

.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret


mvim_backspace:
    ; Delete char before cursor.

    push rax
    push rcx
    push rsi
    push rdi

    cmp qword [mvim_cursor], 0
    je .done

    dec qword [mvim_cursor]

    ; shift left from cursor+1 to cursor, including null terminator
    mov rsi, editor_buffer
    add rsi, [mvim_cursor]
    inc rsi

    mov rdi, editor_buffer
    add rdi, [mvim_cursor]

    mov rcx, [mvim_len]
    sub rcx, [mvim_cursor]

    cld
    rep movsb

    dec qword [mvim_len]

.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret


mvim_move_left:
    cmp qword [mvim_cursor], 0
    je .done

    dec qword [mvim_cursor]

.done:
    ret


mvim_move_right:
    mov rax, [mvim_cursor]
    cmp rax, [mvim_len]
    jae .done

    inc qword [mvim_cursor]

.done:
    ret


mvim_move_up:
    ; Move cursor to same column on previous line.

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8

    mov rax, [mvim_cursor]     ; current cursor index
    mov rbx, rax               ; find current line start

.find_line_start:
    cmp rbx, 0
    je .got_line_start

    mov rsi, editor_buffer
    add rsi, rbx

    cmp byte [rsi - 1], 10
    je .got_line_start

    dec rbx
    jmp .find_line_start

.got_line_start:
    ; RBX = current line start
    ; RCX = current column
    mov rcx, rax
    sub rcx, rbx

    cmp rbx, 0
    je .done                   ; already first line

    ; previous line ends at current line start - 1
    mov rdx, rbx
    dec rdx                    ; previous line newline index
    mov r8, rdx                ; previous line end

.find_prev_start:
    cmp rdx, 0
    je .got_prev_start

    mov rsi, editor_buffer
    add rsi, rdx

    cmp byte [rsi - 1], 10
    je .got_prev_start

    dec rdx
    jmp .find_prev_start

.got_prev_start:
    ; RDX = previous line start
    ; R8  = previous line end
    ; previous length = R8 - RDX

    mov rax, r8
    sub rax, rdx

    cmp rcx, rax
    jbe .column_ok

    mov rcx, rax

.column_ok:
    add rdx, rcx
    mov [mvim_cursor], rdx

.done:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


mvim_move_down:
    ; Move cursor to same column on next line.

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8

    mov rax, [mvim_cursor]
    mov rbx, rax

.find_line_start:
    cmp rbx, 0
    je .got_line_start

    mov rsi, editor_buffer
    add rsi, rbx

    cmp byte [rsi - 1], 10
    je .got_line_start

    dec rbx
    jmp .find_line_start

.got_line_start:
    ; RCX = current column
    mov rcx, rax
    sub rcx, rbx

    ; find end of current line
    mov rdx, rbx

.find_current_end:
    mov rsi, editor_buffer
    add rsi, rdx

    cmp byte [rsi], 0
    je .done                   ; no next line

    cmp byte [rsi], 10
    je .got_current_end

    inc rdx
    jmp .find_current_end

.got_current_end:
    ; next line starts after newline
    inc rdx

    mov rsi, editor_buffer
    add rsi, rdx

    cmp byte [rsi], 0
    je .done

    mov r8, rdx                ; next line start

.find_next_end:
    mov rsi, editor_buffer
    add rsi, rdx

    cmp byte [rsi], 0
    je .got_next_end

    cmp byte [rsi], 10
    je .got_next_end

    inc rdx
    jmp .find_next_end

.got_next_end:
    ; next line length = RDX - R8
    mov rax, rdx
    sub rax, r8

    cmp rcx, rax
    jbe .column_ok

    mov rcx, rax

.column_ok:
    add r8, rcx
    mov [mvim_cursor], r8

.done:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; -------------------------
; ATA PIO disk I/O
; -------------------------
; QEMU boot command must use:
; -drive file=os.img,format=raw,if=ide

ata_wait:
    mov dx, 0x1F7

.wait:
    in al, dx
    test al, 0x80
    jnz .wait
    ret


ata_read_sector:
    ; EAX = LBA
    ; RDI = destination buffer
    push rax
    push rbx
    push rcx
    push rdx

    mov ebx, eax

    call ata_wait

    mov dx, 0x1F6
    mov al, 0xE0
    mov ecx, ebx
    shr ecx, 24
    and cl, 0x0F
    or al, cl
    out dx, al

    mov dx, 0x1F2
    mov al, 1
    out dx, al

    mov dx, 0x1F3
    mov eax, ebx
    out dx, al

    mov dx, 0x1F4
    mov eax, ebx
    shr eax, 8
    out dx, al

    mov dx, 0x1F5
    mov eax, ebx
    shr eax, 16
    out dx, al

    mov dx, 0x1F7
    mov al, 0x20
    out dx, al

.wait_drq:
    in al, dx
    test al, 0x08
    jz .wait_drq

    mov dx, 0x1F0
    mov rcx, 256

.read_loop:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    loop .read_loop

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


ata_write_sector:
    ; EAX = LBA
    ; RSI = source buffer
    push rax
    push rbx
    push rcx
    push rdx

    mov ebx, eax

    call ata_wait

    mov dx, 0x1F6
    mov al, 0xE0
    mov ecx, ebx
    shr ecx, 24
    and cl, 0x0F
    or al, cl
    out dx, al

    mov dx, 0x1F2
    mov al, 1
    out dx, al

    mov dx, 0x1F3
    mov eax, ebx
    out dx, al

    mov dx, 0x1F4
    mov eax, ebx
    shr eax, 8
    out dx, al

    mov dx, 0x1F5
    mov eax, ebx
    shr eax, 16
    out dx, al

    mov dx, 0x1F7
    mov al, 0x30
    out dx, al

.wait_drq:
    in al, dx
    test al, 0x08
    jz .wait_drq

    mov dx, 0x1F0
    mov rcx, 256

.write_loop:
    mov ax, [rsi]
    out dx, ax
    add rsi, 2
    loop .write_loop

    mov dx, 0x1F7
    mov al, 0xE7
    out dx, al

    call ata_wait

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

ata_read_many:
    ; EAX = starting LBA
    ; RDI = destination buffer
    ; RCX = sector count
    ;
    ; Important:
    ; ata_read_sector changes RDI internally,
    ; so we keep our own pointer in R8.

    push rax
    push rbx
    push rcx
    push rdi
    push r8

    mov ebx, eax
    mov r8, rdi

.loop:
    cmp rcx, 0
    je .done

    mov eax, ebx
    mov rdi, r8
    call ata_read_sector

    add r8, 512
    inc ebx
    dec rcx
    jmp .loop

.done:
    pop r8
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

ata_read_sector_slave:
    ; EAX = LBA
    ; RDI = destination buffer
    ; Reads from primary IDE slave: QEMU index=1

    push rax
    push rbx
    push rcx
    push rdx

    mov ebx, eax

    call ata_wait

    mov dx, 0x1F6
    mov al, 0xF0            ; slave drive, LBA mode
    mov ecx, ebx
    shr ecx, 24
    and cl, 0x0F
    or al, cl
    out dx, al

    mov dx, 0x1F2
    mov al, 1
    out dx, al

    mov dx, 0x1F3
    mov eax, ebx
    out dx, al

    mov dx, 0x1F4
    mov eax, ebx
    shr eax, 8
    out dx, al

    mov dx, 0x1F5
    mov eax, ebx
    shr eax, 16
    out dx, al

    mov dx, 0x1F7
    mov al, 0x20
    out dx, al

.wait_drq:
    in al, dx
    test al, 0x08
    jz .wait_drq

    mov dx, 0x1F0
    mov rcx, 256

.read_loop:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    loop .read_loop

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

ata_write_many:
    ; EAX = starting LBA
    ; RSI = source buffer
    ; RCX = sector count
    ;
    ; Important:
    ; ata_write_sector changes RSI internally,
    ; so we keep our own pointer in R8.

    push rax
    push rbx
    push rcx
    push rsi
    push r8

    mov ebx, eax
    mov r8, rsi

.loop:
    cmp rcx, 0
    je .done

    mov eax, ebx
    mov rsi, r8
    call ata_write_sector

    add r8, 512
    inc ebx
    dec rcx
    jmp .loop

.done:
    pop r8
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; -------------------------
; TinyFS
; -------------------------

mcfs_load_table:
    mov eax, MCFS_TABLE_LBA
    mov rdi, disk_buffer
    call ata_read_sector
    ret


mcfs_save_table:
    mov eax, MCFS_TABLE_LBA
    mov rsi, disk_buffer
    call ata_write_sector
    ret


mcfs_clear_table:
    mov rdi, disk_buffer
    call clear_sector_buffer

    mov eax, MCFS_TABLE_LBA
    mov rsi, disk_buffer
    call ata_write_sector
    ret


mcfs_name_equals:
    ; RSI = entry name
    ; RDI = command_arg
    ; AL = 1 if equal

    push rsi
    push rdi
    push rbx

.loop:
    mov al, [rsi]
    mov bl, [rdi]

    cmp al, bl
    jne .no

    cmp al, 0
    je .yes

    inc rsi
    inc rdi
    jmp .loop

.yes:
    pop rbx
    pop rdi
    pop rsi
    mov al, 1
    ret

.no:
    pop rbx
    pop rdi
    pop rsi
    xor al, al
    ret


mcfs_find_any_in_current:
    ; finds command_arg in current folder
    ; output:
    ;   AL = 1 found, 0 not found
    ;   R12 = slot index
    ;   RBX = entry pointer

    call mcfs_load_table

    xor r12, r12
    mov rbx, disk_buffer

.loop:
    cmp r12, MCFS_MAX_ENTRIES
    jae .not_found

    cmp byte [rbx+0], 1
    jne .next

    mov al, [current_dir]
    cmp [rbx+2], al
    jne .next

    lea rsi, [rbx+4]
    mov rdi, command_arg
    call mcfs_name_equals
    cmp al, 1
    je .found

.next:
    add rbx, MCFS_ENTRY_SIZE
    inc r12
    jmp .loop

.found:
    mov al, 1
    ret

.not_found:
    xor al, al
    ret


mcfs_find_in_current:
    ; input:
    ;   AL = type wanted
    ; output:
    ;   AL = 1 found, 0 not found
    ;   R12 = slot index
    ;   RBX = entry pointer

    mov r15b, al
    call mcfs_load_table

    xor r12, r12
    mov rbx, disk_buffer

.loop:
    cmp r12, MCFS_MAX_ENTRIES
    jae .not_found

    cmp byte [rbx+0], 1
    jne .next

    cmp byte [rbx+1], r15b
    jne .next

    mov al, [current_dir]
    cmp [rbx+2], al
    jne .next

    lea rsi, [rbx+4]
    mov rdi, command_arg
    call mcfs_name_equals
    cmp al, 1
    je .found

.next:
    add rbx, MCFS_ENTRY_SIZE
    inc r12
    jmp .loop

.found:
    mov al, 1
    ret

.not_found:
    xor al, al
    ret


mcfs_create_entry:
    ; input:
    ;   AL = type
    ;   command_arg = name
    ; output:
    ;   AL = 1 created
    ;   AL = 2 already exists
    ;   AL = 0 full/error

    push rbx
    push rcx
    push rsi
    push rdi
    push r12
    push r13

    mov r13b, al

    ; duplicate check
    call mcfs_find_any_in_current
    cmp al, 1
    je .exists

    call mcfs_load_table

    xor r12, r12
    mov rbx, disk_buffer

.find_free:
    cmp r12, MCFS_MAX_ENTRIES
    jae .full

    cmp byte [rbx+0], 0
    je .use_slot

    add rbx, MCFS_ENTRY_SIZE
    inc r12
    jmp .find_free

.use_slot:
    mov byte [rbx+0], 1
    mov [rbx+1], r13b

    mov al, [current_dir]
    mov [rbx+2], al

    mov byte [rbx+3], 0

    ; clear name area
    lea rdi, [rbx+4]
    mov rcx, 24
    xor al, al
.clear_name:
    mov [rdi], al
    inc rdi
    loop .clear_name

    ; copy max 23 chars
    mov rsi, command_arg
    lea rdi, [rbx+4]
    mov rcx, 23

.copy_name:
    cmp rcx, 0
    je .save

    mov al, [rsi]
    cmp al, 0
    je .save

    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .copy_name

.save:
    call mcfs_save_table

    mov al, 1
    jmp .done

.exists:
    mov al, 2
    jmp .done

.full:
    xor al, al

.done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret


mcfs_remove_entry:
    ; command_arg = name
    ; output AL = 1 removed, 0 not found

    push rbx

    call mcfs_find_any_in_current
    cmp al, 1
    jne .not_found

    mov byte [rbx+0], 0
    call mcfs_save_table

    mov al, 1
    jmp .done

.not_found:
    xor al, al

.done:
    pop rbx
    ret


mcfs_print_current_dir:
    ; simple v0.1 pwd:
    ; prints only current folder name, not full nested path yet.

    call mcfs_load_table

    movzx r12, byte [current_dir]
    cmp r12, 0
    je .root

    dec r12
    mov rbx, disk_buffer
    mov rax, r12
    imul rax, MCFS_ENTRY_SIZE
    add rbx, rax

    mov al, '/'
    call print_char

    lea rsi, [rbx+4]
    call print_string

    mov al, 10
    call print_char
    ret

.root:
    mov rsi, mcfs_root_msg
    call print_string
    ret

fs_format:
    mov rdi, disk_buffer
    call clear_sector_buffer

    mov byte [disk_buffer+0], 'M'
    mov byte [disk_buffer+1], 'O'
    mov byte [disk_buffer+2], 'S'
    mov byte [disk_buffer+3], 'F'
    mov byte [disk_buffer+4], 'S'
    mov byte [disk_buffer+5], '1'

    mov rsi, disk_buffer
    mov eax, FS_MAGIC_LBA
    call ata_write_sector

    mov rdi, disk_buffer
    call clear_sector_buffer

    mov rdi, disk_buffer
    call clear_editor_sized_buffer

    mov eax, FS_SOURCE_LBA
    mov rsi, disk_buffer
    mov rcx, EDITOR_SECTORS
    call ata_write_many

    mov eax, FS_BACKUP_LBA
    mov rsi, disk_buffer
    mov rcx, EDITOR_SECTORS
    call ata_write_many

    mov rdi, disk_buffer
    call clear_sector_buffer

    mov rsi, disk_buffer
    mov eax, FS_PROG_LBA
    call ata_write_sector
    call mcfs_clear_table
    mov byte [current_dir], 0
    ret


; -------------------------
; Tiny compiler
; -------------------------
; source:
;   pin "hello"
;
; bytecode:
;   OP_PRINT, bytes..., 0
;   OP_HALT

tiny_compile:
    ; tiny compiler v2
    ;
    ; supports:
    ;   pin "hello"
    ;   pin "world"
    ;   halt
    ;
    ; bytecode:
    ;   OP_PRINT, string, 0
    ;   OP_PRINT, string, 0
    ;   OP_HALT

    mov rdi, program_buffer
    call clear_sector_buffer

    mov rsi, editor_buffer
    mov rdi, program_buffer

.line_loop:
    call tiny_skip_spaces_and_newlines

    cmp byte [rsi], 0
    je .finish

    ; check for halt
    cmp byte [rsi+0], 'h'
    jne .try_pin
    cmp byte [rsi+1], 'a'
    jne .try_pin
    cmp byte [rsi+2], 'l'
    jne .try_pin
    cmp byte [rsi+3], 't'
    jne .try_pin

    mov byte [rdi], OP_HALT
    jmp .save

.try_pin:
    ; check for pin "text"
    cmp byte [rsi+0], 'p'
    jne .fail
    cmp byte [rsi+1], 'i'
    jne .fail
    cmp byte [rsi+2], 'n'
    jne .fail
    cmp byte [rsi+3], ' '
    jne .fail
    cmp byte [rsi+4], '"'
    jne .fail

    ; emit OP_PRINT
    mov byte [rdi], OP_PRINT
    inc rdi

    add rsi, 5

.copy_string:
    mov al, [rsi]

    cmp al, 0
    je .fail

    cmp al, '"'
    je .end_string

    mov [rdi], al
    inc rdi
    inc rsi
    jmp .copy_string

.end_string:
    ; null terminate printed string
    mov byte [rdi], 0
    inc rdi

    ; move past closing quote
    inc rsi

    jmp .line_loop

.finish:
    mov byte [rdi], OP_HALT

.save:
    mov rsi, program_buffer
    mov eax, FS_PROG_LBA
    call ata_write_sector

    mov al, 1
    ret

.fail:
    xor al, al
    ret


tiny_skip_spaces_and_newlines:
.skip:
    cmp byte [rsi], ' '
    je .advance

    cmp byte [rsi], 10
    je .advance

    cmp byte [rsi], 13
    je .advance

    ret

.advance:
    inc rsi
    jmp .skip


tiny_run:
    mov eax, FS_PROG_LBA
    mov rdi, program_buffer
    call ata_read_sector

    mov rsi, program_buffer

.loop:
    mov al, [rsi]
    inc rsi

    cmp al, OP_HALT
    je .done

    cmp al, OP_PRINT
    je .op_print

    mov rsi, bad_program_msg
    call print_string
    ret

.op_print:
    call print_string

    mov al, 10
    call print_char

    jmp .loop

.done:
    ret


autoload_source:
    ; If TinyFS exists and source sector has data,
    ; load saved source into editor_buffer on boot.

    mov eax, FS_MAGIC_LBA
    mov rdi, disk_buffer
    call ata_read_sector

    call check_tinyfs_magic
    cmp al, 1
    jne .no_fs

    mov eax, FS_SOURCE_LBA
    mov rdi, disk_buffer
    call ata_read_sector

    call sector_has_data
    cmp al, 1
    jne .no_source

    mov rsi, disk_buffer
    mov rdi, editor_buffer
    call copy_string

    mov rsi, autoload_done_msg
    call print_string
    ret

.no_fs:
    mov rsi, autoload_no_fs_msg
    call print_string
    ret

.no_source:
    mov rsi, autoload_no_source_msg
    call print_string
    ret


; -------------------------
; Data
; -------------------------

input_buffer   times 256 db 0
editor_buffer  times EDITOR_MAX db 0
backup_buffer  times EDITOR_MAX db 0
disk_buffer    times EDITOR_MAX db 0
program_buffer times 512 db 0
command_name times 32 db 0
command_arg  times 64 db 0
current_dir  db 0


fb_width  dw 0
fb_height dw 0
fb_pitch  dw 0
fb_bpp    db 0
fb_ready  db 0
fb_addr   dq 0
cursor_drawn dq 0xFFFFFFFFFFFFFFFF


cmd_help   db "help",0
cmd_ver    db "ver",0
cmd_clear  db "clear",0
cmd_format db "format",0
cmd_ls     db "ls",0
cmd_mvim   db "mvim",0
cmd_show   db "show",0
cmd_save   db "save",0
cmd_load   db "load",0
cmd_backup db "backup",0
cmd_build  db "build",0
cmd_run    db "run",0
cmd_update db "update",0
cmd_reboot db "reboot",0
cmd_status db "status",0
cmd_snap   db "snap",0
cmd_pwd   db "pwd",0
cmd_cd    db "cd",0
cmd_mkdir db "mkdir",0
cmd_new   db "new",0
cmd_rm    db "rm",0

help_msg db "commands:",10
         db "help   | ver    | clear  |",10
         db "format | status | reboot |",10
         db "mvim   | show   | save   |",10
         db "load   | backup | build  |",10
         db "run    | snap   | update |",10
         db "ls     | pwd    | cd     |",10
         db "mkdir  | new    | rm     |",10,0


ver_msg db "MicroOS v0.7",10,0

format_done_msg db "TinyFS formatted",10,0

ls_msg db "TinyFS fixed files:",10
       db "source  sectors 101-116",10
       db "backup  sectors 117-132",10
       db "program sector 133",10,0


editor_header db "mvim - MicroOS editor",10
              db "arrows = move | type = insert | backspace = delete | ESC = exit",10
              db "------------------------------------------------------------",10
              db 10,0

editor_exit_msg db "mvim closed. use show/save/build/run",10,0

mvim_cursor dq 0
mvim_len dq 0
mvim_text_start_cursor dq 0
mvim_top_line dq 0

show_msg db "editor buffer:",10
         db "--------------",10,0

empty_msg db "(empty)",10,0

save_done_msg db "saved source to TinyFS",10,0
load_done_msg db "loaded source from TinyFS",10,0
backup_done_msg db "restored source backup",10,0

build_ok_msg db "build ok: program saved to TinyFS",10,0
build_fail_msg db "build failed: expected pin ",34,"text",34,10,0

update_ok_msg db "update ok: source saved after build",10,0
update_fail_msg db "update failed: restored backup source",10,0

bad_program_msg db "bad program bytecode",10,0
reboot_msg db "rebooting...",10,0
unknown_msg db "unknown command",10
	    db "type help for commands",10,0

cursor dq 0
line_start dq 0
shift_down db 0
altgr_down db 0
extended_prefix db 0

welcome db "==== MicroOS ====",10
        db "microOS v0.7",10
        db 10,0

prompt db "> ",0

status_header_msg db "MicroOS status:",10,0
status_fs_msg     db "TinyFS formatted: ",0
status_source_msg db "source saved:     ",0
status_backup_msg db "backup saved:     ",0
status_program_msg db "program built:    ",0

yes_msg db "yes",10,0
no_msg  db "no",10,0

snap_done_msg db "snapshot saved to backup",10,0

autoload_done_msg db "autoload: source loaded",10,0
autoload_no_fs_msg db "autoload: TinyFS not formatted",10,0
autoload_no_source_msg db "autoload: no saved source",10,0



boot_ready_msg db "ready. type help",10,0
header_line1 db " MicroOS v2",0
header_line2 db "",0

mvim_up_msg db "[up]",10,0
mvim_down_msg db "[down]",10,0
mvim_left_msg db "[left]",10,0
mvim_right_msg db "[right]",10,0

mcfs_no_arg_msg db "missing name",10,0
mcfs_full_msg db "McFS table full",10,0
mcfs_exists_msg db "already exists",10,0
mcfs_not_found_msg db "not found",10,0
mcfs_mkdir_done_msg db "folder created",10,0
mcfs_new_done_msg db "file created",10,0
mcfs_rm_done_msg db "removed",10,0
mcfs_ls_header_msg db "McFS listing:",10,0
mcfs_empty_msg db "(empty)",10,0
mcfs_dir_tag db "[DIR]  ",0
mcfs_file_tag db "[FILE] ",0
mcfs_root_msg db "/",10,0
mcfs_pwd_prefix db "cwd: ",0
mcfs_cd_done_msg db "changed folder",10,0

mvim_gfx_todo_msg db "mvim graphics renderer comes next",10,0
panic_no_gfx_msg db "VBE graphics failed. Use qemu -vga std.",0

update_start_msg db "updating stage2/kernel from update disk...",10,0
update_done_reboot_msg db "update copied. rebooting...",10,0


; -------------------------
; Swedish-ish scancode set 1 maps
; -------------------------

keymap_normal:
    db 0       ; 00
    db 27      ; 01 Esc
    db '1'     ; 02
    db '2'     ; 03
    db '3'     ; 04
    db '4'     ; 05
    db '5'     ; 06
    db '6'     ; 07
    db '7'     ; 08
    db '8'     ; 09
    db '9'     ; 0A
    db '0'     ; 0B
    db '+'     ; 0C
    db 0       ; 0D
    db 8       ; 0E
    db 9       ; 0F

    db 'q'     ; 10
    db 'w'     ; 11
    db 'e'     ; 12
    db 'r'     ; 13
    db 't'     ; 14
    db 'y'     ; 15
    db 'u'     ; 16
    db 'i'     ; 17
    db 'o'     ; 18
    db 'p'     ; 19
    db 0x86    ; 1A å
    db 0       ; 1B
    db 13      ; 1C
    db 0       ; 1D

    db 'a'     ; 1E
    db 's'     ; 1F
    db 'd'     ; 20
    db 'f'     ; 21
    db 'g'     ; 22
    db 'h'     ; 23
    db 'j'     ; 24
    db 'k'     ; 25
    db 'l'     ; 26
    db 0x94    ; 27 ö
    db 0x84    ; 28 ä
    db 0       ; 29
    db 0       ; 2A
    db 39      ; 2B

    db 'z'     ; 2C
    db 'x'     ; 2D
    db 'c'     ; 2E
    db 'v'     ; 2F
    db 'b'     ; 30
    db 'n'     ; 31
    db 'm'     ; 32
    db ','     ; 33
    db '.'     ; 34
    db '-'     ; 35
    db 0       ; 36
    db '*'     ; 37
    db 0       ; 38
    db ' '     ; 39

    times 0x56-($-keymap_normal) db 0
    db '<'

    times 128-($-keymap_normal) db 0


keymap_shift:
    db 0       ; 00
    db 27      ; 01
    db '!'     ; 02
    db '"'     ; 03
    db '#'     ; 04
    db 0       ; 05
    db '%'     ; 06
    db '&'     ; 07
    db '/'     ; 08
    db '('     ; 09
    db ')'     ; 0A
    db '='     ; 0B
    db '?'     ; 0C
    db 0       ; 0D
    db 8       ; 0E
    db 9       ; 0F

    db 'Q'     ; 10
    db 'W'     ; 11
    db 'E'     ; 12
    db 'R'     ; 13
    db 'T'     ; 14
    db 'Y'     ; 15
    db 'U'     ; 16
    db 'I'     ; 17
    db 'O'     ; 18
    db 'P'     ; 19
    db 0x8F    ; 1A Å
    db 0       ; 1B
    db 13      ; 1C
    db 0       ; 1D

    db 'A'     ; 1E
    db 'S'     ; 1F
    db 'D'     ; 20
    db 'F'     ; 21
    db 'G'     ; 22
    db 'H'     ; 23
    db 'J'     ; 24
    db 'K'     ; 25
    db 'L'     ; 26
    db 0x99    ; 27 Ö
    db 0x8E    ; 28 Ä
    db 0       ; 29
    db 0       ; 2A
    db '*'     ; 2B

    db 'Z'     ; 2C
    db 'X'     ; 2D
    db 'C'     ; 2E
    db 'V'     ; 2F
    db 'B'     ; 30
    db 'N'     ; 31
    db 'M'     ; 32
    db ';'     ; 33
    db ':'     ; 34
    db '_'     ; 35
    db 0       ; 36
    db '*'     ; 37
    db 0       ; 38
    db ' '     ; 39

    times 0x56-($-keymap_shift) db 0
    db '>'

    times 128-($-keymap_shift) db 0


keymap_altgr:
    db 0       ; 00
    db 27      ; 01
    db 0       ; 02
    db '@'     ; 03
    db 0       ; 04
    db '$'     ; 05
    db 0       ; 06
    db 0       ; 07
    db '{'     ; 08
    db '['     ; 09
    db ']'     ; 0A
    db '}'     ; 0B
    db 92      ; 0C backslash
    db 0       ; 0D
    db 8       ; 0E
    db 9       ; 0F

    db 0       ; 10
    db 0       ; 11
    db 0       ; 12
    db 0       ; 13
    db 0       ; 14
    db 0       ; 15
    db 0       ; 16
    db 0       ; 17
    db 0       ; 18
    db 0       ; 19
    db 0       ; 1A
    db '~'     ; 1B
    db 13      ; 1C
    db 0       ; 1D

    db 0       ; 1E
    db 0       ; 1F
    db 0       ; 20
    db 0       ; 21
    db 0       ; 22
    db 0       ; 23
    db 0       ; 24
    db 0       ; 25
    db 0       ; 26
    db 0       ; 27
    db 0       ; 28
    db 0       ; 29
    db 0       ; 2A
    db 0       ; 2B

    db 0       ; 2C
    db 0       ; 2D
    db 0       ; 2E
    db 0       ; 2F
    db 0       ; 30
    db 0       ; 31
    db 0       ; 32
    db 0       ; 33
    db 0       ; 34
    db 0       ; 35
    db 0       ; 36
    db 0       ; 37
    db 0       ; 38
    db ' '     ; 39

    times 0x56-($-keymap_altgr) db 0
    db '|'

    times 128-($-keymap_altgr) db 0
