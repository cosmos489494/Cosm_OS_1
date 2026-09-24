; Cosm OS 1 - kernel (Build 1.4.2026)
; Binario FLAT (nasm -f bin): 100% position-independent - ZERO endereco fixo,
; roda em qualquer endereco da memoria (RIP-relative, sem "org" nenhum).
;
; Formato do arquivo "kernel-1.4.2026":
;   offset 0 : ASSINATURA 'K12B' (e ela que o bootloader varre na midia)
;   offset 4 : KERNEL - o bootloader salta pra ca com
;              RCX=ImageHandle, RDX=SystemTable (entrada UEFI) e
;              R8=FrameBufferBase, R9=largura, R10=altura - valores
;              lidos do GOP pelo BOOTLOADER (unico dono do GOP aqui)
;
; O que o kernel faz nesta build (1.4.2026 - fluxo aprovado):
;   1) limpa a tela e escreve "kernel-1.4.2026";
;   2) varre a midia pela ASSINATURA do driver ('V13D' de video.dr,
;      mascarada com XOR 0xA7) - por assinatura, sem caminho nenhum;
;   3) CHAMA o driver (RCX = System Table): o driver SO LE a placa
;      (PCI, framebuffer, VBE/DISPI, SONDA as resolucoes, RESTAURA o
;      modo original) e DEVOLVE o bloco de especificacoes;
;   4) o KERNEL aplica a RESOLUCAO MAIS ALTA do relatorio via
;      ConOut->SetMode (politica aprovada: sempre a mais alta que
;      console e placa aceitarem);
;   5) CHAMA o driver de NOVO (mesma ABI, driver sem alteracao): com o
;      modo ja aplicado, o driver le XRES/YRES ATUAIS e o bloco sai
;      com as dimensoes EXATAS + fb - e o que o interface.grain usa;
;   6) pinta as DUAS linhas e espera 5 SEGUNDOS (Stall 5.000.000 us);
;   7) DEPOIS dos 5s varre a midia por 'interface.grain' (assinatura
;      de 15 bytes, mascarada XOR 0xA7) e PASSA O CONTROLE:
;        RCX = System Table | RDX = &bloco | jmp entrada (+19 - o
;        magic 'IF14' em +15 prova que e o arquivo mesmo, nao o
;        nome que o diretorio da ISO carrega)
;      - o kernel nunca mais roda. O interface.grain pinta a tela de
;      branco DIRETO no framebuffer (BAR0 do driver) - ZERO GOP daqui
;      pra frente (GOP ficou SO no bootloader) - e segura em loop;
;   relatorio do driver FRACO (GPU real nao tem DISPI/Bochs): o kernel
;   NAO mexe no modo (o firmware ja esta no modo que o bootloader leu
;   do GOP) e pinta com os valores do GOP repassados em R8/R9/R10;
;   sem GOP valido NUNCA pinta - as mensagens ficam (nunca escrever
;   em endereco duvidoso de placa desconhecida);
;   nao achou driver: so a linha 1, pra sempre (silencioso);
;   nao achou interface.grain: as mensagens continuam na tela (loop).
; ABI do driver e do interface (contrato identico nos 3 arquivos):
;   chamada: RCX = System Table
;   volta   : driver  -> RAX = status (0 = pronto) | RDX = &bloco
;             interface -> NAO VOLTA (jmp de saida, fim do kernel)
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

    mov   [gop_fb], r8            ; GUARDA o que o BOOTLOADER leu do GOP
    mov   dword [gop_larg], r9d   ; (R8=fb R9=largura R10=altura) - em
    mov   dword [gop_alt], r10d   ; maquina REAL e a UNICA fonte boa de
                                  ;  video (GPU nao tem DISPI); volateis:
                                  ;  salvar ANTES de qualquer call.
                                  ;  ATENCAO (bug real): r9/r10 em dd tem
                                  ;  que ser store de 32 bits - um store
                                  ;  de 64 estourava no proximo rotulo e
                                  ;  apagou o começo do texto1!

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

    mov   rcx, rdi                ; OutputString("kernel-1.4.2026")
    lea   rdx, [rel texto1]
    call  qword [rdi + 8]

; ------------- acha o video.dr e pega o RELATORIO dele -------------
    call  achar_video             ; RAX = 0 (achou+leu) | RDX = &bloco
    test  rax, rax
    jnz   repinta                 ; nao achou: repinta so a linha 1 pra sempre

    mov   [espec_ptr], rdx         ; guarda o bloco de especificacoes
    mov   byte [configurado], 1   ; flag: mostra a 2a linha no loop

