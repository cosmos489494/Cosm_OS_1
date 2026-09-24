; Cosm OS 1 - driver de video (Build 1.3.2026 - AJUSTE: so CONSULTA e REPORTA)
; Arquivo "video.dr": binario FLAT (nasm -f bin), 100% position-independent
; (RIP-relative, zero endereco fixo) - gravado na RAIZ da ISO, SEPARADO,
; junto do kernel e do EFI (nunca dentro de outro arquivo).
;
; Formato do arquivo "video.dr":
;   offset 0 : ASSINATURA 'V13D' (e ela que o kernel varre na midia,
;              mascarada com XOR 0xA7 igual o bootloader faz com o kernel)
;   offset 4 : ENTRADA do driver - o kernel chama aqui com RCX = System Table
;
; DIVISAO DE TAREFAS (ajuste aprovado nesta build):
;   O DRIVER so CONVERSA com a placa e REPORTA o que descobriu:
;     1) varre a PCI (classe 0x03 = display) e le vendor/device/classe;
;     2) le o BAR0 = endereco fisico do framebuffer (32 ou 64 bits);
;     3) PERGUNTA a placa quem ela e (registro ID VBE/DISPI): resposta
;        0xB0C0..0xB0CF = a placa fala DISPI (familia QEMU/Bochs);
;     4) se fala DISPI: le o modo ATUAL, SONDA uma tabela de resolucoes
;        (escreve, le de volta, anota as que a placa aceitou), RESTAURA
;        o modo original e devolve a LISTA;
;     5) se NAO fala DISPI (placa real desconhecida): so reporta os
;        dados crus da PCI + framebuffer - a driver nao arrisca escrever
;        em registrador de placa que nao conversou com ela;
;     6) preenche o BLOCO DE ESPECIFICACOES e devolve em RDX.
;   Depois da sonda o modo original esta ligado de novo - o console
;   nunca fica com a placa fora de sincronia com a letra.
;   O KERNEL que ESCOLHE a resolucao (SEMPRE A MAIS ALTA do relatorio)
;   e que FAZ A MUDANCA via ConOut->SetMode.
;
; ABI (contrato identico no kernel.asm):
;   entrada: RCX = System Table (reservado p/ uso futuro do driver)
;   saida  : RAX = status (0 = relatorio pronto) | RDX = &bloco
;
; BLOCO DE ESPECIFICACOES (offsets dentro do bloco):
;   +0  dd vendor_id     (ex.: 0x1234 = Bochs/QEMU)
;   +4  dd device_id     (ex.: 0x1111)
;   +8  dd familia       (0 = desconhecida, 1 = fala DISPI)
;   +12 dd classe        (dword bruto do registrador 0x08 da PCI)
;   +16 dq framebuffer   (BAR0 - endereco fisico, vem da placa)
;   +24 dd larg_atual    (XRES lido da placa ANTES da sonda)
;   +28 dd alt_atual     (YRES)
;   +32 dd bpp_atual     (bits por pixel)
;   +36 dd vbe_id        (resposta do registro ID - 0 se nao e DISPI)
;   +40 dd n_modos       (quantas resolucoes a placa aceitou na sonda)
;   +44 dd maior_larg    (maior largura aceita)
;   +48 dd maior_alt     (altura da maior)
;   +52 lista de modos   (n_modos x [dd larg, dd alt], capacidade 16;
;                        gravada em ordem CRESCENTE - a tabela de
;                        sondagem e crescente, entao o fim da lista e
;                        sempre a MAIS ALTA - o kernel percorre de la
;                        pra tras justamente por isso)
;
; Registradores: usa rbx/r12-r15 MAS salva na entrada e restaura na
;                saida (MS x64) - os registradores do kernel atravessam
;                a chamada intactos.
; Pilha: so os push/pop proprios - nenhuma chamada de funcao.

BITS 64
default rel

; ---- atalhos das portas VBE/DISPI (0x1CE = indice, 0x1CF = dados) ----
; Registradores: 0=ID  1=XRES  2=YRES  3=BPP  4=ENABLE  6=VIRT_WIDTH
;                7=X_OFFSET  8=Y_OFFSET
%macro selec 1
    mov   dx, 0x1CE
    mov   ax, %1
    out   dx, ax
%endmacro
%macro escreve 1
    mov   dx, 0x1CF
    mov   ax, %1
    out   dx, ax
