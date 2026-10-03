# ============================================================================
#  CSNZ_Server.exe performance patch - injected code (placed in .text padding)
# ============================================================================
    .intel_syntax noprefix
    .text

# ----------------------------------------------------------------------------
#  void PrePoll(CTCPServer* this)   --  rcx = this
#  Called right before the WSAPoll() call in CTCPServer::Listen().
#  Sets m_fds[i].events = POLLRDNORM (+ POLLWRNORM only when that client's
#  send queue is non-empty), clears revents and leaves the poll timeout in r8d.
# ----------------------------------------------------------------------------
    .globl PrePoll
PrePoll:
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
    cmp     rdx, qword ptr [rax+8]      # queue non-empty ?
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

# ----------------------------------------------------------------------------
#  FILE* GetLogFile(const char* path, const char* mode)   -- rcx = path, rdx = mode
#  Replaces the fopen() call in CFileLogger::LogVarg(). The handle is cached
#  (keyed by the path pointer), so the log file is opened once instead of
#  once per log line. If the path pointer changes, a new handle is opened and
#  the old one is simply left alone (same behaviour as the original code).
# ----------------------------------------------------------------------------
    .globl GetLogFile
GetLogFile:
    mov     rax, qword ptr [rip + GLOGFILE]
    test    rax, rax
    jz      .Lgf_open
    cmp     rcx, qword ptr [rip + GLOGPATH]
    jne     .Lgf_open
    ret
.Lgf_open:
    sub     rsp, 0x28
    call    qword ptr [rip + FOPEN_IAT]
    add     rsp, 0x28
    test    rax, rax
    jz      .Lgf_ret
    mov     qword ptr [rip + GLOGFILE], rax
    mov     qword ptr [rip + GLOGPATH], rcx
.Lgf_ret:
    ret

# ----------------------------------------------------------------------------
#  int LogDone(FILE* f)   -- rcx = file
#  Replaces the fclose() call in CFileLogger::LogVarg(): flush the stream but
#  keep it open, so each line still reaches the OS immediately.
# ----------------------------------------------------------------------------
    .globl LogDone
LogDone:
    test    rcx, rcx
    jz      .Lld_ret
    sub     rsp, 0x28
    call    qword ptr [rip + FFLUSH_IAT]
    add     rsp, 0x28
.Lld_ret:
    xor     eax, eax
    ret

# ----------------------------------------------------------------------------
#  void EnsureTimer(void)
#  One-time timeBeginPeriod(1) so the 1 ms WSAPoll timeout really is ~1 ms
#  instead of one system timer tick. Fails silently if winmm.dll is missing.
# ----------------------------------------------------------------------------
    .globl EnsureTimer
EnsureTimer:
    cmp     byte ptr [rip + GTIMERFLAG], 0
    jnz     .Lt_ret
    mov     byte ptr [rip + GTIMERFLAG], 1
    push    rbx
    sub     rsp, 0x20
    lea     rcx, [rip + StrWinmm]
    call    qword ptr [rip + LOADLIB_IAT]
    test    rax, rax
    jz      .Lt_done
    mov     rbx, rax
    mov     rcx, rax
    lea     rdx, [rip + StrTBP]
    call    qword ptr [rip + GETPROC_IAT]
    test    rax, rax
    jz      .Lt_done
    mov     ecx, 1
    call    rax
.Lt_done:
    add     rsp, 0x20
    pop     rbx
.Lt_ret:
    ret

StrWinmm:
    .asciz "winmm.dll"
StrTBP:
    .asciz "timeBeginPeriod"
    .p2align 4