; ---- o relatorio do driver e CONFIAVEL? (GPU real nao tem DISPI) ----
; so confia se: n_modos>0 E larg/alt em faixa E fb != 0. Em maquina
; real isso vem zerado/garbage -> NAO mexe no modo: o modo do firmware
; e exatamente o que o bootloader leu do GOP, entao os valores
; capturados (R8/R9/R10) continuam verdadeiros.
    mov   rax, [espec_ptr]
    cmp   dword [rax + 40], 0     ; n_modos
    je    .modo_ok
    mov   ecx, [rax + 24]         ; larg_atual
    cmp   ecx, 64
    jb    .modo_ok
    cmp   ecx, 7680
    ja    .modo_ok
    mov   r8d, [rax + 28]         ; alt_atual
    cmp   r8d, 64
    jb    .modo_ok
    cmp   r8d, 4320
    ja    .modo_ok
    cmp   qword [rax + 16], 0     ; fb (BAR0)
    je    .modo_ok
    call  escolhe_modo            ; driver CONFIAVEL: KERNEL escolhe a MAIS
                                  ;  ALTA e FAZ A MUDANCA via ConOut->SetMode
.modo_ok:

; ------------- 2a CHAMADA ao driver: dimensoes EXATAS -------------
; o SetMode ja PROGRAMOU a placa no modo novo; o driver e chamado de
; novo (mesma ABI, sem mudanca nenhuma nele) e le XRES/YRES ATUAIS +
; fb - o bloco sai daqui com as dimensoes EXATAS do modo aplicado,
; que e o que o interface.grain vai usar pra pintar tudo.
    mov   rcx, rbx                ; System Table pro driver
    call  qword [drv_entry]       ; 2a entrada do video.dr
    mov   [espec_ptr], rdx        ; bloco ATUALIZADO (fb + larg/alt exatas)

; ---- o bloco final da PINTURA? driver bom -> senao, GOP do boot ----
    mov   rax, [espec_ptr]
    mov   ecx, [rax + 24]         ; larg_atual
    cmp   ecx, 64
    jb    .tenta_gop
    cmp   ecx, 7680
    ja    .tenta_gop
    mov   r8d, [rax + 28]         ; alt_atual
    cmp   r8d, 64
    jb    .tenta_gop
    cmp   r8d, 4320
    ja    .tenta_gop
    cmp   qword [rax + 16], 0     ; fb (BAR0)
    je    .tenta_gop
    mov   byte [pode_pintar], 1   ; dimensoes EXATAS do driver (QEMU)
    jmp   .fim_valida

.tenta_gop:                       ; GPU REAL: usa o GOP do BOOTLOADER
    cmp   qword [gop_fb], 0       ; sem GOP capturado? NUNCA pinta (jamais
    je    .sem_pintura            ;  escrever em endereco duvidoso!)
    mov   ecx, [gop_larg]
    cmp   ecx, 64
    jb    .sem_pintura
    cmp   ecx, 7680
    ja    .sem_pintura
    mov   r8d, [gop_alt]
    cmp   r8d, 64
    jb    .sem_pintura
    cmp   r8d, 4320
    ja    .sem_pintura
    mov   rdx, [espec_ptr]        ; escreve o GOP DENTRO do bloco (o
    mov   r9, [gop_fb]            ;  interface.grain so enxerga o bloco)
    mov   [rdx + 16], r9          ; fb   = FrameBufferBase (bootloader)
    mov   [rdx + 24], ecx         ; larg = resolucao do modo atual do GOP
    mov   r10d, [gop_alt]
    mov   [rdx + 28], r10d        ; alt
    mov   dword [rdx + 32], 32    ; bpp  = 32 (framebuffer UEFI classe 3)
    mov   byte [pode_pintar], 1
    jmp   .fim_valida

.sem_pintura:                     ; relatorio fraco E sem GOP util: as
    mov   byte [pode_pintar], 0   ;  mensagens ficam - nao pinta NUNCA
.fim_valida:

; -------------- as DUAS mensagens na tela por 5 SEGUNDOS --------------
    mov   rcx, rdi                ; ClearScreen(ConOut) -> tela limpa
    call  qword [rdi + 48]

    mov   rcx, rdi                ; SetAttribute(ConOut, 0x0F) = branco
    mov   rdx, 0x0F
    call  qword [rdi + 40]

    mov   rcx, rdi                ; OutputString("kernel-1.4.2026" + CRLF)
    lea   rdx, [rel texto1]
    call  qword [rdi + 8]

    mov   rcx, rdi                ; OutputString("video.dr configurado...")
    lea   rdx, [rel texto2]       ; cursor ja embaixo (texto1 = CRLF)
    call  qword [rdi + 8]

    mov   rcx, 5000000            ; Stall(5.000.000 microssegundos = 5s)
    call  qword [r12 + 0xF8]      ; Boot Services + 0xF8 = Stall