%endmacro
%macro le_dado 0
    mov   dx, 0x1CF
    in    ax, dx
%endmacro

TAM_TABELA equ 13                ; resolucoes testadas na sonda

assinatura:
    db 'V','1','3','D'           ; 4 bytes - o kernel procura isso

driver:                           ; o kernel faz call aqui (RCX = System Table)
    push  rbx                     ; salva os nao-volateis que a rotina usa
    push  r12                     ; (MS x64: o kernel os recebe de volta
    push  r13                     ;  intactos, como se nada tivesse acontecido)
    push  r14
    push  r15

; ---------------- 1) varre a PCI pela classe do display ----------------
; endereco de configuracao PCI: bit31=1 (habilita) | bus<<16 | dev<<11 |
;                               fun<<8 | registrador; portas 0xCF8/0xCFC.
    xor   r8d, r8d                ; bus (0..7)
.percorre_bus:
    xor   r9d, r9d                ; device (0..31)
.percorre_dev:
    xor   r10d, r10d              ; function (0..7)
.percorre_fun:
    mov   eax, 0x80000008         ; habilita + registrador 0x08 (classe)
    mov   ecx, r8d
    shl   ecx, 16
    or    eax, ecx                ; + bus
    mov   ecx, r9d
    shl   ecx, 11
    or    eax, ecx                ; + device
    mov   ecx, r10d
    shl   ecx, 8
    or    eax, ecx                ; + function
    mov   dx, 0xCF8               ; porta padrao PCI: escreve o endereco
    out   dx, eax
    mov   dx, 0xCFC               ; porta padrao PCI: le o dado
    in    eax, dx
    shr   eax, 24                 ; byte mais alto = codigo de classe
    cmp   al, 0x03                ; classe 0x03 = controlador de display
    je    .achou                  ; (funcao vazia devolve 0xFF -> ignora)
    inc   r10d
    cmp   r10d, 8
    jb    .percorre_fun
    inc   r9d
    cmp   r9d, 32
    jb    .percorre_dev
    inc   r8d
    cmp   r8d, 8
    jb    .percorre_bus

    mov   eax, 1                  ; nao achou placa de video = FALHOU
    jmp   .sai

; ---------------- 2) achou: identificacao + BAR0 (framebuffer) ----------------
.achou:
    mov   eax, 0x80000000         ; so o bit de habilitacao...
    mov   ecx, r8d
    shl   ecx, 16
    or    eax, ecx                ; + bus
    mov   ecx, r9d
    shl   ecx, 11
    or    eax, ecx                ; + device
    mov   ecx, r10d
    shl   ecx, 8
    or    eax, ecx                ; + function
    mov   r11d, eax               ; r11 = endereco base da placa na PCI

    ; registrador 0x00: vendor (2 bytes baixos) + device (2 bytes altos)
    mov   eax, r11d
    mov   dx, 0xCF8
    out   dx, eax
    mov   dx, 0xCFC
    in    eax, dx
    mov   ecx, eax
    and   ecx, 0xFFFF
    mov   [espec + 0], ecx        ; BLOCO: vendor_id
    shr   eax, 16
    mov   [espec + 4], eax        ; BLOCO: device_id

    ; registrador 0x08: classe completa (revisao/prog-if/subclass/classe)
    mov   eax, r11d
    or    eax, 0x08
    mov   dx, 0xCF8
    out   dx, eax
    mov   dx, 0xCFC
    in    eax, dx
    mov   [espec + 12], eax       ; BLOCO: classe (bruta)

    ; BAR0 = endereco FISICO do framebuffer (dinamico, vem da placa)
    mov   eax, r11d
    or    eax, 0x10               ; + registrador BAR0
    mov   dx, 0xCF8
    out   dx, eax
    mov   dx, 0xCFC
    in    eax, dx                 ; eax = BAR0 bruto (com os bits de flag)

    mov   ecx, eax
    and   ecx, 0x06               ; bits 2:1 = tipo de memoria
    cmp   ecx, 0x04               ; 10b = memoria de 64 BITS
    jne   .bar32

    ; 64 bits: a parte ALTA esta no BAR1 (registrador 0x14)
    mov   [bar0_baixo], eax       ; guarda o bruto (vamos apagar eax em seguida)
    mov   eax, r11d
    or    eax, 0x14               ; + registrador BAR1
    mov   dx, 0xCF8
    out   dx, eax
    mov   dx, 0xCFC
    in    eax, dx                 ; eax = parte alta (32 bits - zera o rax alto)
    shl   rax, 32                 ; empurra pro alto
    mov   ecx, [bar0_baixo]
    and   ecx, 0xFFFFFFF0         ; limpa os 4 bits de flag do baixo
    or    rax, rcx                ; rax = endereco de 64 bits do framebuffer
    jmp   .bar_ok

