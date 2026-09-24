; Cosm OS 1 - kernel (Build 1.3.2026)
; Binario FLAT (nasm -f bin): 100% position-independent - ZERO endereco fixo,
; roda em qualquer endereco da memoria (RIP-relative, sem "org" nenhum).
;
; Formato do arquivo "kernel-1.3.2026":
;   offset 0 : ASSINATURA 'K12B' (e ela que o bootloader varre na midia)
;   offset 4 : KERNEL - o bootloader da Build 1.3 salta pra ca com
;              RCX=ImageHandle, RDX=SystemTable (mesma entrada do UEFI)
;
; O que o kernel faz nesta build (AJUSTE APROVADO: quem FAZ A MUDANCA do
; modo e o KERNEL - o driver so conversa com a placa e reporta):
;   1) limpa a tela e escreve "kernel-1.3.2026";
;   2) varre a midia pela ASSINATURA do driver ('V13D' de video.dr,
;      mascarada com XOR 0xA7) - o kernel acha o driver do MESMO jeito que
;      o bootloader acha o kernel: por assinatura, sem caminho nenhum;
;   3) CHAMA o driver (RCX = System Table): o driver SO LE a placa
;      (vendor/device/classe na PCI, framebuffer no BAR0, versao e modo
;      atuais do VBE/DISPI, SONDA as resolucoes que a placa aceitou e
;      RESTAURA o modo original) e DEVOLVE o bloco de especificacoes;
;   4) o KERNEL le o bloco e SEMPRE aplica a RESOLUCAO MAIS ALTA do
;      relatorio: percorre a lista da MAIOR p/ menor e aplica a primeira
;      que o console oferecer - via ConOut->SetMode, a API generica do
;      firmware (e o caminho que vale em maquina real, via GOP; o
;      console e o GOP la embaixo vao juntos, cursor e geometria junto);
;      lista vazia/nada casou? aplica a MAIOR que o console oferecer;
;   5) escreve embaixo: "video.dr configurado com sucesso";
;   6) repinta as DUAS linhas a cada 0,2s - fica ali pra sempre.
;   Se nao achar o driver: repinta so a primeira linha (silencioso).
; ABI do driver (contrato identico no video.asm):
;   chamada: RCX = System Table
;   volta   : RAX = status (0 = relatorio pronto) | RDX = &bloco
;   bloco   : +0 vendor +4 device +8 familia +12 classe +16 fb (8 bytes)
;             +24 larg_atual +28 alt_atual +32 bpp_atual +36 vbe_id
;             +40 n_modos +44 maior_larg +48 maior_alt
;             +52 lista de modos: pares (dd larg, dd alt), ate 16,
;             em ordem CRESCENTE (o fim = a mais alta)

BITS 64                         ; -f bin assume 16-bit por padrao - nos queremos x86-64
default rel

assinatura:
    db 'K','1','2','B'           ; 4 bytes - o bootloader procura isso

kernel:                           ; o bootloader da Build 1.3 faz jmp aqui
    and   rsp, -16                ; pilha alinhada (veio de um JMP, nao de CALL)
    sub   rsp, 96                 ; mapa da pilha:
                                  ;   [rsp+0..31 ] espaco de sombra (ABI)
                                  ;   [rsp+32..39] 5o argumento / Colunas
                                  ;   [rsp+40..47] NoHandles / Linhas
                                  ;   [rsp+48..55] *handles
                                  ;   [rsp+56..63] *buffer    (leitura da midia)
                                  ;   [rsp+64..71] *BlockIo

    mov   rbx, rdx                ; rbx = System Table (nunca mais sai daqui)
    mov   rdi, [rbx + 0x40]       ; rdi = ConOut (console de texto)
    mov   r12, [rbx + 0x60]       ; r12 = Boot Services (tabela de funcoes)

    xor   ecx, ecx                ; desliga o watchdog de novo (garantia:
    xor   edx, edx                ; nosso loop nunca pode ser interrompido
    xor   r8,  r8                 ; por um reinicio automatico)
    xor   r9,  r9
    call  qword [r12 + 0x100]     ; SetWatchdogTimer(0,0,0,0)

; ---------------- primeira pintura: so a linha do kernel ----------------
    mov   rcx, rdi                ; ClearScreen(ConOut) -> tela limpa
    call  qword [rdi + 48]

    mov   rcx, rdi                ; SetAttribute(ConOut, 0x0F) = branco
    mov   rdx, 0x0F
    call  qword [rdi + 40]

    mov   rcx, rdi                ; OutputString("kernel-1.3.2026")
    lea   rdx, [rel texto1]
    call  qword [rdi + 8]

