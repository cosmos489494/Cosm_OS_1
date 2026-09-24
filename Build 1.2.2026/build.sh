#!/usr/bin/env bash
#
# Cosm OS - build.sh
# Compila os fontes Assembly e monta a ISO UEFI bootavel.
#
#   entrada : inicio.asm            (bootloader UEFI)
#             kernel.asm             (kernel - binario flat)
#   saidas  : inicio.obj            (na raiz do projeto)
#             EFI/Boot/bootx64.efi  (na raiz do projeto)
#             kernel-1.2.2026       (na raiz do projeto - SEPARADO)
#             cosmos.iso            (na raiz do projeto)
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

SRC="inicio.asm"
KRN_SRC="kernel.asm"
KRN="kernel-1.2.2026"          # o nome carrega a versao da build
OUT_EFI="EFI/Boot/bootx64.efi"
ISO="cosmos.iso"

# arquivos temporarios (limpos ao sair, mesmo com erro)
STAGE="$(mktemp -d)"
ESP_IMG="$(mktemp /tmp/cosmos_esp_XXXXXX.img)"
cleanup() { rm -rf "$STAGE" "$ESP_IMG"; }
trap cleanup EXIT

echo "== [1/4] NASM: $SRC -> inicio.obj (COFF x64)"
nasm -f win64 "$SRC" -o inicio.obj

echo "== [1/4] LINKER: inicio.obj -> $OUT_EFI (.efi UEFI)"
mkdir -p EFI/Boot
lld-link /machine:x64 /subsystem:efi_application /entry:inicio \
         /out:"$OUT_EFI" inicio.obj

echo "== [2/4] NASM: $KRN_SRC -> $KRN (binario flat - arquivo SEPARADO)"
nasm -f bin "$KRN_SRC" -o "$KRN"

echo "== [3/4] Montando imagem FAT da ESP (só o bootx64.efi, El Torito UEFI)"
dd if=/dev/zero of="$ESP_IMG" bs=1M count=1 status=none
mkfs.fat "$ESP_IMG" >/dev/null
mmd -i "$ESP_IMG" ::/EFI ::/EFI/Boot
mcopy -i "$ESP_IMG" "$OUT_EFI" ::/EFI/Boot/bootx64.efi

echo "== [4/4] XORRISO: gerando $ISO (EFI/Boot/bootx64.efi + $KRN lado a lado)"
mkdir -p "$STAGE/EFI/Boot"
cp "$OUT_EFI" "$STAGE/EFI/Boot/bootx64.efi"
cp "$KRN" "$STAGE/$KRN"
rm -f "$ISO"
xorriso -as mkisofs \
    -V "COSMOS" \
    --boot-catalog-hide \
    -append_partition 1 0xef "$ESP_IMG" \
    -e --interval:appended_partition_1:all:: \
    -no-emul-boot \
    -o "$ISO" \
    "$STAGE"

echo
echo "BUILD OK"
echo "  EFI   : $OUT_EFI ($(stat -c%s "$OUT_EFI") bytes)"
echo "  KERNEL: $KRN ($(stat -c%s "$KRN") bytes)"
echo "  ISO   : $ISO ($(stat -c%s "$ISO") bytes)"