.bar32:
    and   eax, 0xFFFFFFF0         ; 32 bits: limpa os 4 bits de flag
.bar_ok:
    test  rax, rax
    jz    .falha                  ; BAR0 = 0 -> a placa nao deu memoria
    mov   [espec + 16], rax       ; BLOCO: framebuffer

; ------------- 3) PERGUNTA a placa: quem ela e? (registro ID) -------------
    selec 0                       ; indice 0 = ID (versao VBE/DISPI)
    le_dado                       ; a placa responde com a versao
    movzx eax, ax
    mov   [espec + 36], eax       ; BLOCO: vbe_id
    mov   ecx, eax
    and   ecx, 0xFFF0
    cmp   ecx, 0xB0C0             ; 0xB0C0..0xB0CF = a placa fala DISPI
    je    .fala_dispi

    ; NAO e DISPI (ex.: Intel/NVIDIA em maquina real): so reporta o que
    ; lemos na PCI - nao escreve em registrador de placa estranha
    mov   dword [espec + 8], 0    ; familia = desconhecida
    mov   dword [espec + 24], 0   ; larg_atual
    mov   dword [espec + 28], 0   ; alt_atual
    mov   dword [espec + 32], 0   ; bpp_atual
    mov   dword [espec + 40], 0   ; n_modos
    mov   dword [espec + 44], 0   ; maior_larg
    mov   dword [espec + 48], 0   ; maior_alt
    jmp   .reporta

.fala_dispi:
    mov   dword [espec + 8], 1    ; BLOCO: familia = DISPI (QEMU/Bochs)

    ; modo ATUAL da placa - lido ANTES de mexer em nada (para restaurar)
    selec 1                       ; indice 1 = XRES
    le_dado
    movzx eax, ax
    mov   [espec + 24], eax       ; BLOCO: larg_atual
    selec 2                       ; indice 2 = YRES
    le_dado
    movzx eax, ax
    mov   [espec + 28], eax       ; BLOCO: alt_atual
    selec 3                       ; indice 3 = BPP
    le_dado
    movzx eax, ax
    mov   [espec + 32], eax       ; BLOCO: bpp_atual

    ; guarda o ENABLE original (a sonda desliga e religa a saida)
    selec 4                       ; indice 4 = ENABLE
    le_dado
    movzx eax, ax
    mov   [orig_enable], eax

; ------------- 4) SONDA: quais resolucoes a placa aceita? -------------
; Para cada candidata: desliga, escreve XRES/YRES/BPP/VIRT/OFFSETS, liga
; (0x41 = ligado + nao limpa a VRAM), le de volta - se os 3 valores
; batem, a placa ACEITOU e a resolucao entra na lista. No fim RESTAURA
; o modo original. E so LEITURA de capacidade: quem escolhe e quem
; aplica o modo final e o KERNEL.
    lea   rbx, [rel tabela_modos] ; rbx = tabela de candidatas (larg, alt)
    lea   r12, [rel espec + 52]   ; r12 = onde anota as aceitas
    xor   r13d, r13d              ; r13 = indice da tabela
    mov   dword [espec + 40], 0   ; n_modos = 0
    mov   dword [espec + 44], 0   ; maior_larg = 0
    mov   dword [espec + 48], 0   ; maior_alt = 0