; ------------- acha o video.dr e pega o RELATORIO dele -------------
    call  achar_video             ; RAX = 0 (achou+leu) | RDX = &bloco
    test  rax, rax
    jnz   repinta                 ; nao achou: repinta so a linha 1 pra sempre

    mov   [espec_ptr], rdx         ; guarda o bloco de especificacoes
    mov   byte [configurado], 1   ; flag: mostra a 2a linha no loop
    call  escolhe_modo            ; o KERNEL escolhe (sempre a MAIS ALTA)
                                  ;  e FAZ A MUDANCA via ConOut->SetMode

; ------------- loop: repinta as DUAS linhas a cada 0,2s -------------
repinta:
    mov   rcx, rdi                ; ClearScreen(ConOut) -> fundo preto
    call  qword [rdi + 48]

    mov   rcx, rdi                ; SetAttribute(ConOut, 0x0F)
    mov   rdx, 0x0F               ; 0x0F = texto BRANCO, fundo preto
    call  qword [rdi + 40]

    mov   rcx, rdi                ; OutputString("kernel-1.3.2026" + CRLF)
    lea   rdx, [rel texto1]
    call  qword [rdi + 8]

    cmp   byte [configurado], 0   ; driver configurado?
    je    .so_primeira
    mov   rcx, rdi                ; OutputString("video.dr configurado...")
    lea   rdx, [rel texto2]       ; cursor ja esta embaixo (texto1 = CRLF)
    call  qword [rdi + 8]
.so_primeira:

    mov   rcx, 200000             ; Stall(200000 microssegundos = 0,2s)
    call  qword [r12 + 0xF8]      ; Boot Services + 0xF8 = Stall

    jmp   repinta                 ; fica aqui pra sempre

; =========================================================================
; achar_video - varre TODOS os discos (BlockIo) pela assinatura mascarada
;               de video.dr ('V13D' XOR 0xA7) e CHAMA o driver (que nesta
;               build so le/reporta a placa).
;   retorna: RAX = 0 (driver reportou) / RAX != 0 (nao achou/falhou)
;            RDX = &bloco de especificacoes do driver (quando RAX = 0)
; Pilha desta sub (sub rsp,72 na entrada ~8 -> fica ~0 = alinhada):
;   [rsp+0..31] sombra   [rsp+32] 5o arg   [rsp+40] NoHandles
;   [rsp+48] *handles    [rsp+56] *buffer  [rsp+64] *BlockIo
; =========================================================================
achar_video:
    sub   rsp, 72                 ; frame proprio (alinhado, ver cabecalho)

    lea   r9,  [rsp + 40]         ; &NoHandles
    lea   rax, [rsp + 48]         ; &handles
    mov   [rsp + 32], rax         ; 5o argumento (vai na pilha)
    mov   ecx, 2                  ; SearchType = ByProtocol
    lea   rdx, [rel guid_blockio]
    xor   r8, r8                  ; SearchKey = NULL
    call  qword [r12 + 0x138]     ; LocateHandleBuffer (todos BlockIo)
    test  rax, rax
    jnz   kv_falhou

    lea   r8,  [rsp + 56]         ; &buffer
    mov   ecx, 1                  ; EfiLoaderCode = EXECUTAVEL (EfiLoaderData
                                  ; pode vir com NX e a chamada daria fault!)
    mov   rdx, 0x800100           ; 8 MB + folga
    call  qword [r12 + 0x40]      ; AllocatePool
    test  rax, rax
    jnz   kv_falhou

    mov   rax, [rsp + 56]         ; alinha o buffer a 16 bytes (respeita
    add   rax, 15                 ; IoAlign dos discos)
    and   rax, -16
    mov   [rsp + 56], rax

    xor   r14, r14                ; indice do primeiro disco

; ------------- percorre cada disco (BlockIo) -------------
kv_proximo_handle:
    mov   rax, [rsp + 48]
    cmp   r14, [rsp + 40]
    jae   kv_falhou               ; todos os discos lidos e nao achou
    mov   rcx, [rax + r14*8]      ; handle atual
    lea   rdx, [rel guid_blockio]
    lea   r8,  [rsp + 64]         ; &BlockIo
    call  qword [r12 + 0x98]      ; HandleProtocol
    inc   r14
    test  rax, rax
    jnz   kv_proximo_handle       ; esse handle nao deu BlockIo -> proximo

kv_hp_ok:
    lea   r13, [rel janelas]      ; r13 = percorre a tabela de janelas
                                  ; (nao-volatil: sobrevive as chamadas)

kv_janela_try:
    mov   r9, [r13]               ; tamanho da janela atual
    test  r9, r9
    jz    kv_proximo_handle       ; todas as janelas falharam neste disco
    xor   rbp, rbp                ; MediaId a tentar: 0,1,2,3

