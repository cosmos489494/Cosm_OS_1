; Cosm OS 1 - bootloader UEFI (Build 1.1.2026)
; Formato: COFF x64 (win64) - o linker transforma em .efi (PE/COFF UEFI)
;
; O UEFI nos chama assim (ABI Microsoft x64):
;   RCX = ImageHandle
;   RDX = SystemTable*
;
; Nenhum endereco fixo: os dados sao acessados via RIP-relative,
; entao a imagem boota em qualquer midia (CD, pendrive com dd, disco virtual).
;
; "Tela sempre na tela": drivers atrasados do firmware repintam a tela
; ~2s depois do boot (logo/erro/preto). Nosso loop RE-ESCREVE a tela a
; cada 0,2s via Boot Services -> Stall: qualquer pincelada do firmware
; dura no maximo 0,2s e a mensagem volta.

default rel

global inicio            ; exporta o simbolo de entrada (build.sh usa /entry:inicio)

section .text
inicio:
    mov   rbx, rdx                ; rbx = System Table (nunca mais sai daqui)
    mov   rdi, [rbx + 0x40]       ; rdi = ConOut (console de texto)
    mov   r12, [rbx + 0x60]       ; r12 = Boot Services (tabela de funcoes)

    sub   rsp, 40                 ; sombra de 32 bytes + 8 de alinhamento (ABI)

;   ATENCAO (bug que ja aconteceu aqui): a System Table tem so ~0x78 bytes.
;   Pra chamar uma funcao dos Boot Services sao DOIS passos de ponteiro:
;     1) r12 = [SystemTable + 0x60]          -> ponteiro da tabela
;     2) call [r12 + offset_da_funcao]       -> a funcao em si
;   Um so passo (ex.: call [rbx + 0x158]) le lixo e cai em endereco-garbage.

    xor   ecx, ecx                ; SetWatchdogTimer(0,0,0,0) =
    xor   edx, edx                ; desliga o watchdog do firmware (senao ele
    xor   r8,  r8                 ; reinicia a maquina em ~5 minutos e a
    xor   r9,  r9                 ; mensagem sumiria da tela)
    call  qword [r12 + 0x100]     ; Boot Services + 0x100 = SetWatchdogTimer

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

    jmp   repetir                 ; recomeca: a mensagem fica PRA SEMPRE

section .data
mensagem:                         ; UTF-16: cada caractere em 16 bits (exigencia do UEFI)
    dw 'C','o','s','m',' ','O','S',' ','1',' ','v','1','.','0',' ','B','u','i','l','d',' ','1','.','1','.','2','0','2','6'
    dw 0