.sonda_prox:
    cmp   r13d, TAM_TABELA        ; acabou a tabela?
    jae   .sonda_fim
    mov   r14d, [rbx + r13*8]     ; r14 = largura candidata
    mov   r15d, [rbx + r13*8 + 4] ; r15 = altura candidata

    selec 4                       ; primeiro DESLIGA a saida (indice 4)
    escreve 0                     ; ENABLE <- 0 (desligado)
    selec 1                       ; XRES = candidata
    escreve r14w
    selec 2                       ; YRES = candidata
    escreve r15w
    selec 3                       ; BPP = 32 (cores)
    escreve 32
    selec 6                       ; VIRT_WIDTH = candidata (sem pan)
    escreve r14w
    selec 7                       ; X_OFFSET = 0
    escreve 0
    selec 8                       ; Y_OFFSET = 0
    escreve 0
    selec 4                       ; liga: 0x41 = LIGADO + nao limpa a VRAM
    escreve 0x41

    selec 1                       ; le de volta: a placa aceitou a largura?
    le_dado
    cmp   ax, r14w
    jne   .sonda_naoy
    selec 2                       ; aceitou a altura?
    le_dado
    cmp   ax, r15w
    jne   .sonda_naoy
    selec 3                       ; aceitou o bpp?
    le_dado
    cmp   ax, 32
    jne   .sonda_naoy

    cmp   dword [espec + 40], 16  ; lista cheia? (nao deve acontecer:
    jae   .sonda_naoy             ;  a tabela tem 13)
    mov   [r12], r14d             ; ANOTA: largura
    mov   [r12 + 4], r15d         ; ANOTA: altura
    add   r12, 8
    inc   dword [espec + 40]      ; n_modos++
    mov   eax, [espec + 44]       ; maior que a maior ja vista?
    cmp   r14d, eax
    jbe   .sonda_naoy
    mov   [espec + 44], r14d      ; maior_larg = esta
    mov   [espec + 48], r15d      ; maior_alt  = esta

.sonda_naoy:
    inc   r13d
    jmp   .sonda_prox

; --------- 5) RESTAURA o modo que estava antes da sonda ---------
; (a tela volta exatamente ao que estava - o console continua certo)
.sonda_fim:
    selec 4
    escreve 0                     ; desliga
    selec 1
    escreve word [espec + 24]     ; XRES original
    selec 2
    escreve word [espec + 28]     ; YRES original
    selec 3
    escreve word [espec + 32]     ; BPP original
    selec 6
    escreve word [espec + 24]     ; VIRT_WIDTH = largura original
    selec 7
    escreve 0                     ; X_OFFSET = 0
    selec 8
    escreve 0                     ; Y_OFFSET = 0
    selec 4                       ; religa a saida com o ENABLE original
    escreve word [orig_enable]

; ---------------- 6) relatorio pronto: devolve o bloco ----------------
.reporta:
    xor   eax, eax                ; RAX = 0 = relatorio pronto
.sai:
    lea   rdx, [rel espec]        ; RDX = &bloco de especificacoes
    pop   r15                     ; devolve os nao-volateis do kernel
    pop   r14
    pop   r13
    pop   r12
    pop   rbx
    ret

.falha:
    mov   eax, 1                  ; RAX != 0 = falhou (sem framebuffer)
    jmp   .sai

; ---------------- bloco de especificacoes (ABI - lido pelo kernel) ----------------
align 8
espec:
    dd 0                          ; +0  vendor_id
    dd 0                          ; +4  device_id
    dd 0                          ; +8  familia (0 desconhecida, 1 DISPI)
    dd 0                          ; +12 classe (bruta, reg 0x08)
    dq 0                          ; +16 framebuffer (BAR0)
    dd 0                          ; +24 larg_atual
    dd 0                          ; +28 alt_atual
    dd 0                          ; +32 bpp_atual
    dd 0                          ; +36 vbe_id
    dd 0                          ; +40 n_modos
    dd 0                          ; +44 maior_larg
    dd 0                          ; +48 maior_alt
    times 16 dd 0, 0              ; +52 lista: pares (larg, alt), ordem crescente

orig_enable: dd 0                 ; ENABLE original (restaurado apos a sonda)
bar0_baixo:  dd 0                 ; (temp: BAR0 bruto durante a leitura)

tabela_modos:                     ; resolucoes testadas na sonda - EM ORDEM
    dd 640, 480                   ; CRESCENTE (o fim da lista = a mais alta;
    dd 800, 600                   ;  o kernel percorre de tras pra frente)
    dd 1024, 768
    dd 1280, 720
    dd 1280, 800
    dd 1366, 768
    dd 1440, 900
    dd 1600, 900
    dd 1680, 1050
    dd 1920, 1080
    dd 1920, 1200
    dd 2560, 1440
    dd 3840, 2160