kv_mid_try:
    mov   r10, [rsp + 64]         ; BlockIo*
    mov   rax, [rsp + 56]         ; buffer
    mov   [rsp + 32], rax         ; 5o arg = Buffer
    mov   rcx, r10                ; 1o arg = This
    mov   rdx, rbp                ; 2o arg = MediaId
    xor   r8, r8                  ; 3o arg = LBA 0
    mov   r9, [r13]               ; 4o arg = BufferSize (recarrega: call clobbera)
    call  qword [r10 + 24]        ; ReadBlocks (BlockIo + 24)
    test  rax, rax
    jz    kv_leitura_ok           ; deu certo!
    inc   rbp
    cmp   rbp, 4
    jb    kv_mid_try
    add   r13, 8                  ; janela grande nao serviu -> tenta a menor
    jmp   kv_janela_try

kv_leitura_ok:
    mov   r13, [r13]              ; r13 = bytes lidos (tamanho da janela)

; ------- varre o buffer pela ASSINATURA ('V13D' XOR 0xA7) -------
    mov   rsi, [rsp + 56]
    lea   r9, [rsi + r13]
    sub   r9, 4                   ; ultimo inicio valido
kv_varre:
    cmp   rsi, r9
    ja    kv_proximo_handle       ; percorreu o disco inteiro sem achar
    movzx eax, byte [rsi]
    xor   al, 0xA7
    cmp   al, byte [rel masc_v13d]
    jne   kv_prox_byte
    movzx eax, byte [rsi + 1]
    xor   al, 0xA7
    cmp   al, byte [rel masc_v13d + 1]
    jne   kv_prox_byte
    movzx eax, byte [rsi + 2]
    xor   al, 0xA7
    cmp   al, byte [rel masc_v13d + 2]
    jne   kv_prox_byte
    movzx eax, byte [rsi + 3]
    xor   al, 0xA7
    cmp   al, byte [rel masc_v13d + 3]
    jne   kv_prox_byte

; ACHOU! rsi aponta pra assinatura; o driver comeca 4 bytes depois.
; ABI do driver (contrato no video.asm): RCX = System Table | volta
; RAX = status e RDX = &bloco de especificacoes. O driver SALVA e
; RESTAURA rbx/r12-r15 (MS x64), entao SystemTable/ConOut/BootServices
; atravessam a chamada intactos. Este e o ultimo call antes do ret -
; nenhuma chamada de firmware no caminho, RDX chega no kernel intacto.
    mov   rcx, rbx                ; System Table pro driver
    lea   rax, [rsi + 4]
    call  rax                     ; chama o RELATORIO do video.dr
    add   rsp, 72
    ret                           ; RAX = status do driver pro kernel

kv_prox_byte:
    inc   rsi
    jmp   kv_varre

kv_falhou:                        ; nao achou o driver: volta com erro
    mov   eax, 1
    add   rsp, 72
    ret

; =========================================================================
; escolhe_modo - POLITICA APROVADA: o KERNEL SEMPRE aplica a RESOLUCAO
;                MAIS ALTA. Percorre a lista que o driver reportou da
;                MAIOR p/ menor (o fim da lista e sempre a maior - a
;                tabela de sondagem e crescente); para cada candidata
;                procura no CONSOLE o modo de largura correspondente
;                (colunas = largura / 8 px de fonte). Casou? aplica via
;                ConOut->SetMode - a API generica do firmware (e ela que
;                vale em maquina real, via GOP; o console e o GOP la
;                embaixo vao juntos, cursor e geometria junto).
;                A mais alta do relatorio nao existe no console?
;                desce pra proxima mais alta. Lista vazia ou nada
;                casou? FALLBACK: a MAIOR que o console oferece.
;                Offset's do SimpleTextOut (provados no codigo funcional):
;                OutputString=8 QueryMode=24 SetMode=32.
;   retorna: RAX = 0 (setou) / 1 (o console nao ofereceu nada)
; Pilha desta sub (sub rsp,72):
;   +32 Colunas  +40 Linhas  +48 melhor_cols  +56 melhor_idx  +64 cols_alvo
; =========================================================================
escolhe_modo:
    sub   rsp, 72                 ; frame proprio (alinhado, ver cabecalho)

    mov   r14, [rdi + 72]         ; r14 = ConOut->Mode* (MaxMode em +0;
                                  ;  nao-volatil = sobrevive firmware)
    mov   r13, [espec_ptr]        ; r13 = bloco de especificacoes do driver
    mov   r15d, [r13 + 40]        ; r15 = n_modos
    dec   r15d                    ; ultimo indice (percorre ao contrario)

