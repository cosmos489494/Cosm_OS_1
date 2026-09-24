; Cosm OS 1 - bootloader UEFI (Build 1.4.2026)
; Formato: COFF x64 (win64) - o linker transforma em .efi (PE/COFF UEFI)
;
; O UEFI nos chama assim (ABI Microsoft x64):
;   RCX = ImageHandle
;   RDX = SystemTable*
;
; O que este bootloader faz:
;   1) mostra "Cosm OS 1 v1.0 Build 1.4.2026" e repinta a cada 0,2s
;      (o firmware tenta pincelar a tela ~2s apos o boot - nao deixamos);
;   2) conta 5 segundos (25 x 0,2s);
;   3) varre TODOS os discos da maquina (BlockIo) procurando a ASSINATURA
;      mascarada do kernel - nada de caminho, nada de endereco fixo: o
;      kernel e achado em QUALQUER lugar da midia (CD, USB com dd, etc.);
;   4) salta pra ele (RCX=ImageHandle, RDX=SystemTable, igual UEFI) e,
;      ANTES do salto, captura o GOP - AQUI e o UNICO lugar onde o GOP
;      pode ser tocado (regra da build 1.4) - repassando em registradores:
;        R8 = FrameBufferBase   R9 = largura   R10 = altura
;      (motivo: em maquina REAL a GPU nao tem DISPI/Bochs, o driver nao
;       consegue ler resolucao nem acha o framebuffer de verdade - o
;       bootloader leu tudo do GOP e manda pro kernel).
;   Se nao achar: repinta a mensagem pra sempre (nunca trava).
;
; Como lemos os discos SEM depender do mapa do EFI_BLOCK_IO_MEDIA (o mapa
; da especificacao nao bateu com o firmware de verdade):
;   - tentamos janelas decrescentes (8 MB -> 4 KB), todas multiplas de
;     4096 = validas pra qualquer BlockSize (512 / 2048 / 4096);
;   - LBA = 0 sempre + BufferSize = janela -> quem valida e o firmware;
;   - MediaId tentado de 0 a 3 (as duas midias testadas usaram 1).
;
; Pilha (sub rsp,88 - na entrada RSP~8, entao fica ~0 = alinhado p/ chamadas):
;   [rsp+0..31 ] espaco de sombra (ABI)
;   [rsp+32..39] 5o argumento (LocateHandleBuffer / ReadBlocks)
;   [rsp+40..47] NoHandles       (quantos discos BlockIo existem)
;   [rsp+48..55] *handles        (array devolvido pelo firmware)
;   [rsp+56..63] *buffer         (8 MB de leitura, EfiLoaderCode = executavel)
;   [rsp+64..71] *BlockIo        (protocolo do disco atual)
;
; Registradores: r15=ImageHandle  rbx=SystemTable  r12=BootServices
;                rdi=ConOut       r14=indice de disco
;                r13=janela/bytes lidos  rbp=MediaId  rsi=varredura

default rel

global inicio            ; exporta o simbolo de entrada (build.sh usa /entry:inicio)

section .text
inicio:
    mov   r15, rcx                ; guarda ImageHandle (pro jmp final)
    mov   rbx, rdx                ; rbx = System Table (nunca mais sai daqui)
    mov   rdi, [rbx + 0x40]       ; rdi = ConOut (console de texto)
    mov   r12, [rbx + 0x60]       ; r12 = Boot Services (tabela de funcoes)

    sub   rsp, 88                 ; pilha (ver mapa no cabecalho)

;   ATENCAO (bug que ja aconteceu aqui): a System Table tem so ~0x78 bytes.
;   Pra chamar uma funcao dos Boot Services sao DOIS passos de ponteiro:
;     1) r12 = [SystemTable + 0x60]          -> ponteiro da tabela
;     2) call [r12 + offset_da_funcao]       -> a funcao em si

    xor   ecx, ecx                ; SetWatchdogTimer(0,0,0,0) =
    xor   edx, edx                ; desliga o watchdog do firmware (senao ele
    xor   r8,  r8                 ; reinicia a maquina em ~5 minutos e a
    xor   r9,  r9                 ; tela sumiria)
    call  qword [r12 + 0x100]     ; Boot Services + 0x100 = SetWatchdogTimer

    mov   r13d, 25                ; contador: 25 x 0,2s = 5 segundos

