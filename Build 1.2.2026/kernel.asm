; Cosm OS 1 - kernel (Build 1.2.2026)
; Binario FLAT (nasm -f bin): 100% position-independent - ZERO endereco fixo,
; roda em qualquer endereco da memoria (RIP-relative, sem "org" nenhum).
;
; Formato do arquivo "kernel-1.2.2026":
;   offset 0 : ASSINATURA 'K12B' (e ela que o bootloader varre na midia)
;   offset 4 : KERNEL - o bootloader da Build 1.2 salta pra ca com
;              RCX=ImageHandle, RDX=SystemTable (mesma entrada do UEFI)
;
; O que o kernel faz: limpa a tela (preto), escreve "kernel-1.2.2026"
; em branco e repinta a cada 0,2s - fica ali pra sempre.

BITS 64                         ; -f bin assume 16-bit por padrao - nos queremos x86-64
default rel

assinatura:
    db 'K','1','2','B'           ; 4 bytes - o bootloader procura isso

kernel:                           ; o bootloader da Build 1.2 faz jmp aqui
    and   rsp, -16                ; garante pilha alinhada (veio de um JMP,
                                  ; nao de um CALL - alinha por conta propria)
    sub   rsp, 32                 ; espaco de sombra (ABI Microsoft x64)

    mov   rbx, rdx                ; rbx = System Table
    mov   rdi, [rbx + 0x40]       ; rdi = ConOut (console de texto)
    mov   r12, [rbx + 0x60]       ; r12 = Boot Services

    xor   ecx, ecx                ; desliga o watchdog de novo (garantia:
    xor   edx, edx                ; nosso loop nunca pode ser interrompido
    xor   r8,  r8                 ; por um reinicio automatico)
    xor   r9,  r9
    call  qword [r12 + 0x100]     ; SetWatchdogTimer(0,0,0,0)

repinta:
    mov   rcx, rdi                ; ClearScreen(ConOut) -> fundo preto
    call  qword [rdi + 48]

    mov   rcx, rdi                ; SetAttribute(ConOut, 0x0F)
    mov   rdx, 0x0F               ; 0x0F = texto BRANCO, fundo preto
    call  qword [rdi + 40]

    mov   rcx, rdi                ; OutputString(ConOut, texto)
    lea   rdx, [rel texto]
    call  qword [rdi + 8]

    mov   rcx, 200000             ; Stall(200000 microssegundos = 0,2s)
    call  qword [r12 + 0xF8]      ; Boot Services + 0xF8 = Stall

    jmp   repinta                 ; fica aqui pra sempre

texto:                            ; UTF-16: "kernel-1.2.2026"
    dw 'k','e','r','n','e','l','-','1','.','2','.','2','0','2','6'
    dw 0
