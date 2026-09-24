; Cosm OS 1 - interface (Build 1.4.2026)
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
; O que esta build faz:
;   PINTA A TELA TODA DE BRANCO escrevendo DIRETO no framebuffer
;   (endereco do BAR0 que o video.dr reportou no bloco): um
;   rep stosd com 0xFFFFFFFF cobrindo largura x altura.
;   ZERO chamada de GOP, ZERO console - a partir desta build o GOP
;   so existe no bootloader (regra aprovada na 1.4.2026).
;   Depois SEGURA: a tela branca fica parada (fim da build).
;
; Bloco de especificacoes (offsets - mesmo contrato do video.asm):
;   +16 dq framebuffer (BAR0)   +24 dd largura   +28 dd altura
;
; Pilha: nao faz NENHUMA chamada de funcao (nem de firmware) - o
;   rep stosd nao precisa de sombra nem de alinhamento. Se um dia
;   for chamar a firmware aqui dentro: alinhar rsp (~0 mod 16) e
;   reservar 32 bytes de sombra ANTES do call.

BITS 64
default rel

assinatura:
    db 'i','n','t','e','r','f','a','c','e','.','g','r','a','i','n' ; 15 bytes
magic:                            ; 4 bytes de PROVA - o diretorio da ISO
    db 'I','F','1','4'           ; guarda o nome 'interface.grain' tambem;
                                  ; so o ARQUIVO tem este magic depois dele
                                  ; (kernel: sem ele, NUNCA salta)

interface:                        ; JMP do kernel chega aqui (RDX = bloco)
    mov   rdi, [rdx + 16]         ; rdi = framebuffer (BAR0, dado do driver)
    test  rdi, rdi
    jz    .segura                 ; sem framebuffer? segura (nao deve ocorrer)

    mov   eax, [rdx + 24]         ; largura em pixels
    mul   dword [rdx + 28]        ; edx:eax = largura x altura (pixels)
    mov   ecx, eax                ; total de pixels (cabe em 32 bits:
                                  ; 1920x1080 = 2.073.600)
    jecxz .segura                 ; tela 0x0? segura

    mov   eax, 0xFFFFFFFF         ; 0xFFRRGGBB = BRANCO PURO (32 bpp)
    cld                           ; rep pra frente (DF=0, garantia)
    rep   stosd                   ; preenche o framebuffer inteiro de branco

.segura:
    jmp   .segura                 ; a tela branca fica parada (fim da 1.4)