; ---------------- 5 segundos de bootloader (repintando) ----------------
repetir:
    mov   rcx, rdi                ; ClearScreen(ConOut) -> tela limpa
    call  qword [rdi + 48]

    mov   rcx, rdi                ; SetAttribute(ConOut, 0x0F)
    mov   rdx, 0x0F               ; 0x0F = texto BRANCO, fundo preto
    call  qword [rdi + 40]

    mov   rcx, rdi                ; OutputString(ConOut, mensagem)
    lea   rdx, [rel mensagem]
    call  qword [rdi + 8]

    mov   rcx, 200000             ; Stall(200000 microssegundos = 0,2s)
    call  qword [r12 + 0xF8]      ; Boot Services + 0xF8 = Stall

    dec   r13
    jnz   repetir                 ; ate somar os 5 segundos

; ---------------- acha o kernel por ASSINATURA ----------------
    lea   r9,  [rsp + 40]         ; &NoHandles
    lea   rax, [rsp + 48]         ; &handles
    mov   [rsp + 32], rax         ; 5o argumento (vai na pilha)
    mov   ecx, 2                  ; SearchType = ByProtocol
    lea   rdx, [rel guid_blockio]
    xor   r8, r8                  ; SearchKey = NULL
    call  qword [r12 + 0x138]     ; LocateHandleBuffer (todos BlockIo)
    test  rax, rax
    jnz   sem_kernel

    lea   r8,  [rsp + 56]         ; &buffer
    mov   ecx, 1                  ; EfiLoaderCode = EXECUTAVEL (EfiLoaderData
                                  ; pode vir com NX e o jmp daria fault!)
    mov   rdx, 0x800100           ; 8 MB + folga
    call  qword [r12 + 0x40]      ; AllocatePool
    test  rax, rax
    jnz   sem_kernel

    mov   rax, [rsp + 56]         ; alinha o buffer a 16 bytes (respeita
    add   rax, 15                 ; IoAlign dos discos)
    and   rax, -16
    mov   [rsp + 56], rax

    xor   r14, r14                ; indice do primeiro disco

; ------------- percorre cada disco (BlockIo) -------------
proximo_handle:
    mov   rax, [rsp + 48]
    cmp   r14, [rsp + 40]
    jae   sem_kernel              ; todos os discos lidos e nao achou
    mov   rcx, [rax + r14*8]      ; handle atual
    lea   rdx, [rel guid_blockio]
    lea   r8,  [rsp + 64]         ; &BlockIo
    call  qword [r12 + 0x98]      ; HandleProtocol
    inc   r14
    test  rax, rax
    jnz   proximo_handle          ; esse handle nao deu BlockIo -> proximo

hp_ok:
    lea   r13, [rel janelas]      ; r13 = percorre a tabela de janelas
                                  ; (nao-volatil: sobrevive as chamadas)

janela_try:
    mov   r9, [r13]               ; tamanho da janela atual
    test  r9, r9
    jz    proximo_handle          ; todas as janelas falharam neste disco
    xor   rbp, rbp                ; MediaId a tentar: 0,1,2,3

mid_try:
    mov   r10, [rsp + 64]         ; BlockIo*
    mov   rax, [rsp + 56]         ; buffer
    mov   [rsp + 32], rax         ; 5o arg = Buffer
    mov   rcx, r10                ; 1o arg = This
    mov   rdx, rbp                ; 2o arg = MediaId
    xor   r8, r8                  ; 3o arg = LBA 0
    mov   r9, [r13]               ; 4o arg = BufferSize (recarrega: call clobbera)
    call  qword [r10 + 24]        ; ReadBlocks (BlockIo + 24)
    test  rax, rax
    jz    leitura_ok              ; deu certo!
    inc   rbp
    cmp   rbp, 4
    jb    mid_try
    add   r13, 8                  ; janela grande nao serviu -> tenta a menor
    jmp   janela_try

leitura_ok:
    mov   r13, [r13]              ; r13 = bytes lidos (tamanho da janela)

; --------- varre o buffer pela ASSINATURA ('K12B' XOR 0xA7) ---------
    mov   rsi, [rsp + 56]
    lea   r9, [rsi + r13]
    sub   r9, 4                   ; ultimo inicio valido
