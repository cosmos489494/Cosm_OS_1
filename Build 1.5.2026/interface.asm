; Cosm OS 1 - interface (Build 1.5.2026)
; Arquivo "interface.grain": binario FLAT (nasm -f bin), 100%
; position-independent (RIP-relative, ZERO endereco fixo) - SEPARADO
; na raiz da ISO, junto do kernel e do video.dr (nunca dentro de
; outro arquivo).
;
; Formato do arquivo "interface.grain":
;   offset 0  : ASSINATURA 'interface.grain' (15 bytes, PUROS - e
;               ela que o kernel varre na midia, mascarada com
;               XOR 0xA7 do MESMO jeito que K12B e V13D)
;   offset 15 : MAGIC 'IF14' (4 bytes) - PROVA de que e o ARQUIVO:
;               o diretorio da ISO tambem contem o nome
;               'interface.grain' - sem esse magic o kernel ja pulou
;               pra lixo uma vez (1o hit da midia = diretorio; o CPU
;               deu #UD, instruicao invalida). Confirmado no hexdump:
;               diretorio em 0x99C1, arquivo em 0x11800.
;   offset 19 : ENTRADA - o kernel faz JMP pra ca (nunca volta) com
;               RCX = System Table | RDX = &bloco do video.dr
;
; O que esta build (1.5.2026) faz:
;   1) PINTA A TELA TODA DE BRANCO escrevendo DIRETO no framebuffer
;      (endereco do bloco - na maquina real vem do GOP que SO o
;      bootloader leu; aqui e so um endereco numa variavel): um
;      rep stosd com 0xFFFFFFFF cobrindo largura x altura;
;   2) DESENHA LINHAS PRETAS VERTICAIS de 1 pixel de largura nas
;      coordenadas x = 153 e x = 859 (pixel preto de y=0 ate a
;      ultima linha) - a tabela xs controla as coordenadas;
;   3) DESENHA UMA LINHA PRETA HORIZONTAL de 1 pixel de altura em
;      y = 973, de x = 153 ate x = 859 (ponta a ponta, os dois
;      finais inclusos - fecha o retangulo com as verticais);
;   4) ESCREVE "Cosm OS 1" DE PRETO na area (150,32)-(309,78),
;      com uma FONTE 5x7 propria embutida no arquivo, escalada 3x
;      (glifo vira 15x21 px, avanco 17 px) - texto de 151x21 px
;      comecando em (158,45); cada pixel de fonte vira um bloco
;      3x3 preto;
;   ZERO chamada de GOP, ZERO console - o GOP so existe no bootloader
;   (regra aprovada). Depois SEGURA: a tela fica parada (fim).
;
; Bloco de especificacoes (offsets - mesmo contrato do video.asm):
;   +16 dq framebuffer      +24 dd largura   +28 dd altura
;
; Stride: assume-se que pixels por linha == largura (verdade no QEMU
;   e no modo do boot do Galaxy Book4 - branco la cobriu a tela
;   inteira). Se um dia aparecer PixelsPerScanLine > largura, as
;   linhas e o branco precisam usar o stride real.
;
; Pilha: nao faz NENHUMA chamada de funcao (nem de firmware) - o
;   rep stosd nao precisa de sombra nem de alinhamento. Se um dia
;   for chamar a firmware aqui dentro: alinhar rsp (~0 mod 16) e
;   reservar 32 bytes de sombra ANTES do call.
;
; Registradores na entrada (do kernel): RDX = &bloco, RCX = System
;   Table (nao usado aqui). Depois do passo 1: r8=fb, r9=larg,
;   r10=alt, rdx=stride (bytes).

BITS 64
default rel

TEX_X   equ 158                   ; X inicial do texto (pedido: comecar em 158)
TEX_Y   equ 45                    ; Y inicial do texto (centro da area)
AVANCO  equ 17                    ; 15 px de glifo + 2 px de espaco
ESCALA  equ 3                     ; fonte 5x7 -> 15x21 px na tela
GLIFOS  equ 9                     ; "Cosm OS 1" = 9 caracteres