; ------ DEPOIS dos 5s: procura interface.grain e PASSA O CONTROLE ------
    cmp   byte [pode_pintar], 0   ; temos dimensoes SEGURAS pra pintar?
    je    repinta                 ; nao: as mensagens continuam (nunca
                                  ;  escreve em endereco duvidoso)

; cursor PRETO ficava aparecendo em cima da tela branca (o firmware
; continua com o cursor ligado no console). Desliga ANTES do jmp -
; ConOut->EnableCursor = API de console (offset 64), NAO e GOP.
    mov   rcx, rdi                ; This = ConOut
    xor   edx, edx                ; FALSE = esconde o cursor
    call  qword [rdi + 64]        ; SimpleTextOut + 64 = EnableCursor

    call  achar_interface         ; achou: JMP pro interface - NUNCA volta;
                                  ; nao achou: cai direto no repinta (as
                                  ; mensagens continuam na tela)

; ------------- loop (fallback): repinta as DUAS linhas a cada 0,2s -----
repinta:
    mov   rcx, rdi                ; ClearScreen(ConOut) -> fundo preto
    call  qword [rdi + 48]

    mov   rcx, rdi                ; SetAttribute(ConOut, 0x0F)
    mov   rdx, 0x0F               ; 0x0F = texto BRANCO, fundo preto
    call  qword [rdi + 40]

    mov   rcx, rdi                ; OutputString("kernel-1.4.2026" + CRLF)
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

    jmp   repinta                 ; nao achou interface: fica aqui pra sempre

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
    mov   [drv_entry], rax        ; guarda a entrada: depois do SetMode o
                                  ; kernel chama o driver de novo por aqui
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
; achar_interface - varre TODOS os discos (BlockIo) pela ASSINATURA
;                   mascarada de interface.grain ('interface.grain'
;                   XOR 0xA7 - 15 bytes) e PASSA O CONTROLE:
;                     ANTES do jmp confirma o magic 'IF14' em +15 -
;                     o diretorio da ISO tem o MESMO nome e levaria
;                     o salto pra lixo (ja aconteceu: #UD); confirmado:
;                     RCX = System Table | RDX = &bloco do video.dr
;                     jmp pra entrada (+19) - o kernel NUNCA mais roda.
;                   Nao achou: volta com RAX != 0 (as mensagens ficam).
; Pilha desta sub (sub rsp,72, igual a achar_video): mesma disposicao
;   [rsp+0..31] sombra   [rsp+32] 5o arg   [rsp+40] NoHandles
;   [rsp+48] *handles    [rsp+56] *buffer  [rsp+64] *BlockIo
; =========================================================================
achar_interface:
    sub   rsp, 72                 ; frame proprio (alinhado, ver cabecalho)

    lea   r9,  [rsp + 40]         ; &NoHandles
    lea   rax, [rsp + 48]         ; &handles
    mov   [rsp + 32], rax         ; 5o argumento (vai na pilha)
    mov   ecx, 2                  ; SearchType = ByProtocol
    lea   rdx, [rel guid_blockio]
    xor   r8, r8                  ; SearchKey = NULL
    call  qword [r12 + 0x138]     ; LocateHandleBuffer (todos BlockIo)
    test  rax, rax
    jnz   ki_falhou

    lea   r8,  [rsp + 56]         ; &buffer
    mov   ecx, 1                  ; EfiLoaderCode = EXECUTAVEL
    mov   rdx, 0x800100           ; 8 MB + folga
    call  qword [r12 + 0x40]      ; AllocatePool
    test  rax, rax
    jnz   ki_falhou

    mov   rax, [rsp + 56]         ; alinha o buffer a 16 bytes (respeita
    add   rax, 15                 ; IoAlign dos discos)
    and   rax, -16
    mov   [rsp + 56], rax

    xor   r14, r14                ; indice do primeiro disco

; ------------- percorre cada disco (BlockIo) -------------
ki_proximo_handle:
    mov   rax, [rsp + 48]
    cmp   r14, [rsp + 40]
    jae   ki_falhou               ; todos os discos lidos e nao achou
    mov   rcx, [rax + r14*8]      ; handle atual
    lea   rdx, [rel guid_blockio]
    lea   r8,  [rsp + 64]         ; &BlockIo
    call  qword [r12 + 0x98]      ; HandleProtocol
    inc   r14
    test  rax, rax
    jnz   ki_proximo_handle       ; esse handle nao deu BlockIo -> proximo

ki_hp_ok:
    lea   r13, [rel janelas]      ; r13 = percorre a tabela de janelas

ki_janela_try:
    mov   r9, [r13]               ; tamanho da janela atual
    test  r9, r9
    jz    ki_proximo_handle       ; todas as janelas falharam neste disco
    xor   rbp, rbp                ; MediaId a tentar: 0,1,2,3

ki_mid_try:
    mov   r10, [rsp + 64]         ; BlockIo*
    mov   rax, [rsp + 56]         ; buffer
    mov   [rsp + 32], rax         ; 5o arg = Buffer
    mov   rcx, r10                ; 1o arg = This
    mov   rdx, rbp                ; 2o arg = MediaId
    xor   r8, r8                  ; 3o arg = LBA 0
    mov   r9, [r13]               ; 4o arg = BufferSize
    call  qword [r10 + 24]        ; ReadBlocks (BlockIo + 24)
    test  rax, rax
    jz    ki_leitura_ok           ; deu certo!
    inc   rbp
    cmp   rbp, 4
    jb    ki_mid_try
    add   r13, 8                  ; janela grande nao serviu -> tenta a menor
    jmp   ki_janela_try

ki_leitura_ok:
    mov   r13, [r13]              ; r13 = bytes lidos (tamanho da janela)

; ------- varre o buffer pela ASSINATURA (15 bytes mascarados) -------
    mov   rsi, [rsp + 56]
    lea   r9, [rsi + r13]
    sub   r9, 15                  ; ultimo inicio valido
    lea   r15, [rel masc_interface] ; r15 = padrao esperado (fixo na varredura)

ki_varre:
    cmp   rsi, r9
    ja    ki_proximo_handle       ; percorreu o disco inteiro sem achar
    xor   ecx, ecx                ; i = 0 (byte atual do padrao)
ki_compara:
    movzx eax, byte [rsi + rcx]   ; byte da midia
    xor   al, 0xA7                ; desmascara
    cmp   al, [r15 + rcx]         ; == byte esperado ('interface.grain')?
    jne   ki_prox_byte
    inc   ecx
    cmp   ecx, 15                 ; bateu os 15?
    jb    ki_compara

; A assinatura existe NA MIDIA FORA do arquivo tambem: o diretorio da
; ISO guarda o nome 'interface.grain' (RockRidge) - SEM essa prova o
; kernel ja pulou pra lixo uma vez (RSI+15 = bytes do diretorio e o
; CPU deu #UD - instruicao invalida). O magic 'IF14' em +15 so existe
; no proprio arquivo: nao bateu? e o nome do diretorio -> continua.
    cmp   dword [rsi + 15], 0x34314649  ; 'I','F','1','4' (little-endian)
    jne   ki_prox_byte

; ACHOU o ARQUIVO! rsi = assinatura, magic em +15, entrada em +19.
; PASSA O CONTROLE (mesma ABI do driver): RCX = System Table,
; RDX = &bloco do video.dr (fb em +16, larg em +24, alt em +28).
    mov   rcx, rbx                ; System Table pro interface
    mov   rdx, [espec_ptr]        ; bloco com as dimensoes EXATAS
    lea   rax, [rsi + 19]         ; entrada do interface.grain
    add   rsp, 72                 ; desmonta o frame (o jmp nao volta!)
    jmp   rax                     ; ... e o kernel acabou

ki_prox_byte:
    inc   rsi
    jmp   ki_varre

ki_falhou:                        ; nao achou a interface: volta com erro
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
drv_entry:                        ; entrada do video.dr (guardada na 1a
    dq 0                          ;  chamada; o kernel chama de novo)
gop_fb:                           ; GOP capturado pelo BOOTLOADER no
    dq 0                          ;  handoff (R8) - fonte real de video
gop_larg:                         ; resolucao do modo atual do GOP (R9)
    dd 0
gop_alt:                          ; idem, altura (R10)
    dd 0
pode_pintar:                      ; 1 = dimensoes validas (driver OU GOP);
    db 0                          ;  0 = NUNCA chama o interface

texto1:                           ; UTF-16: "kernel-1.4.2026" + quebra de linha
    dw 'k','e','r','n','e','l','-','1','.','4','.','2','0','2','6',13,10
    dw 0
texto2:                           ; UTF-16: "video.dr configurado com sucesso"
    dw 'v','i','d','e','o','.','d','r',' ','c','o','n','f','i','g','u','r'
    dw 'a','d','o',' ','c','o','m',' ','s','u','c','e','s','s','o'
    dw 0
masc_v13d:                        ; 'V13D' XOR 0xA7 - os bytes 'V13D' puros
    db 0xF1, 0x96, 0x94, 0xE3     ; NUNCA aparecem no nosso kernel nem no
                                  ; .efi (so existem puros no proprio video.dr)
masc_interface:                   ; 'interface.grain' XOR 0xA7 (15 bytes) -
    db 0xCE,0xC9,0xD3,0xC2,0xD5   ; os bytes PUROS 'interface.grain' NUNCA
    db 0xC1,0xC6,0xC4,0xC2,0x89   ; aparecem neste kernel - existem puros
    db 0xC0,0xD5,0xC6,0xCE,0xC9   ; so no proprio interface.grain
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