varre:
    cmp   rsi, r9
    ja    proximo_handle          ; percorreu o disco inteiro sem achar
    movzx eax, byte [rsi]
    xor   al, 0xA7
    cmp   al, byte [rel assinatura_masc]
    jne   .proximo
    movzx eax, byte [rsi + 1]
    xor   al, 0xA7
    cmp   al, byte [rel assinatura_masc + 1]
    jne   .proximo
    movzx eax, byte [rsi + 2]
    xor   al, 0xA7
    cmp   al, byte [rel assinatura_masc + 2]
    jne   .proximo
    movzx eax, byte [rsi + 3]
    xor   al, 0xA7
    cmp   al, byte [rel assinatura_masc + 3]
    jne   .proximo

; ACHOU! rsi aponta pra assinatura; o kernel comeca 4 bytes depois.
; ANTES do salto: captura o GOP (HandleProtocol no ConsoleOutHandle -
; NUNCA LocateProtocol, e nunca fora deste arquivo). Em maquina real e
; a UNICA fonte boa de framebuffer + resolucao (GPU real nao tem DISPI).
    lea   r8,  [rsp + 72]         ; &Interface (slot livre do frame)
    mov   rcx, [rbx + 0x38]       ; SystemTable->ConsoleOutHandle
    lea   rdx, [rel guid_gop]
    call  qword [r12 + 0x98]      ; HandleProtocol
    test  rax, rax
    jnz   .sem_gop                ; console sem GOP -> R8/R9/R10 = 0
    mov   rax, [rsp + 72]         ; rax = GraphicsOutput*
    mov   r13, [rax + 24]         ; r13 = Mode*
    test  r13, r13
    jz    .sem_gop
    mov   r14, [r13 + 8]          ; r14 = Info* (resolucao do modo atual)
    test  r14, r14
    jz    .sem_gop
    mov   r8,  [r13 + 24]         ; R8 = FrameBufferBase (onde PINTAR)
    mov   r9d, [r14 + 4]          ; R9 = HorizontalResolution
    mov   r10d, [r14 + 8]         ; R10 = VerticalResolution
    jmp   .entrega
.sem_gop:
    xor   r8, r8                  ; sem GOP: entrega zerado (o kernel NAO
    xor   r9, r9                  ; vai pintar - segura as mensagens)
    xor   r10, r10
.entrega:
    mov   rcx, r15                ; ImageHandle (como o firmware faria)
    mov   rdx, rbx                ; SystemTable
    lea   rax, [rsi + 4]
    jmp   rax                     ; controle pro kernel (nunca mais volta)

.proximo:
    inc   rsi
    jmp   varre

; --------- fallback: sem kernel, repinta a mensagem pra sempre ---------
sem_kernel:
    xor   r13d, r13d              ; zera o contador (nao volta a zerar em
                                  ; tempo util = repete pra sempre)
    mov   rdi, [rbx + 0x40]       ; recarrega ConOut
    jmp   repetir

section .data
assinatura_masc:                  ; 'K12B' XOR 0xA7 - os bytes 'K12B' puros
    db 0xEC, 0x96, 0x95, 0xE5     ; NUNCA aparecem no nosso .efi (senao a
                                  ; varredura nos encontraria primeiro!)
guid_blockio:                     ; EFI_BLOCK_IO_PROTOCOL
    db 0x21,0x5B,0x4E,0x96, 0x59,0x64, 0xD2,0x11
    db 0x8E,0x39,0x00,0xA0,0xC9,0x69,0x72,0x3B
guid_gop:                         ; EFI_GRAPHICS_OUTPUT_PROTOCOL
    db 0xDE,0xA9,0x42,0x90, 0xDC,0x23, 0x38,0x4A
    db 0x96,0xFB,0x7A,0xDE,0xD0,0x80,0x51,0x6A
mensagem:                         ; UTF-16: cada caractere em 16 bits
    dw 'C','o','s','m',' ','O','S',' ','1',' ','v','1','.','0',' ','B','u','i','l','d',' ','1','.','4','.','2','0','2','6'
    dw 0
janelas:                          ; janelas de leitura (maior -> menor); todas
    dq 0x800000                   ; multiplas de 4096 = validas pra qualquer
    dq 0x400000                   ; BlockSize (512, 2048 ou 4096)
    dq 0x200000
    dq 0x100000
    dq 0x80000
    dq 0x20000
    dq 0x8000
    dq 0x1000
    dq 0                          ; fim da tabela