.es_prox_cand:
    cmp   r15d, 0
    jl    .es_fallback            ; lista esgotada sem casamento
    mov   eax, [r13 + r15*8 + 52] ; largura candidata (maior primeiro)
    test  al, 7                   ; precisa ser multipla de 8 (8 px/coluna)
    jnz   .es_avanca
    shr   eax, 3                  ; colunas alvo = largura / 8
    mov   [rsp + 64], eax
    xor   ebp, ebp                ; ebp = i (modo do console, 0..MaxMode-1)

.es_prox_console:
    cmp   ebp, [r14]              ; i >= MaxMode?
    jae   .es_avanca              ; console esgotou p/ este candidato
    mov   rcx, rdi                ; 1o arg = This (ConOut)
    mov   rdx, rbp                ; 2o arg = numero do modo
    lea   r8,  [rsp + 32]         ; 3o arg = &Colunas
    lea   r9,  [rsp + 40]         ; 4o arg = &Linhas
    call  qword [rdi + 24]        ; QueryMode (ConOut + 24)
    test  rax, rax
    jnz   .es_i_prox              ; modo invalido neste console -> proximo
    mov   eax, [rsp + 32]         ; colunas que o console oferece neste
    cmp   eax, [rsp + 64]         ;  == colunas da candidata?
    jne   .es_i_prox              ; nao -> proximo modo do console
    mov   rcx, rdi                ; ACHOU: aplica a resolucao!
    mov   rdx, rbp                ; indice do modo
    call  qword [rdi + 32]        ; SetMode (ConOut + 32) - console + GOP
                                  ;  reancoram junto (cursor, colunas,
                                  ;  linhas e o hardware la embaixo)
    xor   eax, eax                ; 0 = sucesso
    add   rsp, 72
    ret

.es_i_prox:
    inc   ebp
    jmp   .es_prox_console

.es_avanca:                       ; candidata sem par no console ->
    dec   r15d                    ;  tenta a PROXIMA MAIS ALTA
    jmp   .es_prox_cand

.es_fallback:                     ; nada casou (ou lista vazia): aplica a
    mov   qword [rsp + 48], 0     ;  MAIOR que o console oferece
    mov   dword [rsp + 56], -1    ; melhor_idx (-1 = nenhum ainda)
    xor   ebp, ebp

.es_fb_prox:
    cmp   ebp, [r14]
    jae   .es_fb_fim
    mov   rcx, rdi
    mov   rdx, rbp
    lea   r8,  [rsp + 32]
    lea   r9,  [rsp + 40]
    call  qword [rdi + 24]        ; QueryMode
    test  rax, rax
    jnz   .es_fb_i
    mov   rax, [rsp + 32]
    cmp   rax, [rsp + 48]         ; mais colunas que o melhor ate agora?
    jbe   .es_fb_i
    mov   [rsp + 48], rax
    mov   [rsp + 56], ebp
.es_fb_i:
    inc   ebp
    jmp   .es_fb_prox

.es_fb_fim:
    cmp   dword [rsp + 56], 0
    jl    .es_fb_nenhum           ; nenhum modo valido no console
    mov   rcx, rdi
    movsxd rdx, dword [rsp + 56]  ; indice do maior
    call  qword [rdi + 32]        ; SetMode
    xor   eax, eax
    add   rsp, 72
    ret

.es_fb_nenhum:
    mov   eax, 1
    add   rsp, 72
    ret

section .data
configurado:                      ; 1 = video.dr reportou (mostra linha 2)
    db 0
espec_ptr:                        ; &bloco de especificacoes (RDX do driver)
    dq 0

texto1:                           ; UTF-16: "kernel-1.3.2026" + quebra de linha
    dw 'k','e','r','n','e','l','-','1','.','3','.','2','0','2','6',13,10
    dw 0
texto2:                           ; UTF-16: "video.dr configurado com sucesso"
    dw 'v','i','d','e','o','.','d','r',' ','c','o','n','f','i','g','u','r'
    dw 'a','d','o',' ','c','o','m',' ','s','u','c','e','s','s','o'
    dw 0
masc_v13d:                        ; 'V13D' XOR 0xA7 - os bytes 'V13D' puros
    db 0xF1, 0x96, 0x94, 0xE3     ; NUNCA aparecem no nosso kernel nem no
                                  ; .efi (so existem puros no proprio video.dr)
guid_blockio:                     ; EFI_BLOCK_IO_PROTOCOL
    db 0x21,0x5B,0x4E,0x96, 0x59,0x64, 0xD2,0x11
    db 0x8E,0x39,0x00,0xA0,0xC9,0x69,0x72,0x3B
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
