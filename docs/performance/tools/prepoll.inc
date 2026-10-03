# ---- shared body: void PrePoll(CTCPServer* this)  [rcx=this, returns timeout in r8d]
        push    rbx
        push    rbp
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        mov     r12, rcx                    # r12 = this
        call    EnsureTimer
        xor     ebp, ebp                    # anyPending = 0
        mov     rbx, qword ptr [r12+0x40]   # m_Clients.begin()
        mov     rsi, qword ptr [r12+0x48]   # m_Clients.end()
.Lscan:
        cmp     rbx, rsi
        jae     .Lmasks
        mov     rcx, qword ptr [rbx]
        test    rcx, rcx
        jz      .Lscan_next
        mov     rax, qword ptr [rcx]
        mov     rax, qword ptr [rax+0xc0]   # IExtendedSocket::GetPacketsToSend
        call    rax
        mov     rdx, qword ptr [rax]
        cmp     rdx, qword ptr [rax+8]      # send queue non-empty ?
        jne     .Lany
.Lscan_next:
        add     rbx, 8
        jmp     .Lscan
.Lany:
        mov     ebp, 1
.Lmasks:
        mov     rdi, qword ptr [r12+0x68]   # m_fds.begin()
        mov     r14, qword ptr [r12+0x70]   # m_fds.end()
        add     rdi, 16                     # skip the listening socket (index 0)
        test    ebp, ebp
        jnz     .Lprecise
.Lnone:
        cmp     rdi, r14
        jae     .Ldone
        mov     dword ptr [rdi+8], 0x100    # events = POLLRDNORM, revents = 0
        add     rdi, 16
        jmp     .Lnone
.Lprecise:
        cmp     rdi, r14
        jae     .Ldone
        mov     r13, rdi
        mov     rdx, qword ptr [rdi]        # socket descriptor
        mov     rcx, r12
        call    GetExSocketBySocket
        test    rax, rax
        jz      .Lro
        mov     rcx, rax
        mov     rax, qword ptr [rcx]
        mov     rax, qword ptr [rax+0xc0]
        call    rax
        mov     rdx, qword ptr [rax]
        cmp     rdx, qword ptr [rax+8]
        je      .Lro
        mov     dword ptr [r13+8], 0x110    # POLLRDNORM|POLLWRNORM, revents = 0
        jmp     .Lpnext
.Lro:
        mov     dword ptr [r13+8], 0x100
.Lpnext:
        lea     rdi, [r13+16]
        jmp     .Lprecise
.Ldone:
        mov     r8d, 1                      # WSAPoll timeout (ms)
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbp
        pop     rbx
        ret