assinatura:
    db 'i','n','t','e','r','f','a','c','e','.','g','r','a','i','n' ; 15 bytes
magic:                            ; 4 bytes de PROVA - o diretorio da ISO
    db 'I','F','1','4'           ; guarda o nome 'interface.grain' tambem;
                                  ; so o ARQUIVO tem este magic depois dele
                                  ; (kernel: sem ele, NUNCA salta)

interface:                        ; JMP do kernel chega aqui (RDX = bloco)
    mov   r8, [rdx + 16]          ; r8 = framebuffer (do bloco)
    test  r8, r8
    jz    .segura                 ; sem framebuffer? segura (nao deve ocorrer)
    mov   r9d, [rdx + 24]         ; r9 = largura em pixels
    mov   r10d, [rdx + 28]        ; r10 = altura em pixels
    test  r9d, r9d
    jz    .segura                 ; tela 0 de largura? segura
    test  r10d, r10d
    jz    .segura                 ; tela 0 de altura? segura

; ---------------- 1) TELA TODA DE BRANCO ----------------
    mov   rdi, r8                 ; comeca no primeiro pixel
    mov   eax, r9d
    mul   r10d                    ; edx:eax = largura x altura (pixels)
    mov   ecx, eax                ; total de pixels (cabe em 32 bits:
                                  ; 1920x1080 = 2.073.600)
    mov   eax, 0xFFFFFFFF         ; 0xFFRRGGBB = BRANCO PURO (32 bpp)
    cld                           ; rep pra frente (DF=0, garantia)
    rep   stosd                   ; preenche o framebuffer inteiro

; ------------- 2) LINHAS PRETAS VERTICAIS (x = 153 e 859) -------------
    lea   rdx, [r9*4]             ; rdx = bytes por linha (stride = larg*4)
    lea   rsi, [rel xs]           ; rsi = comeco da tabela de coordenadas
.prox_x:
    mov   r11d, [rsi]             ; proxima coordenada X
    add   rsi, 4
    test  r11d, r11d
    js    .horizontal             ; -1 = acabou a tabela -> linha H
    cmp   r9d, r11d
    jbe   .prox_x                 ; x fora da tela? nao pinta fora do quadro
    lea   rdi, [r8 + r11*4]       ; 1o pixel da linha: fb + x*4 (y=0)
    mov   ecx, r10d               ; vai do y=0 ate a ultima linha
    xor   eax, eax                ; 0x00000000 = PRETO PURO (32 bpp)
.linha:
    mov   dword [rdi], eax        ; pixel preto em (x, y)
    add   rdi, rdx                ; pula pra linha de baixo (stride)
    loop  .linha
    jmp   .prox_x                 ; proxima coordenada da tabela

; -------- 3) LINHA PRETA HORIZONTAL (y = 973, x = 153..859) --------
.horizontal:
    mov   r11d, 973               ; coordenada Y do pedido (build 1.5)
    cmp   r10d, r11d
    jbe   .segura                 ; y fora da altura? nao pinta fora
    cmp   r9d, 859
    jbe   .segura                 ; x final fora da largura? nao pinta
    mov   rdi, r11                ; comeca em rdi = y
    imul  rdi, rdx                ;   * stride (bytes)
    lea   rdi, [rdi + r8]         ;   + fb  = pixel (0, 973)
    add   rdi, 153 * 4            ;   + x_inicial*4 = pixel (153, 973)
    mov   ecx, 859 - 153 + 1      ; 707 pixels: x=153..859 (pontas inclusas)
    xor   eax, eax                ; 0x00000000 = PRETO PURO
    cld                           ; garantia (DF=0)
    rep   stosd                   ; pinta a faixa horizontal de uma vez

