    .intel_syntax noprefix
    .text
    .globl prepoll_test
prepoll_test:                    # SysV: rdi = fake CTCPServer*, returns r8d (timeout)
    mov     rcx, rdi             # -> win64 first arg register
    sub     rsp, 8
    call    prepoll_body
    add     rsp, 8
    mov     eax, r8d
    ret

prepoll_body:
    .include "prepoll.inc"

    .globl mock_get_queue
mock_get_queue:                  # win64 vtable target: rcx = socket -> &queue (offset 0x40)
    lea     rax, [rcx+0x40]
    ret
    .globl EnsureTimer
EnsureTimer:
    ret
    .globl GetExSocketBySocket
GetExSocketBySocket:             # mock: rcx = server, rdx = fd -> linear search of fake clients
    mov     rax, qword ptr [rcx+0x40]
    mov     r8,  qword ptr [rcx+0x48]
.Lgl:
    cmp     rax, r8
    jae     .Lgn
    mov     r9, qword ptr [rax]
    cmp     qword ptr [r9+0x58], rdx    # fake: fd stored at client+0x58
    je      .Lgy
    add     rax, 8
    jmp     .Lgl
.Lgy:
    mov     rax, r9
    ret
.Lgn:
    xor     eax, eax
    ret