; -------- 4) TEXTO "Cosm OS 1" DE PRETO (area 150,32..309,78) --------
.texto:
    cmp   r9d, TEX_X + GLIFOS * AVANCO - (AVANCO - 15) ; ~305 px
    jb    .segura                 ; tela estreita demais? nao escreve fora
    cmp   r10d, TEX_Y + 7 * ESCALA + 1                 ; 67 px
    jb    .segura                 ; tela baixa demais? nao escreve fora
    lea   r12, [rel fonte]        ; r12 = glifos (9 x 7 bytes), caminha sozinho
    xor   r13d, r13d              ; r13 = indice do glifo (0..8)
.glifo:
    cmp   r13d, GLIFOS
    jae   .segura                 ; acabou os 9 caracteres -> fim
    imul  r14d, r13d, AVANCO      ; x0 em pixels = TEX_X + glifo*17
    add   r14d, TEX_X
    shl   r14d, 2                 ; x0 em BYTES (*4)
    xor   ebx, ebx                ; ebx = linha do glifo (0..6)
.linha_g:
    cmp   ebx, 7
    jae   .proximo_g
    movzx r15d, byte [r12]        ; r15 = bits da linha (bit4 = esquerda)
    xor   esi, esi                ; esi = coluna (0..4)
.col_g:
    cmp   esi, 5
    jae   .fim_linha
    mov   ecx, 4
    sub   ecx, esi                ; bit de teste = 4 - coluna
    bt    r15d, ecx               ; pixel aceso?
    jnc   .prox_col               ; nao -> proxima coluna
    xor   ebp, ebp                ; ebp = dy do bloco 3x3 (0..2)
.dy_g:
    cmp   ebp, 3
    jae   .prox_col
    lea   eax, [rbx*3 + TEX_Y]    ; y = TEX_Y + linha*3 (1 indice so!)
    add   eax, ebp                ;   + dy (dois indices nao existem em x86)
    imul  rax, rdx                ;   * stride (bytes)
    add   rax, r8                 ;   + fb = comeco da linha (0, y)
    mov   edi, esi
    imul  edi, ESCALA * 4         ; coluna * 3 px * 4 bytes
    add   rdi, r14                ;   + x0 (bytes)
    add   rdi, rax                ;   + fb+y*stride = pixel (x, y)
    mov   ecx, ESCALA             ; 3 pixels de largura (dx 0..2)
    xor   eax, eax                ; 0x00000000 = PRETO PURO
    rep   stosd                   ; bloco 3x3: uma linha de 3 por vez
    inc   ebp
    jmp   .dy_g
.prox_col:
    inc   esi
    jmp   .col_g
.fim_linha:
    add   r12, 1                  ; proxima linha do glifo
    inc   ebx
    jmp   .linha_g
.proximo_g:
    inc   r13d
    jmp   .glifo

.segura:
    jmp   .segura                 ; a tela fica parada (fim da build 1.5)

xs:                               ; coordenadas X das linhas verticais
    dd 153                        ; (pedido da build 1.5.2026)
    dd 859
    dd -1                         ; fim da tabela

fonte:                            ; FONTE 5x7: "Cosm OS 1" = 9 glifos x 7
                                  ; linhas; bit4 = coluna da esquerda
    db 01110b,10001b,10000b,10000b,10000b,10001b,01110b ; C
    db 00000b,00000b,01110b,10001b,10001b,10001b,01110b ; o
    db 00000b,00000b,01111b,10000b,01110b,00001b,11110b ; s
    db 00000b,00000b,11111b,10101b,10101b,10101b,10101b ; m
    db 00000b,00000b,00000b,00000b,00000b,00000b,00000b ; ' '
    db 01110b,10001b,10001b,10001b,10001b,10001b,01110b ; O
    db 01111b,10000b,10000b,01110b,00001b,00001b,11110b ; S
    db 00000b,00000b,00000b,00000b,00000b,00000b,00000b ; ' '
    db 00100b,01100b,00100b,00100b,00100b,00100b,01110b ; 1
