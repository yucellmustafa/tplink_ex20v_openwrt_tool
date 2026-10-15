#requires -Version 5.1
<#
.SYNOPSIS
    TP-Link EX20v v2 backup, installation and recovery tool.

.DESCRIPTION
    Runs the repository's complete installation flow from one PowerShell file.
    Firmware images are read from the adjacent "files" directory. No Python,
    TFTP server or separate shell scripts are required.
#>

[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8000
)

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    }
    $workingDirectory = Split-Path -Parent $scriptPath
    $isExecutable = [IO.Path]::GetExtension($scriptPath) -ieq '.exe'
    if ($isExecutable) {
        $executable = $scriptPath
        $arguments = @('-Port', $Port)
    }
    else {
        $executable = Join-Path $PSHOME 'powershell.exe'
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $scriptPath),
            '-Port', $Port
        )
    }
    try {
        [void](Start-Process -FilePath $executable `
            -Verb RunAs -WorkingDirectory $workingDirectory -ArgumentList $arguments)
    }
    catch {
        Write-Host 'Yonetici izni verilmedigi icin arac baslatilamadi.' -ForegroundColor Red
        [void](Read-Host 'Kapatmak icin Enter')
        exit 1
    }
    exit 0
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try { $Host.UI.RawUI.WindowTitle = 'TP-Link EX20v v2 - OpenWrt Araci (Yonetici)' } catch {}

$compiledRoot = Get-Variable -Name ScriptRoot -ErrorAction SilentlyContinue
$script:ToolRoot = if ($null -ne $compiledRoot -and -not [string]::IsNullOrWhiteSpace($compiledRoot.Value)) {
    $compiledRoot.Value
}
else {
    $PSScriptRoot
}
$script:ImageRoot = Join-Path $script:ToolRoot 'files'
$script:BackupRoot = Join-Path $script:ToolRoot 'Backups'
$script:StateRoot = Join-Path $script:BackupRoot '.state'
$script:StockUser = 'root'
$script:StockPassword = 'Root2025.'
$script:ImageNames = @(
    'ex20v-rescue.bin',
    'ex20v-kernel.bin',
    'ex20v-ubi.bin',
    'ex20v-v2-sysupgrade.bin'
)

$script:RemoteAgent = @'
#!/bin/sh
set -u

ACTION="${1:-}"
PC="${2:-}"
PORT="${3:-8000}"
BS=262144

say() { printf '%s\n' "$*"; }
die() { say "HATA: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' komutu bulunamadi"; }
mtdn() { sed -n "s/^\(mtd[0-9][0-9]*\):.*\"$1\"$/\1/p" /proc/mtd | head -n 1; }
root_dev() { awk '$5=="/" {print $3; exit}' /proc/self/mountinfo; }
root_fs() { awk '$2=="/" {print $3; exit}' /proc/mounts; }

[ -r /proc/mtd ] || die 'Linux shell acilamadi (/proc/mtd yok)'
say 'EX20V_SHELL=LINUX'

require_ex20v_layout() {
    [ -r /proc/mtd ] || die '/proc/mtd okunamiyor'
    grep -q '^mtd4: 00600000 .* "kernel"$' /proc/mtd || die 'slot A kernel bolumu beklenen duzende degil'
    grep -q '^mtd7: 00600000 .* "kernel_2"$' /proc/mtd || die 'slot B kernel bolumu beklenen duzende degil'
    grep -q '^mtd8: 02000000 .* "rootfs_2"$' /proc/mtd || die 'slot B rootfs bolumu beklenen duzende degil'
    grep -q '^mtd10: 17080000 .* "reserve_area"$' /proc/mtd || die 'reserve_area beklenen duzende degil'
}

require_known_device() {
    if is_openwrt; then
        [ -n "$(mtdn bootflag)" ] || die 'OpenWrt bootflag bolumu bulunamadi'
        [ -n "$(mtdn kernel)" ] || die 'OpenWrt kernel bolumu bulunamadi'
        [ -n "$(mtdn ubi)" ] || die 'OpenWrt UBI bolumu bulunamadi'
    else
        require_ex20v_layout
    fi
}

is_openwrt() {
    grep -q 'tplink,ex20v-v2' /tmp/sysinfo/board_name 2>/dev/null
}

environment() {
    if is_openwrt; then
        case "$(root_fs)" in
            rootfs|tmpfs|ramfs) printf rescue ;;
            *)                  printf openwrt ;;
        esac
    elif require_ex20v_layout >/dev/null 2>&1; then
        printf stock
    else
        printf unknown
    fi
}

fetch() {
    out="$1"; name="$2"
    rm -f "$out"
    if command -v curl >/dev/null 2>&1; then
        curl -sS -f -o "$out" "http://$PC:$PORT/$name" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "http://$PC:$PORT/$name" || return 1
    else
        return 1
    fi
}

select_restore_dir() {
    required_kib="$1"
    for base in /tmp /var/tmp/dev; do
        [ -d "$base" ] || continue
        available="$(df -Pk "$base" 2>/dev/null | awk 'END {print $4}')"
        case "$available" in ''|*[!0-9]*) continue ;; esac
        [ "$available" -ge "$required_kib" ] || continue
        work="$base/ex20v-restore"
        mkdir -p "$work" 2>/dev/null || continue
        probe="$work/.write-test.$$"
        if (umask 077; : > "$probe") 2>/dev/null; then
            rm -f "$probe"
            printf '%s' "$work"
            return 0
        fi
        rmdir "$work" 2>/dev/null || true
    done
    return 1
}

upload() {
    file="$1"; name="${2:-$(basename "$1")}" 
    if command -v curl >/dev/null 2>&1; then
        curl -sS -f -T "$file" "http://$PC:$PORT/$name" >/dev/null || return 1
    elif command -v tftp >/dev/null 2>&1; then
        tftp -p -b 1428 -l "$file" -r "$name" "$PC" "$PORT" >/dev/null 2>&1 ||
            tftp -p -l "$file" -r "$name" "$PC" "$PORT" >/dev/null 2>&1 || return 1
    else
        return 1
    fi
    say "gonderildi: $name"
}

make_char_device() {
    number="$1"; path="$2"
    if [ -e "/dev/mtd$number" ]; then
        printf '/dev/mtd%s' "$number"
        return 0
    fi
    dev="$(cat "/sys/class/mtd/mtd$number/dev" 2>/dev/null)"
    [ -n "$dev" ] || return 1
    rm -f "$path"
    mknod "$path" c "${dev%%:*}" "${dev##*:}" || return 1
    printf '%s' "$path"
}

stock_flag() {
    dd if=/dev/mtdblock2 bs=$BS skip=4 count=1 2>/dev/null | head -c 1
}

openwrt_flag() {
    fp="$(mtdn bootflag)"
    [ -n "$fp" ] || return 1
    dd if="/dev/$fp" bs=1 count=1 2>/dev/null
}

show_slot() {
    env="$(environment)"
    if [ "$env" = stock ]; then flag="$(stock_flag)"; else flag="$(openwrt_flag)"; fi
    case "$env" in
        stock)   env_desc='Stok firmware' ;;
        rescue)  env_desc='Rescue OpenWrt' ;;
        openwrt) env_desc='Ana OpenWrt' ;;
        *)       env_desc='Bilinmeyen sistem' ;;
    esac
    case "$flag" in
        0) desc='Slot A / rescue' ;;
        1) desc='Slot B / ana sistem' ;;
        *) desc='GECERSIZ' ;;
    esac
    say "Calisan sistem : $env_desc"
    say "Acilis tercihi : $desc (bootflag=$flag)"
    say "Root bolumu    : $(root_dev) / $(root_fs)"
}

set_stock_flag() {
    value="$1"; old=/tmp/ex20v-flag-old.bin; new=/tmp/ex20v-flag-new.bin
    dd if=/dev/mtdblock2 of="$old" bs=$BS skip=4 count=1 2>/dev/null || die 'bootflag blogu okunamadi'
    [ "$(wc -c < "$old")" -eq "$BS" ] || die 'bootflag blogu eksik okundu'
    printf '%s' "$value" > "$new"
    dd if="$old" bs=1 skip=1 2>/dev/null >> "$new" || die 'bootflag blogu hazirlanamadi'
    dd if="$new" of=/dev/mtdblock2 bs=$BS seek=4 count=1 conv=notrunc 2>/dev/null || die 'bootflag yazilamadi'
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    a="$(md5sum < "$new")"; b="$(dd if=/dev/mtdblock2 bs=$BS skip=4 count=1 2>/dev/null | md5sum)"
    rm -f "$old" "$new"
    [ "$a" = "$b" ] || die 'bootflag dogrulanamadi; yeniden baslatmayin'
}

set_openwrt_flag() {
    value="$1"; fp="$(mtdn bootflag)"; out=/tmp/ex20v-bootflag.bin
    [ -n "$fp" ] || die 'bootflag bolumu bulunamadi'
    printf '%s' "$value" > "$out"
    dd if=/dev/zero bs=$((BS-1)) count=1 2>/dev/null | tr '\000' '\377' >> "$out"
    mtd write "$out" bootflag >/dev/null || die 'bootflag yazilamadi'
    actual="$(dd if="/dev/$fp" bs=1 count=1 2>/dev/null)"
    rm -f "$out"
    [ "$actual" = "$value" ] || die "bootflag dogrulanamadi (okunan: '$actual')"
}

set_slot() {
    value="$1"
    case "$value" in 0|1) ;; *) die 'slot yalnizca 0 veya 1 olabilir' ;; esac
    if [ "$(environment)" = stock ]; then set_stock_flag "$value"; else set_openwrt_flag "$value"; fi
    say "bootflag='$value' DOGRULANDI"
}

backup_all() {
    [ -n "$PC" ] || die 'PC IP adresi verilmedi'
    require_ex20v_layout
    [ "$(environment)" = stock ] || die 'tam yedek yalnizca stok firmware uzerinde alinabilir'
    command -v curl >/dev/null 2>&1 || command -v tftp >/dev/null 2>&1 || die 'curl veya tftp komutu bulunamadi'
    need dd; need md5sum
    cd /tmp || die '/tmp acilamadi'

    say 'Sistem bilgileri toplaniyor...'
    {
        echo '### date';         date
        echo '### version';      cat /proc/version
        echo '### cpuinfo';      cat /proc/cpuinfo
        echo '### meminfo';      cat /proc/meminfo
        echo '### mtd';          cat /proc/mtd
        echo '### partitions';   cat /proc/partitions
        echo '### devices';      ls -l /dev/mtd* /dev/ubi* 2>&1
        echo '### mounts';       cat /proc/mounts
        echo '### df';           df
        echo '### ubinfo';       ubinfo -a 2>&1
        echo '### mtd sysfs'
        for d in /sys/class/mtd/mtd*; do
            echo "$d name=$(cat "$d/name" 2>/dev/null) dev=$(cat "$d/dev" 2>/dev/null) size=$(cat "$d/size" 2>/dev/null) erase=$(cat "$d/erasesize" 2>/dev/null) write=$(cat "$d/writesize" 2>/dev/null)"
        done
        echo '### interfaces';   ifconfig -a 2>&1
    } > ex20v-info.txt 2>&1
    upload ex20v-info.txt info.txt || die 'info.txt gonderilemedi'
    rm -f ex20v-info.txt

    : > ex20v-md5.txt
    for n in 0 1 2 3 4 5 7 8; do
        src="$(make_char_device "$n" "/tmp/ex20v-mtd$n")" || die "mtd$n cihaz dosyasi olusturulamadi"
        name="$(tr -d '\n' < "/sys/class/mtd/mtd$n/name" 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"
        file="mtd${n}_${name}.bin"
        say "okunuyor: mtd$n -> $file"
        dd if="$src" of="$file" bs=4096 2>/tmp/ex20v-dd-error || die "mtd$n okunamadi: $(cat /tmp/ex20v-dd-error)"
        md5sum "$file" >> ex20v-md5.txt
        upload "$file" "$file" || die "$file gonderilemedi"
        rm -f "$file" "/tmp/ex20v-mtd$n"
    done
    upload ex20v-md5.txt md5.txt || die 'md5.txt gonderilemedi'
    rm -f ex20v-md5.txt /tmp/ex20v-dd-error

    say 'reserve_area yedegi aliniyor (yaklasik 368 MiB)...'
    src="$(make_char_device 10 /tmp/ex20v-mtd10)" || die 'mtd10 cihaz dosyasi olusturulamadi'
    : > ex20v-reserve-md5.txt
    i=0; part=0; total=1474; chunk=128
    while [ "$i" -lt "$total" ]; do
        count=$chunk
        [ $((i+count)) -gt "$total" ] && count=$((total-i))
        file="$(printf 'reserve_%02d.bin' "$part")"
        say "okunuyor: $file (blok $i, $count blok)"
        dd if="$src" of="$file" bs=$BS skip="$i" count="$count" 2>/dev/null || die "$file okunamadi"
        [ "$(wc -c < "$file")" -eq $((count*BS)) ] || die "$file eksik okundu"
        md5sum "$file" >> ex20v-reserve-md5.txt
        upload "$file" "$file" || die "$file gonderilemedi"
        rm -f "$file"
        i=$((i+count)); part=$((part+1))
    done
    upload ex20v-reserve-md5.txt reserve_md5.txt || die 'reserve_md5.txt gonderilemedi'
    rm -f ex20v-reserve-md5.txt /tmp/ex20v-mtd10
}

prepare_rescue() {
    [ -n "$PC" ] || die 'PC IP adresi verilmedi'
    require_ex20v_layout
    [ "$(environment)" = stock ] || die 'bu adim stok firmware uzerinde calistirilmalidir'
    [ "$(root_dev)" = '31:8' ] || die 'stok sistem slot B uzerinden calismiyor; once menuden slot B secilip cihaz yeniden baslatilmali'
    [ "$(stock_flag)" = '1' ] || die 'bootflag slot B (1) degil'

    cd /tmp || die '/tmp acilamadi'
    image=ex20v-rescue.bin
    fetch "$image" "$image" || die "$image PCden indirilemedi"
    size="$(wc -c < "$image")"
    [ "$size" -gt 1048576 ] && [ "$size" -le 6291456 ] || die 'rescue imaji boyutu gecersiz'
    magic="$(head -c 4 "$image" | hexdump -v -e '4/1 "%02x"')"
    entry="$(dd if="$image" bs=1 skip=108 count=4 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
    [ "$magic" = 03000003 ] || die 'rescue imajinda TP-Link basligi yok'
    [ "$entry" = 00200080 ] || die 'rescue imaji giris adresi beklenmedik'

    pad=$(( (BS-size%BS)%BS ))
    [ "$pad" -eq 0 ] || dd if=/dev/zero bs="$pad" count=1 2>/dev/null | tr '\000' '\377' >> "$image"
    blocks=$(( $(wc -c < "$image")/BS ))
    say "rescue slot A'ya yaziliyor ($blocks blok)..."
    dd if="$image" of=/dev/mtdblock4 bs=$BS count="$blocks" conv=notrunc 2>/dev/null || die 'slot A yazilamadi'
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    expected="$(md5sum < "$image" | cut -c1-32)"
    actual="$(dd if=/dev/mtd4 bs=$BS count="$blocks" 2>/dev/null | md5sum | cut -c1-32)"
    [ "$expected" = "$actual" ] || die 'rescue yazma dogrulamasi basarisiz; yeniden baslatmayin'
    say 'rescue imaji DOGRULANDI'
    rm -f "$image"

    set_stock_flag 0
    say "bootflag='0' DOGRULANDI"
}

install_main() {
    [ -n "$PC" ] || die 'PC IP adresi verilmedi'
    is_openwrt || die 'cihaz EX20v v2 OpenWrt olarak taninmadi'
    case "$(root_fs)" in rootfs|tmpfs|ramfs) ;; *) die 'rescue (initramfs) sistemi calismiyor' ;; esac
    for tool in ubiformat ubiattach ubidetach mtd; do need "$tool"; done

    kp="$(mtdn kernel)"; up="$(mtdn ubi)"; fp="$(mtdn bootflag)"
    [ -n "$kp" ] && [ -n "$up" ] && [ -n "$fp" ] || die 'kernel/ubi/bootflag bolumleri bulunamadi'
    say "kernel=$kp ubi=$up bootflag=$fp"
    cd /tmp || die '/tmp acilamadi'
    rm -f ex20v-md5.txt ex20v-kernel.bin ex20v-ubi.bin

    fetch ex20v-md5.txt md5.txt || die 'yedegin md5.txt dosyasi indirilemedi'
    stock_k="$(grep 'mtd7_kernel_2.bin' ex20v-md5.txt | cut -c1-32)"
    stock_r="$(grep 'mtd8_rootfs_2.bin' ex20v-md5.txt | cut -c1-32)"
    [ "${#stock_k}" -eq 32 ] && [ "${#stock_r}" -eq 32 ] || die 'md5.txt icinde mtd7/mtd8 kayitlari yok'

    say '0/3 NAND bad-block esleme kontrolu...'
    current_k="$(dd if="/dev/$kp" bs=$BS count=24 2>/dev/null | md5sum | cut -c1-32)"
    entry="$(dd if="/dev/$kp" bs=1 skip=108 count=4 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
    if [ "$current_k" = "$stock_k" ]; then
        current_r="$(dd if="/dev/$up" bs=$BS count=128 2>/dev/null | md5sum | cut -c1-32)"
        [ "$current_r" = "$stock_r" ] || die 'slot B kernel uyumlu fakat rootfs_2 yedekle uyusmuyor; hicbir sey yazilmadi'
        say 'slot B stok yedekle uyumlu'
    elif [ "$entry" = 00200080 ]; then
        say 'slot B zaten OpenWrt iceriyor; yeniden kurulum devam ediyor'
    else
        die 'slot B ham okuma cihaz yedegiyle uyusmuyor; bad-block kaymasi olabilir'
    fi

    fetch ex20v-kernel.bin ex20v-kernel.bin || die 'ex20v-kernel.bin indirilemedi'
    fetch ex20v-ubi.bin ex20v-ubi.bin || die 'ex20v-ubi.bin indirilemedi'
    kernel_size="$(wc -c < ex20v-kernel.bin)"; ubi_size="$(wc -c < ex20v-ubi.bin)"
    [ "$kernel_size" -gt 1048576 ] && [ "$kernel_size" -le 6291456 ] || die 'kernel boyutu gecersiz'
    [ "$ubi_size" -gt 1048576 ] || die 'UBI imaji boyutu gecersiz'
    [ "$(head -c 4 ex20v-kernel.bin | hexdump -v -e '4/1 "%02x"')" = 03000003 ] || die 'kernel TP-Link basligi gecersiz'
    [ "$(head -c 4 ex20v-ubi.bin)" = 'UBI#' ] || die 'rootfs dosyasi UBI imaji degil'

    say "1/3 kernel slot B'ye yaziliyor..."
    mtd write ex20v-kernel.bin kernel || die 'kernel yazilamadi; bootflag degistirilmedi'
    expected="$(md5sum < ex20v-kernel.bin | cut -c1-32)"
    actual="$(dd if="/dev/$kp" bs="$kernel_size" count=1 2>/dev/null | md5sum | cut -c1-32)"
    [ "$expected" = "$actual" ] || die 'kernel dogrulanamadi; bootflag degistirilmedi'
    say 'kernel DOGRULANDI'

    say '2/3 UBI rootfs yaziliyor...'
    ubidetach -p "/dev/$up" >/dev/null 2>&1 || true
    ubiformat "/dev/$up" -y -f ex20v-ubi.bin || die 'UBI yazilamadi; bootflag degistirilmedi'
    if ubiattach -p "/dev/$up" >/dev/null 2>&1; then
        ubinfo -a | grep -E 'Name|Size' || true
        ubidetach -p "/dev/$up" >/dev/null 2>&1 || true
    fi
    say 'UBI YAZILDI'

    say "3/3 bootflag slot B'ye aliniyor..."
    set_openwrt_flag 1
    rm -f ex20v-md5.txt ex20v-kernel.bin ex20v-ubi.bin
    say "bootflag='1' DOGRULANDI"
}

backup_hash() {
    manifest="$1"; name="$2"
    awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$manifest"
}

fetch_checked() {
    name="$1"; manifest="$2"; out="$RESTORE_DIR/$name"
    expected="$(backup_hash "$manifest" "$name")"
    [ "${#expected}" -eq 32 ] || die "$name MD5 kaydi bulunamadi"
    rm -f "$out"
    fetch "$out" "$name" || die "$name indirilemedi"
    actual="$(md5sum < "$out" | cut -c1-32)"
    [ "$actual" = "$expected" ] || die "$name indirme dogrulamasi basarisiz"
}

require_same_backup_device() {
    manifest="$1"
    rom="$(mtdn romfile)"; radio="$(mtdn radio)"
    [ -n "$rom" ] && [ -n "$radio" ] || die 'romfile/radio bolumleri bulunamadi'
    expected_rom="$(backup_hash "$manifest" mtd1_romfile.bin)"
    expected_radio="$(backup_hash "$manifest" mtd3_radio.bin)"
    [ "${#expected_rom}" -eq 32 ] && [ "${#expected_radio}" -eq 32 ] || die 'cihaz kimlik MD5 kayitlari eksik'
    actual_rom="$(md5sum < "/dev/$rom" | cut -c1-32)"
    actual_radio="$(md5sum < "/dev/$radio" | cut -c1-32)"
    [ "$actual_rom" = "$expected_rom" ] || die 'yedek baska cihaza ait (romfile uyusmuyor)'
    [ "$actual_radio" = "$expected_radio" ] || die 'yedek baska cihaza ait (radio uyusmuyor)'
    say 'Yedek cihaz kimligi DOGRULANDI'
}

restore_stock() {
    [ -n "$PC" ] || die 'PC IP adresi verilmedi'
    is_openwrt || die 'stok geri yukleme yalnizca rescue OpenWrt uzerinde baslatilabilir'
    case "$(root_fs)" in rootfs|tmpfs|ramfs) ;; *) die 'rescue (initramfs) sistemi calismiyor' ;; esac
    [ "$(openwrt_flag)" = 0 ] || die "bootflag rescue slotunda (0) degil; hicbir sey yazilmadi"
    for tool in mtd ubidetach md5sum; do need "$tool"; done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die 'curl veya wget komutu bulunamadi'

    kp="$(mtdn kernel)"; up="$(mtdn ubi)"; fp="$(mtdn bootflag)"
    [ -n "$kp" ] && [ -n "$up" ] && [ -n "$fp" ] || die 'kernel/ubi/bootflag bolumleri bulunamadi'
    [ "$(cat "/sys/class/mtd/$kp/size")" = 6291456 ] || die 'kernel bolumu boyutu beklenmedik'
    [ "$(cat "/sys/class/mtd/$up/size")" = 419954688 ] || die 'ubi bolumu boyutu beklenmedik'
    RESTORE_DIR="$(select_restore_dir 40000)" || die 'geri yukleme icin en az 40 MiB kullanilabilir RAM alani gerekir; hicbir sey yazilmadi'
    say "Gecici RAM alani: $RESTORE_DIR"
    cd "$RESTORE_DIR" || die 'gecici calisma dizini acilamadi'
    rm -f stock-md5.txt reserve-md5.txt mtd7_kernel_2.bin mtd8_rootfs_2.bin reserve_??.bin
    fetch stock-md5.txt md5.txt || die 'md5.txt indirilemedi'
    fetch reserve-md5.txt reserve_md5.txt || die 'reserve_md5.txt indirilemedi'
    require_same_backup_device stock-md5.txt
    [ "$(grep -c 'reserve_[0-9][0-9]\.bin' reserve-md5.txt)" -eq 12 ] || die 'reserve manifesti 12 parca icermiyor'
    ubidetach -p "/dev/$up" >/dev/null 2>&1 || true

    say '1/3 reserve_area geri yukleniyor...'
    i=0
    while [ "$i" -lt 12 ]; do
        name="$(printf 'reserve_%02d.bin' "$i")"
        count=128; [ "$i" -eq 11 ] && count=66
        skip=$((128 + i * 128))
        fetch_checked "$name" reserve-md5.txt
        [ "$(wc -c < "$RESTORE_DIR/$name")" -eq $((count * BS)) ] || die "$name boyutu gecersiz"
        mtd -p $((skip * BS)) write "$RESTORE_DIR/$name" ubi >/dev/null || die "$name yazilamadi; rescue korunuyor"
        expected="$(backup_hash reserve-md5.txt "$name")"
        actual="$(dd if="/dev/$up" bs=$BS skip="$skip" count="$count" 2>/dev/null | md5sum | cut -c1-32)"
        [ "$actual" = "$expected" ] || die "$name yazma dogrulamasi basarisiz; rescue korunuyor"
        rm -f "$RESTORE_DIR/$name"
        say "DOGRULANDI: $name"
        i=$((i + 1))
    done

    say '2/3 stok rootfs_2 geri yukleniyor...'
    fetch_checked mtd8_rootfs_2.bin stock-md5.txt
    [ "$(wc -c < mtd8_rootfs_2.bin)" -eq 33554432 ] || die 'rootfs_2 boyutu gecersiz'
    mtd -p 0 write mtd8_rootfs_2.bin ubi >/dev/null || die 'rootfs_2 yazilamadi; rescue korunuyor'
    expected="$(backup_hash stock-md5.txt mtd8_rootfs_2.bin)"
    actual="$(dd if="/dev/$up" bs=$BS count=128 2>/dev/null | md5sum | cut -c1-32)"
    [ "$actual" = "$expected" ] || die 'rootfs_2 dogrulanamadi; rescue korunuyor'
    rm -f mtd8_rootfs_2.bin
    say 'rootfs_2 DOGRULANDI'

    say '3/3 stok kernel_2 geri yukleniyor...'
    fetch_checked mtd7_kernel_2.bin stock-md5.txt
    [ "$(wc -c < mtd7_kernel_2.bin)" -eq 6291456 ] || die 'kernel_2 boyutu gecersiz'
    mtd write mtd7_kernel_2.bin kernel >/dev/null || die 'kernel_2 yazilamadi; rescue korunuyor'
    expected="$(backup_hash stock-md5.txt mtd7_kernel_2.bin)"
    actual="$(dd if="/dev/$kp" bs=$BS count=24 2>/dev/null | md5sum | cut -c1-32)"
    [ "$actual" = "$expected" ] || die 'kernel_2 dogrulanamadi; rescue korunuyor'
    rm -f mtd7_kernel_2.bin
    sync

    set_openwrt_flag 1
    rm -f stock-md5.txt reserve-md5.txt
    cd /
    rmdir "$RESTORE_DIR" 2>/dev/null || true
    say "bootflag='1' DOGRULANDI; rescue slot A korunuyor"
}

restore_stock_finalize() {
    [ -n "$PC" ] || die 'PC IP adresi verilmedi'
    require_ex20v_layout
    [ "$(environment)" = stock ] || die 'tamamlama yalnizca stok firmware uzerinde yapilabilir'
    [ "$(root_dev)" = '31:8' ] || die 'stok sistem slot B uzerinden calismiyor; hicbir sey yazilmadi'
    [ "$(stock_flag)" = 1 ] || die "bootflag slot B (1) degil; hicbir sey yazilmadi"
    need dd; need md5sum
    RESTORE_DIR="$(select_restore_dir 42000)" || die 'geri yukleme icin en az 42 MiB kullanilabilir RAM alani gerekir; hicbir sey yazilmadi'
    say "Gecici RAM alani: $RESTORE_DIR"
    cd "$RESTORE_DIR" || die 'gecici calisma dizini acilamadi'
    rm -f stock-md5.txt mtd4_kernel.bin mtd5_rootfs.bin
    fetch stock-md5.txt md5.txt || die 'md5.txt indirilemedi'
    require_same_backup_device stock-md5.txt
    fetch_checked mtd5_rootfs.bin stock-md5.txt
    fetch_checked mtd4_kernel.bin stock-md5.txt
    [ "$(wc -c < mtd5_rootfs.bin)" -eq 33554432 ] || die 'slot A rootfs boyutu gecersiz'
    [ "$(wc -c < mtd4_kernel.bin)" -eq 6291456 ] || die 'slot A kernel boyutu gecersiz'

    say '1/2 stok slot A rootfs geri yukleniyor...'
    dd if=mtd5_rootfs.bin of=/dev/mtdblock5 bs=$BS count=128 conv=notrunc 2>/dev/null || die 'slot A rootfs yazilamadi'
    expected="$(backup_hash stock-md5.txt mtd5_rootfs.bin)"
    actual="$(dd if=/dev/mtd5 bs=$BS count=128 2>/dev/null | md5sum | cut -c1-32)"
    [ "$actual" = "$expected" ] || die 'slot A rootfs dogrulanamadi'
    rm -f mtd5_rootfs.bin
    say 'slot A rootfs DOGRULANDI'

    say '2/2 stok slot A kernel geri yukleniyor...'
    dd if=mtd4_kernel.bin of=/dev/mtdblock4 bs=$BS count=24 conv=notrunc 2>/dev/null || die 'slot A kernel yazilamadi'
    expected="$(backup_hash stock-md5.txt mtd4_kernel.bin)"
    actual="$(dd if=/dev/mtd4 bs=$BS count=24 2>/dev/null | md5sum | cut -c1-32)"
    [ "$actual" = "$expected" ] || die 'slot A kernel dogrulanamadi'
    sync
    rm -f stock-md5.txt mtd4_kernel.bin mtd5_rootfs.bin
    cd /
    rmdir "$RESTORE_DIR" 2>/dev/null || true
    say 'slot A kernel DOGRULANDI'
}

case "$ACTION" in
    inspect)
        require_known_device
        show_slot
        ;;
    backup)
        backup_all
        ;;
    prepare-rescue)
        prepare_rescue
        ;;
    install-main)
        install_main
        ;;
    restore-stock)
        restore_stock
        ;;
    restore-stock-finalize)
        restore_stock_finalize
        ;;
    slot-show)
        require_known_device
        show_slot
        ;;
    slot-set)
        require_known_device
        set_slot "${4:-}"
        show_slot
        ;;
    reboot)
        say 'Cihaz 3 saniye icinde yeniden baslatilacak.'
        (sleep 3; /sbin/reboot) >/dev/null 2>&1 &
        ;;
    *)
        die "bilinmeyen islem: $ACTION"
        ;;
esac
'@

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host ('[OK] ' + $Text) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host ('[!]  ' + $Text) -ForegroundColor Yellow
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Confirm-Word {
    param([string]$Message, [string]$Word)
    Write-Warn $Message
    return ((Read-Host "Devam etmek icin $Word yazin") -ceq $Word)
}

function Get-SshExecutable {
    $systemSsh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    if (Test-Path -LiteralPath $systemSsh -PathType Leaf) { return $systemSsh }
    $command = Get-Command ssh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw 'Windows OpenSSH istemcisi bulunamadi. Ayarlar > Istege bagli ozellikler > OpenSSH Client kurulmalidir.'
    }
    return $command.Source
}

function Get-SshAskPassExecutable {
    if (-not (Test-Path -LiteralPath $script:StateRoot)) {
        [void](New-Item -ItemType Directory -Path $script:StateRoot -Force)
    }
    $path = Join-Path $script:StateRoot 'ex20v-password.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }

    $source = @'
using System;
internal static class Ex20vAskPass
{
    public static int Main()
    {
        string password = Environment.GetEnvironmentVariable("EX20V_SSH_PASSWORD");
        if (String.IsNullOrEmpty(password)) return 1;
        Console.WriteLine(password);
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $source -OutputAssembly $path -OutputType WindowsApplication
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'SSH parola yardimcisi olusturulamadi.'
    }
    return $path
}

function Read-SshPassword {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $secure.Dispose()
    }
    if ([string]::IsNullOrEmpty($password)) { throw 'Parola bos birakilamaz.' }
    return $password
}

function Get-LocalIPv4 {
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
        if ($nic.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        foreach ($address in $nic.GetIPProperties().UnicastAddresses) {
            if ($address.Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $ip = $address.Address.ToString()
            if ($ip -notlike '169.254.*' -and -not $result.Contains($ip)) { $result.Add($ip) }
        }
    }
    return $result.ToArray()
}

function Read-IPv4 {
    param([string]$Purpose, [string]$Preferred = '')
    $addresses = @(Get-LocalIPv4)
    if ($addresses.Count -gt 0) {
        Write-Host ('Bilgisayardaki IPv4 adresleri: ' + ($addresses -join ', ')) -ForegroundColor DarkGray
    }
    if ([string]::IsNullOrWhiteSpace($Preferred)) {
        $lanAddress = $addresses | Where-Object { $_ -like '192.168.1.*' } | Select-Object -First 1
        if ($addresses -contains '192.168.1.2') { $Preferred = '192.168.1.2' }
        elseif (-not [string]::IsNullOrWhiteSpace($lanAddress)) { $Preferred = $lanAddress }
        elseif ($addresses.Count -gt 0) { $Preferred = $addresses[0] }
        else { $Preferred = '192.168.1.2' }
    }
    while ($true) {
        $value = Read-Default $Purpose $Preferred
        $parsed = $null
        if ([Net.IPAddress]::TryParse($value, [ref]$parsed) -and
            $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
            return $value
        }
        Write-Warn 'Gecerli bir IPv4 adresi girin.'
    }
}

function Read-SshTarget {
    param([string]$Default = 'root@192.168.1.1')
    while ($true) {
        $value = Read-Default 'SSH hedefi (kullanici@IP)' $Default
        if ($value -match '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$') { return $value }
        Write-Warn 'Ornek bicim: root@192.168.1.1'
    }
}

function Get-FilePrefix {
    param([string]$Path, [int]$Count, [int]$Offset = 0)
    $stream = [IO.File]::OpenRead($Path)
    try {
        [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] $Count
        $read = $stream.Read($buffer, 0, $Count)
        if ($read -ne $Count) { throw "Dosya beklenenden kisa: $Path" }
        return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $stream.Dispose()
    }
}

function Test-ImageFiles {
    param([switch]$ShowHashes)
    Write-Section 'Firmware dosyalari denetleniyor'
    foreach ($name in $script:ImageNames) {
        $path = Join-Path $script:ImageRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Eksik dosya: $path" }
    }

    $rescue = Join-Path $script:ImageRoot 'ex20v-rescue.bin'
    $kernel = Join-Path $script:ImageRoot 'ex20v-kernel.bin'
    $ubi = Join-Path $script:ImageRoot 'ex20v-ubi.bin'
    if ((Get-Item -LiteralPath $rescue).Length -gt 6291456) { throw 'ex20v-rescue.bin 6 MiB sinirini asiyor.' }
    if ((Get-Item -LiteralPath $kernel).Length -gt 6291456) { throw 'ex20v-kernel.bin 6 MiB sinirini asiyor.' }
    foreach ($path in @($rescue, $kernel)) {
        if ((Get-FilePrefix $path 4) -ne '03000003') { throw "TP-Link basligi gecersiz: $path" }
        if ((Get-FilePrefix $path 4 108) -ne '00200080') { throw "Giris adresi gecersiz: $path" }
    }
    if ((Get-FilePrefix $ubi 4) -ne '55424923') { throw 'ex20v-ubi.bin UBI imaji degil.' }

    foreach ($name in $script:ImageNames) {
        $path = Join-Path $script:ImageRoot $name
        $item = Get-Item -LiteralPath $path
        Write-Ok ("{0} ({1:N0} bayt)" -f $name, $item.Length)
        if ($ShowHashes) {
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Host ("     SHA256: {0}" -f $hash) -ForegroundColor DarkGray
        }
    }
}

function Test-BackupDirectory {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Quiet)
    $lists = @('md5.txt', 'reserve_md5.txt')
    foreach ($listName in $lists) {
        $listPath = Join-Path $Path $listName
        if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { throw "Yedek eksik: $listPath" }
        $entryCount = 0
        foreach ($line in Get-Content -LiteralPath $listPath) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -notmatch '^([0-9a-fA-F]{32})\s+\*?(.+)$') { throw "Gecersiz MD5 kaydi: $listName" }
            $expected = $Matches[1].ToLowerInvariant()
            $name = $Matches[2].Trim()
            if ($name -ne [IO.Path]::GetFileName($name) -or $name -notmatch '^[A-Za-z0-9._-]+$') {
                throw "Gecersiz yedek dosya adi: $name"
            }
            $file = Join-Path $Path $name
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Yedek parcasi eksik: $name" }
            $actual = (Get-FileHash -LiteralPath $file -Algorithm MD5).Hash.ToLowerInvariant()
            if ($actual -ne $expected) { throw "Yedek parcasi bozuk: $name" }
            $entryCount++
        }
        $expectedCount = if ($listName -eq 'md5.txt') { 8 } else { 12 }
        if ($entryCount -ne $expectedCount) { throw "$listName kayit sayisi gecersiz: $entryCount (beklenen $expectedCount)" }
    }
    $md5Text = Get-Content -Raw -LiteralPath (Join-Path $Path 'md5.txt')
    if ($md5Text -notmatch 'mtd7_kernel_2\.bin' -or $md5Text -notmatch 'mtd8_rootfs_2\.bin') {
        throw 'Yedekte slot B kernel/rootfs kayitlari yok.'
    }
    $expectedSizes = @{
        'mtd0_boot.bin' = 262144L
        'mtd1_romfile.bin' = 1048576L
        'mtd2_config.bin' = 2097152L
        'mtd3_radio.bin' = 262144L
        'mtd4_kernel.bin' = 6291456L
        'mtd5_rootfs.bin' = 33554432L
        'mtd7_kernel_2.bin' = 6291456L
        'mtd8_rootfs_2.bin' = 33554432L
    }
    for ($i = 0; $i -lt 12; $i++) {
        $name = 'reserve_{0:00}.bin' -f $i
        $expectedSizes[$name] = if ($i -eq 11) { 17301504L } else { 33554432L }
    }
    foreach ($entry in $expectedSizes.GetEnumerator()) {
        $file = Join-Path $Path $entry.Key
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Yedek parcasi eksik: $($entry.Key)" }
        if ((Get-Item -LiteralPath $file).Length -ne $entry.Value) {
            throw "Yedek parcasi boyutu gecersiz: $($entry.Key)"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'info.txt') -PathType Leaf)) { throw 'Yedekte info.txt yok.' }
    if (-not $Quiet) { Write-Ok "Yedek butunlugu dogrulandi: $Path" }
    return $true
}

function Select-BackupDirectory {
    $candidates = @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'md5.txt') } |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) { throw 'Kullanilabilir tam yedek yok. Once ana menuden 1. adimi calistirin.' }
    Write-Host 'Bulunan yedekler:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $candidates[$i].Name)
    }
    $choice = Read-Default 'Yedek secimi' '1'
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $candidates.Count) {
        throw 'Gecersiz yedek secimi.'
    }
    $selected = $candidates[$index - 1].FullName
    [void](Test-BackupDirectory -Path $selected)
    return $selected
}

function Start-Ex20vServer {
    param(
        [Parameter(Mandatory = $true)][string]$ServeRoot,
        [Parameter(Mandatory = $true)][string]$UploadRoot
    )
    $serverCode = {
        param($Files, $Uploads, $ListenPort)
        $ErrorActionPreference = 'Stop'

        function Send-Header($Stream, [int]$Status, [string]$Reason, [long]$Length, [string]$Type = 'text/plain') {
            $text = "HTTP/1.1 $Status $Reason`r`nContent-Length: $Length`r`nContent-Type: $Type`r`nConnection: close`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($text)
            $Stream.Write($bytes, 0, $bytes.Length)
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, [int]$ListenPort)
        $listener.Start()
        Write-Output "READY:$ListenPort"
        $running = $true
        while ($running) {
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 30000
                $client.SendTimeout = 30000
                $stream = $client.GetStream()
                $headerBytes = New-Object System.Collections.Generic.List[byte]
                $tail = ''
                while ($headerBytes.Count -lt 65536 -and $tail -ne "`r`n`r`n") {
                    $value = $stream.ReadByte()
                    if ($value -lt 0) { break }
                    $headerBytes.Add([byte]$value)
                    $tail = ($tail + [char]$value)
                    if ($tail.Length -gt 4) { $tail = $tail.Substring($tail.Length - 4) }
                }
                $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
                $lines = $headerText -split "`r`n"
                $request = $lines[0] -split ' '
                if ($request.Count -lt 2) { throw 'Gecersiz HTTP istegi.' }
                $method = $request[0].ToUpperInvariant()
                $rawName = [Uri]::UnescapeDataString(($request[1] -split '\?')[0].Trim('/'))
                $name = [IO.Path]::GetFileName($rawName)
                if ($name -ne $rawName -or $name -notmatch '^[A-Za-z0-9._-]+$') { throw 'Gecersiz dosya adi.' }
                $headers = @{}
                foreach ($line in $lines[1..($lines.Count - 1)]) {
                    $separator = $line.IndexOf(':')
                    if ($separator -gt 0) { $headers[$line.Substring(0, $separator).Trim().ToLowerInvariant()] = $line.Substring($separator + 1).Trim() }
                }

                if ($method -eq 'GET' -and $name -eq '__stop__') {
                    Send-Header $stream 200 'OK' 0
                    $running = $false
                }
                elseif ($method -eq 'GET' -or $method -eq 'HEAD') {
                    $allowed = @(
                        'md5.txt', 'reserve_md5.txt', 'mtd4_kernel.bin', 'mtd5_rootfs.bin',
                        'mtd7_kernel_2.bin', 'mtd8_rootfs_2.bin', 'ex20v-rescue.bin',
                        'ex20v-kernel.bin', 'ex20v-ubi.bin', 'ex20v-v2-sysupgrade.bin'
                    )
                    if ($name -notin $allowed -and $name -notmatch '^reserve_[0-9]{2}\.bin$') {
                        Send-Header $stream 403 'Forbidden' 0
                    }
                    else {
                        $path = Join-Path $Uploads $name
                        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $path = Join-Path $Files $name }
                        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                            Send-Header $stream 404 'Not Found' 0
                        }
                        else {
                            $file = [IO.File]::OpenRead($path)
                            try {
                                Send-Header $stream 200 'OK' $file.Length 'application/octet-stream'
                                if ($method -eq 'GET') { $file.CopyTo($stream, 65536) }
                            }
                            finally { $file.Dispose() }
                            Write-Output "GET $name"
                        }
                    }
                }
                elseif ($method -eq 'PUT' -or $method -eq 'POST') {
                    if (-not $headers.ContainsKey('content-length')) {
                        Send-Header $stream 411 'Length Required' 0
                        continue
                    }
                    [long]$remaining = $headers['content-length']
                    if ($remaining -lt 0 -or $remaining -gt 536870912) { throw 'Gecersiz dosya boyutu.' }
                    if ($headers.ContainsKey('expect') -and $headers['expect'] -match '100-continue') {
                        $interim = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                        $stream.Write($interim, 0, $interim.Length)
                    }
                    $part = Join-Path $Uploads ($name + '.part')
                    $output = [IO.File]::Create($part)
                    try {
                        $buffer = New-Object byte[] 65536
                        while ($remaining -gt 0) {
                            $read = $stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
                            if ($read -le 0) { throw 'Baglanti dosya tamamlanmadan kesildi.' }
                            $output.Write($buffer, 0, $read)
                            $remaining -= $read
                        }
                    }
                    finally { $output.Dispose() }
                    Move-Item -LiteralPath $part -Destination (Join-Path $Uploads $name) -Force
                    Send-Header $stream 201 'Created' 0
                    Write-Output "PUT $name"
                }
                else {
                    Send-Header $stream 405 'Method Not Allowed' 0
                }
            }
            catch {
                try { Send-Header $stream 500 'Server Error' 0 } catch {}
                Write-Error $_
            }
            finally {
                if ($null -ne $client) { $client.Dispose() }
            }
        }
        $listener.Stop()
    }

    $job = Start-Job -ScriptBlock $serverCode -ArgumentList $ServeRoot, $UploadRoot, $Port
    $ready = $false
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Milliseconds 100
        $messages = @(Receive-Job -Job $job)
        if ($messages -match '^READY:') { $ready = $true; break }
        if ($job.State -in @('Failed', 'Completed', 'Stopped')) { break }
    }
    if (-not $ready) {
        $details = (Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-String).Trim()
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "HTTP sunucusu $Port portunda baslatilamadi. $details"
    }
    Write-Ok "Dosya sunucusu 0.0.0.0:$Port adresinde hazir."
    return $job
}

function Stop-Ex20vServer {
    param($Job)
    if ($null -eq $Job) { return }
    try {
        $client = [Net.WebClient]::new()
        [void]$client.DownloadData("http://127.0.0.1:$Port/__stop__")
        $client.Dispose()
        [void](Wait-Job -Job $Job -Timeout 5)
    }
    catch {}
    $messages = @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)
    foreach ($message in $messages) { Write-Host ('  HTTP: ' + $message) -ForegroundColor DarkGray }
    Stop-Job -Job $Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}

function Start-Ex20vTftpServer {
    param([Parameter(Mandatory = $true)][string]$UploadRoot)
    if ($null -eq ('Ex20vTftpReceiver' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public sealed class Ex20vTftpReceiver : IDisposable
{
    private readonly string root;
    private readonly UdpClient udp;
    private readonly Thread worker;
    private readonly object gate = new object();
    private readonly List<string> messages = new List<string>();
    private volatile bool stopping;

    public Ex20vTftpReceiver(string uploadRoot, int port)
    {
        root = Path.GetFullPath(uploadRoot);
        udp = new UdpClient(port);
        udp.Client.ReceiveTimeout = 1000;
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Name = "EX20v TFTP receiver";
        worker.Start();
    }

    private void Log(string value) { lock (gate) messages.Add(value); }

    public string[] DrainMessages()
    {
        lock (gate) { string[] result = messages.ToArray(); messages.Clear(); return result; }
    }

    private static byte[] Ack(byte high, byte low) { return new byte[] { 0, 4, high, low }; }

    private void Run()
    {
        while (!stopping)
        {
            try
            {
                IPEndPoint peer = new IPEndPoint(IPAddress.Any, 0);
                byte[] request = udp.Receive(ref peer);
                if (request.Length < 4 || request[0] != 0 || request[1] != 2) continue;
                ReceiveFile(request, peer);
            }
            catch (SocketException ex)
            {
                if (!stopping && ex.SocketErrorCode != SocketError.TimedOut) Log("HATA: " + ex.Message);
            }
            catch (ObjectDisposedException) { if (!stopping) throw; }
            catch (Exception ex) { if (!stopping) Log("HATA: " + ex.Message); }
        }
    }

    private void ReceiveFile(byte[] request, IPEndPoint peer)
    {
        string[] fields = Encoding.ASCII.GetString(request, 2, request.Length - 2).Split('\0');
        if (fields.Length < 2) return;
        string name = Path.GetFileName(fields[0]);
        if (name != fields[0] || !Regex.IsMatch(name, "^[A-Za-z0-9._-]+$")) return;

        int blockSize = 512;
        bool hasBlockSize = false;
        for (int i = 2; i + 1 < fields.Length; i += 2)
        {
            if (!fields[i].Equals("blksize", StringComparison.OrdinalIgnoreCase)) continue;
            int requested;
            if (Int32.TryParse(fields[i + 1], out requested)) blockSize = Math.Max(512, Math.Min(1468, requested));
            hasBlockSize = true;
        }

        byte[] reply;
        if (hasBlockSize)
        {
            byte[] option = Encoding.ASCII.GetBytes("blksize\0" + blockSize + "\0");
            reply = new byte[option.Length + 2]; reply[1] = 6; Buffer.BlockCopy(option, 0, reply, 2, option.Length);
        }
        else reply = Ack(0, 0);
        udp.Send(reply, reply.Length, peer);

        string part = Path.Combine(root, name + ".part");
        string target = Path.Combine(root, name);
        int expected = 1, timeouts = 0;
        try
        {
            using (FileStream output = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 65536))
            {
                while (!stopping)
                {
                    try
                    {
                        IPEndPoint sender = new IPEndPoint(IPAddress.Any, 0);
                        byte[] packet = udp.Receive(ref sender);
                        if (!sender.Equals(peer) || packet.Length < 4 || packet[0] != 0 || packet[1] != 3) continue;
                        int block = (packet[2] << 8) | packet[3];
                        if (block == expected)
                        {
                            int length = packet.Length - 4;
                            if (length > 0) output.Write(packet, 4, length);
                            byte[] ack = Ack(packet[2], packet[3]); udp.Send(ack, ack.Length, peer);
                            expected = (expected + 1) & 0xffff; timeouts = 0;
                            if (length < blockSize) break;
                        }
                        else if (block == ((expected - 1) & 0xffff))
                        {
                            byte[] ack = Ack(packet[2], packet[3]); udp.Send(ack, ack.Length, peer);
                        }
                    }
                    catch (SocketException ex)
                    {
                        if (ex.SocketErrorCode != SocketError.TimedOut || ++timeouts >= 30) throw;
                    }
                }
            }
            if (stopping) { File.Delete(part); return; }
            if (File.Exists(target)) File.Delete(target);
            File.Move(part, target);
            Log("PUT " + name);
        }
        catch { try { File.Delete(part); } catch { } throw; }
    }

    public void Dispose()
    {
        stopping = true;
        udp.Close();
        worker.Join(3000);
    }
}
'@
    }
    $server = [Ex20vTftpReceiver]::new($UploadRoot, $Port)
    Write-Ok "Yedek sunucusu 0.0.0.0:$Port/UDP adresinde hazir."
    return $server
}

function Stop-Ex20vTftpServer {
    param($Server)
    if ($null -eq $Server) { return }
    $messages = @($Server.DrainMessages())
    foreach ($message in $messages) { Write-Host ('  TFTP: ' + $message) -ForegroundColor DarkGray }
    $Server.Dispose()
}

function Invoke-RemoteAgentSession {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z-]+$')][string]$Action,
        [string]$PcIp = '127.0.0.1',
        [string]$Extra = '',
        [ValidateSet('stock', 'rescue', 'main')][string]$HostKeyGroup = 'main',
        [AllowEmptyString()][string]$LoginPassword = '',
        [AllowEmptyString()][string]$SecondaryPassword = ''
    )
    $ssh = Get-SshExecutable
    if ($Target -notmatch '^[A-Za-z0-9._-]+@([A-Za-z0-9._-]+)$') {
        throw 'SSH hedefi kullanici@IP biciminde olmalidir.'
    }
    if ($HostKeyGroup -eq 'stock') {
        $Target = $script:StockUser + '@' + $Matches[1]
    }
    if (-not (Test-Path -LiteralPath $script:StateRoot)) { [void](New-Item -ItemType Directory -Path $script:StateRoot -Force) }
    $knownHosts = Join-Path $script:StateRoot ("known_hosts_{0}" -f $HostKeyGroup)
    # The vendor firmware and initramfs rescue can generate a new host key on
    # each boot. Their dedicated cache must not block the next local recovery
    # session; the installed main OpenWrt key remains pinned normally.
    if ($HostKeyGroup -in @('stock', 'rescue') -and (Test-Path -LiteralPath $knownHosts)) {
        Remove-Item -LiteralPath $knownHosts -Force
    }
    if (-not (Test-Path -LiteralPath $knownHosts)) { [void](New-Item -ItemType File -Path $knownHosts -Force) }
    $sshArgs = @(
        '-tt',
        '-o', 'ConnectTimeout=12',
        '-o', 'ServerAliveInterval=15',
        '-o', 'LogLevel=ERROR',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$knownHosts"
    )
    if ($HostKeyGroup -eq 'stock') {
        # The vendor firmware only offers the legacy ssh-rsa host-key type.
        # Keep this exception scoped to stock; rescue/main OpenWrt use defaults.
        $sshArgs += @(
            '-o', 'HostKeyAlgorithms=+ssh-rsa',
            '-o', 'PubkeyAuthentication=no'
        )
    }
    if ([string]::IsNullOrEmpty($LoginPassword)) {
        $sshArgs += @(
            '-o', 'BatchMode=yes',
            '-o', 'NumberOfPasswordPrompts=0'
        )
    }
    else {
        $sshArgs += @(
            '-o', 'BatchMode=no',
            '-o', 'PasswordAuthentication=yes',
            '-o', 'KbdInteractiveAuthentication=yes',
            '-o', 'PreferredAuthentications=password,keyboard-interactive',
            '-o', 'NumberOfPasswordPrompts=1'
        )
    }
    $sshArgs += $Target

    $agentBytes = [Text.UTF8Encoding]::new($false).GetBytes($script:RemoteAgent)
    $shellUser = ''
    $shellPassword = $SecondaryPassword
    Write-Host "SSH baglantisi: $Target" -ForegroundColor Cyan
    $writeSshLine = {
        param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
        $oldColor = [Console]::ForegroundColor
        try {
            [Console]::ForegroundColor = $Color
            if ([Console]::IsOutputRedirected) {
                [Console]::WriteLine($Text)
            }
            else {
                [Console]::Write("`r{0}`r`n", $Text)
            }
        }
        finally {
            [Console]::ForegroundColor = $oldColor
        }
    }
    $process = $null
    $errorTask = $null
    $sshError = ''
    $captured = [Text.StringBuilder]::new()
    $linuxShellConfirmed = $false
    $sessionCompleted = $false
    try {
        $quotedArgs = foreach ($argument in $sshArgs) {
            if ($argument -match '[\s"]') { '"' + $argument.Replace('"', '\"') + '"' } else { $argument }
        }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $ssh
        $startInfo.Arguments = $quotedArgs -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $false
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        if (-not [string]::IsNullOrEmpty($LoginPassword)) {
            $startInfo.EnvironmentVariables['SSH_ASKPASS'] = Get-SshAskPassExecutable
            $startInfo.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
            $startInfo.EnvironmentVariables['DISPLAY'] = 'ex20v-password-login'
            $startInfo.EnvironmentVariables['EX20V_SSH_PASSWORD'] = $LoginPassword
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'SSH istemcisi baslatilamadi.' }
        $errorTask = $process.StandardError.ReadToEndAsync()
        $standardInput = $process.StandardInput
        # StreamWriter.BaseStream calls Flush(), which otherwise writes a UTF-8
        # BOM before the first SSH byte on Windows PowerShell 5.1. Newer .NET
        # versions already use BOM-less UTF-8, so only patch the legacy writer.
        if ($standardInput.Encoding.GetPreamble().Length -gt 0) {
            $flags = [Reflection.BindingFlags]'Instance,NonPublic'
            $preambleField = [IO.StreamWriter].GetField('haveWrittenPreamble', $flags)
            if ($null -eq $preambleField) {
                $preambleField = [IO.StreamWriter].GetField('_haveWrittenPreamble', $flags)
            }
            if ($null -eq $preambleField) { throw 'PowerShell SSH giris kodlamasi ayarlanamadi.' }
            $preambleField.SetValue($standardInput, $true)
        }
        $inputStream = $standardInput.BaseStream
        $inputEncoding = [Text.UTF8Encoding]::new($false)
        $sendLine = {
            param([string]$Text)
            $bytes = $inputEncoding.GetBytes($Text + "`n")
            $inputStream.Write($bytes, 0, $bytes.Length)
            $inputStream.Flush()
        }
        if ($HostKeyGroup -eq 'stock') {
            $state = 'detect-shell'
            & $sendLine ''
        }
        else {
            $state = 'wait-shell'
            & $sendLine ''
        }

        $window = ''
        $stateStarted = [DateTime]::MinValue
        $buffer = New-Object char[] 512
        $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
        while ($true) {
            if ($readTask.Wait(100)) {
                $count = $readTask.Result
                if ($count -eq 0) { break }
                $chunk = [string]::new($buffer, 0, $count)
                $window += $chunk
                if ($window.Length -gt 4096) { $window = $window.Substring($window.Length - 4096) }
                if ($stateStarted -eq [DateTime]::MinValue) { $stateStarted = [DateTime]::UtcNow }

                # Do not display the bytes immediately following the secondary
                # password or the agent transfer. Some stock builds cannot turn
                # terminal echo off, so transfer output is hidden locally too.
                if ($state -notin @(
                    'detect-shell', 'wait-user', 'wait-password', 'wait-shell', 'wait-ready',
                    'transfer-init', 'transfer-chunk',
                    'starting-agent', 'wait-clean', 'finishing'
                )) {
                    $safeChunk = $chunk
                    if (-not [string]::IsNullOrEmpty($shellPassword)) {
                        $safeChunk = $safeChunk.Replace($shellPassword, '********')
                    }
                    [void]$captured.Append($safeChunk)
                    $displayChunk = $safeChunk `
                        -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '' `
                        -replace 'EX20V_SHELL_READY\r?\n?', '' `
                        -replace 'EX20V_SHELL=LINUX\r?\n?', '' `
                        -replace '(?m)^/var/tmp/dropbear #[ \t]*', '' `
                        -replace '__EX20V_RC=[0-9]+\r?\n?', ''
                    $displayChunk = [regex]::Replace($displayChunk, '(?<!\r)\n', "`r`n")
                    if ($displayChunk.Length -gt 0) { Write-Host -NoNewline $displayChunk }
                }

                $plainWindow = $window -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''
                switch ($state) {
                    'detect-shell' {
                        if ($plainWindow -match '(?is)(TP-Link|COMMAND-LINE Interface).*[>#]\s*$') {
                            & $writeSshLine 'TP-Link komut arayuzu algilandi; shell aciliyor.' DarkGray
                            & $sendLine 'shell'
                            $window = ''
                            $state = 'wait-user'
                            $stateStarted = [DateTime]::UtcNow
                        }
                        elseif ($plainWindow -match '(?m)[#$]\s*$') {
                            & $writeSshLine 'SSH oturumu zaten Linux shell acmis; ikinci giris atlandi.' DarkGray
                            & $sendLine "stty -echo 2>/dev/null || true; printf '%s%s\n' 'EX20V_' 'SHELL_READY'"
                            $window = ''
                            $state = 'wait-ready'
                            $stateStarted = [DateTime]::UtcNow
                        }
                    }
                    'wait-user' {
                        if ($plainWindow -match '(?i)(user\s*name|username|login|kullanici(?:\s+adi)?|user)\s*[:>]\s*$') {
                            $shellUser = $script:StockUser
                            & $sendLine $shellUser
                            $window = ''
                            $state = 'wait-password'
                            $stateStarted = [DateTime]::UtcNow
                        }
                    }
                    'wait-password' {
                        if ($plainWindow -match '(?i)(password|passwd|parola|sifre)\s*[:>]\s*$') {
                            & $sendLine $shellPassword
                            $window = ''
                            $state = 'wait-shell'
                            $stateStarted = [DateTime]::UtcNow
                        }
                    }
                    'wait-shell' {
                        if ($plainWindow -match '(?i)(incorrect|denied|authentication\s+failed|login\s+failed|hatali|yanlis|username\s*:\s*$|password\s*:\s*$)') {
                            $authError = [Security.Authentication.AuthenticationException]::new('Shell sonrasi Linux parolasi reddedildi.')
                            $authError.Data['EX20V_STAGE'] = 'shell'
                            throw $authError
                        }
                        if ($plainWindow -match '(?m)[#$]\s*$') {
                            & $sendLine "stty -echo 2>/dev/null || true; printf '%s%s\n' 'EX20V_' 'SHELL_READY'"
                            $window = ''
                            $state = 'wait-ready'
                            $stateStarted = [DateTime]::UtcNow
                        }
                    }
                    'wait-ready' {
                        if ($plainWindow -match 'EX20V_SHELL_READY') {
                            & $writeSshLine '[OK] Linux shell acildi ve dogrulandi.' Green
                            $transferParts = [Collections.Generic.List[string]]::new()
                            for ($offset = 0; $offset -lt $agentBytes.Length; $offset += 12) {
                                $length = [Math]::Min(12, $agentBytes.Length - $offset)
                                $octal = ''
                                for ($index = $offset; $index -lt ($offset + $length); $index++) {
                                    $octal += '\' + [Convert]::ToString($agentBytes[$index], 8).PadLeft(3, '0')
                                }
                                $transferParts.Add($octal)
                            }
                            $transferIndex = 0
                            & $sendLine 'rm -f /tmp/x'
                            $window = ''
                            $state = 'transfer-init'
                            $stateStarted = [DateTime]::UtcNow
                        }
                    }
                    'transfer-init' {
                        if ($plainWindow -match '(?m)[#$]\s*$') {
                            $batchCount = 0
                            while ($transferIndex -lt $transferParts.Count -and $batchCount -lt 4) {
                                & $sendLine ("printf '$($transferParts[$transferIndex])'>>/tmp/x")
                                $transferIndex++
                                $batchCount++
                            }
                            $window = ''
                            $state = 'transfer-chunk'
                            $stateStarted = [DateTime]::UtcNow
                        }
                    }
                    'transfer-chunk' {
                        if ($plainWindow -match '(?m)[#$]\s*$') {
                            if ($transferIndex -lt $transferParts.Count) {
                                $batchCount = 0
                                while ($transferIndex -lt $transferParts.Count -and $batchCount -lt 4) {
                                    & $sendLine ("printf '$($transferParts[$transferIndex])'>>/tmp/x")
                                    $transferIndex++
                                    $batchCount++
                                }
                                $window = ''
                                $stateStarted = [DateTime]::UtcNow
                            }
                            else {
                                $agentExtra = if ([string]::IsNullOrEmpty($Extra)) { 'x' } else { $Extra }
                                & $sendLine "sh /tmp/x $Action $PcIp $Port $agentExtra;r=`$?;echo __EX20V_RC=`$r"
                                $window = ''
                                $state = 'starting-agent'
                                $stateStarted = [DateTime]::UtcNow
                            }
                        }
                    }
                    'starting-agent' {
                        $marker = 'EX20V_SHELL=LINUX'
                        $markerIndex = $window.IndexOf($marker, [StringComparison]::Ordinal)
                        if ($markerIndex -ge 0) {
                            $linuxShellConfirmed = $true
                            $remainder = $window.Substring($markerIndex + $marker.Length) -replace '^\r?\n', ''
                            if ($remainder.Length -gt 0) {
                                [void]$captured.Append($remainder)
                                $displayRemainder = $remainder `
                                    -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '' `
                                    -replace '(?m)^/var/tmp/dropbear #[ \t]*', '' `
                                    -replace '__EX20V_RC=[0-9]+\r?\n?', ''
                                $displayRemainder = [regex]::Replace($displayRemainder, '(?<!\r)\n', "`r`n")
                                if ($displayRemainder.Length -gt 0) {
                                    if (-not [Console]::IsOutputRedirected) { [Console]::Write("`r") }
                                    Write-Host -NoNewline $displayRemainder
                                }
                            }
                            $window = $remainder
                            $state = 'running'
                            $stateStarted = [DateTime]::MinValue
                            if ($remainder -match '__EX20V_RC=[0-9]+') {
                                & $sendLine "rm -f /tmp/x;printf '%s%s\n' 'EX20V_' 'CLEAN'"
                                $window = ''
                                $state = 'wait-clean'
                                $stateStarted = [DateTime]::UtcNow
                            }
                        }
                    }
                    'running' {
                        if ($plainWindow -match '__EX20V_RC=[0-9]+') {
                            & $sendLine "rm -f /tmp/x;printf '%s%s\n' 'EX20V_' 'CLEAN'"
                            $window = ''
                            $state = 'wait-clean'
                            $stateStarted = [DateTime]::UtcNow
                        }
                    }
                    'wait-clean' {
                        if ($plainWindow -match 'EX20V_CLEAN') {
                            $sessionCompleted = $true
                            $inputStream.Close()
                            $state = 'finishing'
                            $stateStarted = [DateTime]::UtcNow
                        }
                    }
                }
                $buffer = New-Object char[] 512
                $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
            }
            elseif ($state -ne 'running' -and $stateStarted -ne [DateTime]::MinValue) {
                $stateSeconds = ([DateTime]::UtcNow - $stateStarted).TotalSeconds
                if ($state -eq 'detect-shell' -and $stateSeconds -gt 2) {
                    & $writeSshLine 'Linux shell algilanamadi; shell komutu deneniyor.' DarkGray
                    & $sendLine 'shell'
                    $window = ''
                    $state = 'wait-user'
                    $stateStarted = [DateTime]::UtcNow
                }
                elseif ($stateSeconds -gt 20 -and $state -in @('wait-user', 'wait-password', 'wait-shell')) {
                    $authError = [Security.Authentication.AuthenticationException]::new('Shell sonrasi Linux girisi zaman asimina ugradi.')
                    $authError.Data['EX20V_STAGE'] = 'shell'
                    throw $authError
                }
                elseif ($stateSeconds -gt 20) {
                    throw "Linux shell gecisi zaman asimina ugradi (asama: $state)."
                }
            }
        }
        $process.WaitForExit()
        if ($null -ne $errorTask) { $sshError = $errorTask.Result }
        $sshExit = if ($sessionCompleted) { 0 } else { $process.ExitCode }
    }
    catch {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill() } } catch {}
        }
        throw
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        $shellPassword = $null
        $LoginPassword = $null
        $SecondaryPassword = $null
    }

    $lines = @($captured.ToString() -split "`r?`n")
    $remoteExit = $null
    foreach ($line in $lines) {
        $plain = $line -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''
        if ($plain -match 'EX20V_SHELL=LINUX') { $linuxShellConfirmed = $true }
        if ($plain -match '__EX20V_RC=([0-9]+)') { $remoteExit = [int]$Matches[1] }
    }
    if ($null -eq $remoteExit) {
        if ($sshExit -ne 0) {
            if ($sshError -match '(?i)(permission denied|authentication failed|access denied)') {
                $authError = [Security.Authentication.AuthenticationException]::new('SSH parolasi veya kimlik dogrulamasi reddedildi.')
                $authError.Data['EX20V_STAGE'] = 'ssh'
                throw $authError
            }
            if (-not [string]::IsNullOrWhiteSpace($sshError)) {
                Write-Host $sshError.Trim() -ForegroundColor DarkGray
            }
            throw "SSH baglantisi basarisiz (kod $sshExit)."
        }
        throw 'Linux shell acilamadi veya ikinci kullanici adi/sifre kabul edilmedi.'
    }
    if (-not $linuxShellConfirmed) {
        throw 'Linux shell dogrulanamadi; guvenlik nedeniyle islem baslatilmadi.'
    }
    if ($remoteExit -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($sshError)) { Write-Host $sshError.Trim() -ForegroundColor Red }
        throw "Cihaz islemi hata ile durdu (kod $remoteExit)."
    }
    return ($lines -join "`n")
}

function Invoke-RemoteAgent {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z-]+$')][string]$Action,
        [string]$PcIp = '127.0.0.1',
        [string]$Extra = '',
        [ValidateSet('stock', 'rescue', 'main')][string]$HostKeyGroup = 'main'
    )

    $loginPassword = if ($HostKeyGroup -eq 'stock') { $script:StockPassword } else { '' }
    $secondaryPassword = if ($HostKeyGroup -eq 'stock') { $script:StockPassword } else { '' }
    $loginPrompted = $false
    $shellPrompted = $false
    try {
        while ($true) {
            try {
                return Invoke-RemoteAgentSession -Target $Target -Action $Action -PcIp $PcIp `
                    -Extra $Extra -HostKeyGroup $HostKeyGroup -LoginPassword $loginPassword `
                    -SecondaryPassword $secondaryPassword
            }
            catch [Security.Authentication.AuthenticationException] {
                $stage = [string]$_.Exception.Data['EX20V_STAGE']
                if ($stage -eq 'ssh' -and -not $loginPrompted) {
                    $label = switch ($HostKeyGroup) {
                        'stock'  { 'Stok firmware SSH parolasi' }
                        'rescue' { 'Rescue OpenWrt root parolasi' }
                        default  { 'Ana OpenWrt root parolasi' }
                    }
                    Write-Warn 'Parolasiz veya varsayilan SSH girisi kabul edilmedi.'
                    $loginPassword = Read-SshPassword $label
                    $loginPrompted = $true
                    continue
                }
                if ($stage -eq 'shell' -and $HostKeyGroup -eq 'stock' -and -not $shellPrompted) {
                    Write-Warn 'TP-Link arayuzunden sonraki Linux shell parolasi kabul edilmedi.'
                    $secondaryPassword = Read-SshPassword 'Linux shell parolasi'
                    $shellPrompted = $true
                    continue
                }
                throw
            }
        }
    }
    finally {
        $loginPassword = $null
        $secondaryPassword = $null
    }
}

function Invoke-RebootPrompt {
    param([string]$Target, [ValidateSet('stock', 'rescue', 'main')][string]$HostKeyGroup)
    $answer = Read-Host 'Cihaz simdi yeniden baslatilsin mi? (E/h)'
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[eEyY]') {
        [void](Invoke-RemoteAgent -Target $Target -Action reboot -HostKeyGroup $HostKeyGroup)
        Write-Ok 'Yeniden baslatma komutu gonderildi.'
    }
    else {
        Write-Warn 'Yeniden baslatma yapilmadi.'
    }
}

function Invoke-Backup {
    Write-Section '1 - Tam stok firmware yedegi'
    Write-Host 'Bu islem flash bellekte hicbir degisiklik yapmaz. Yaklasik 450 MB bos alan gerekir.'
    $target = Read-SshTarget
    $pcIp = Read-IPv4 'Routerin erisecegi bilgisayar IPv4 adresi'
    $session = Join-Path $script:BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    [void](New-Item -ItemType Directory -Path $session -Force)
    $server = $null
    try {
        $server = Start-Ex20vTftpServer -UploadRoot $session
        [void](Invoke-RemoteAgent -Target $target -Action backup -PcIp $pcIp -HostKeyGroup stock)
    }
    catch {
        if (@(Get-ChildItem -LiteralPath $session -Force).Count -eq 0) {
            Remove-Item -LiteralPath $session -Force
            Write-Warn 'Hicbir yedek dosyasi alinmadi; bos oturum klasoru kaldirildi.'
        }
        else {
            Write-Warn "Yarim kalan dosyalar korunuyor: $session"
        }
        throw
    }
    finally {
        Stop-Ex20vTftpServer $server
    }
    [void](Test-BackupDirectory -Path $session)
    Write-Ok "Tam yedek hazir: $session"
}

function Invoke-PrepareRescue {
    Write-Section '2A - Stok firmware uzerinden rescue kurulumu'
    Test-ImageFiles
    $backup = Select-BackupDirectory
    $target = Read-SshTarget
    $pcIp = Read-IPv4 'Stok routerin erisecegi bilgisayar IPv4 adresi'
    if (-not (Confirm-Word -Message 'Bu adim slot A kernel bolumune rescue yazar ve bootflag degerini 0 yapar.' -Word 'OPENWRT')) {
        Write-Warn 'Islem iptal edildi.'
        return
    }
    $server = $null
    try {
        $server = Start-Ex20vServer -ServeRoot $script:ImageRoot -UploadRoot $backup
        [void](Invoke-RemoteAgent -Target $target -Action prepare-rescue -PcIp $pcIp -HostKeyGroup stock)
    }
    finally {
        Stop-Ex20vServer $server
    }
    Write-Ok "Rescue slot A'ya yazildi ve dogrulandi."
    Write-Warn 'Sonraki acilista PC adresini 192.168.1.2/24 yapin ve kabloyu LAN1/2/3 portuna takin.'
    Invoke-RebootPrompt -Target $target -HostKeyGroup stock
}

function Invoke-InstallMain {
    Write-Section '2B - Rescue uzerinden ana OpenWrt kurulumu'
    Test-ImageFiles
    $backup = Select-BackupDirectory
    $target = Read-SshTarget 'root@192.168.1.1'
    $pcIp = Read-IPv4 'Rescue sisteminin erisecegi bilgisayar IPv4 adresi' '192.168.1.2'
    if (-not (Confirm-Word -Message 'Bu adim stok rootfs alanini siler ve ana OpenWrt sistemini yazar.' -Word 'SIL')) {
        Write-Warn 'Islem iptal edildi.'
        return
    }
    $server = $null
    try {
        $rescueKnownHosts = Join-Path $script:StateRoot 'known_hosts_rescue'
        if (Test-Path -LiteralPath $rescueKnownHosts) { Remove-Item -LiteralPath $rescueKnownHosts -Force }
        $server = Start-Ex20vServer -ServeRoot $script:ImageRoot -UploadRoot $backup
        [void](Invoke-RemoteAgent -Target $target -Action install-main -PcIp $pcIp -HostKeyGroup rescue)
    }
    finally {
        Stop-Ex20vServer $server
    }
    Write-Ok 'ANA OPENWRT KURULUMU TAMAMLANDI.'
    Write-Host 'Yeniden acildiginda LuCI: http://192.168.1.1'
    Invoke-RebootPrompt -Target $target -HostKeyGroup rescue
}

function Show-InstallMenu {
    Write-Section '2 - OpenWrt kurulumu'
    Write-Host 'Kurulum iki adimlidir. Sirayi atlamayin.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  1) Adim 1/2 - Stok sistemde rescue OpenWrt'yi kur"
    Write-Host '     Once tam yedek alinmis olmali.' -ForegroundColor DarkGray
    Write-Host "  2) Adim 2/2 - Rescue sistemde ana OpenWrt'yi kur"
    Write-Host '     Birinci adimdan sonra rescue ile acilinca kullanin.' -ForegroundColor DarkGray
    Write-Host '  0) Ana menuye don'
    switch (Read-Host 'Secim') {
        '1' { Invoke-PrepareRescue }
        '2' { Invoke-InstallMain }
        '0' { return }
        default { Write-Warn 'Gecersiz secim.' }
    }
}

function Invoke-RestoreStockStageOne {
    Write-Section '3A - Rescue uzerinden stok firmware geri yukleme'
    Write-Host "Bu adim stok slot B'yi ve reserve_area yedegini geri yukler."
    Write-Host 'Rescue slot A korunur; bootflag yalnizca tum yazmalar dogrulanirsa degisir.'
    $backup = Select-BackupDirectory
    $target = Read-SshTarget 'root@192.168.1.1'
    $pcIp = Read-IPv4 'Rescue sisteminin erisecegi bilgisayar IPv4 adresi' '192.168.1.2'
    if (-not (Confirm-Word -Message 'Bu islem slot B ve reserve_area uzerindeki OpenWrt verilerini stok yedekle degistirir.' -Word 'STOKA-DON')) {
        Write-Warn 'Islem iptal edildi.'
        return
    }

    $server = $null
    try {
        $rescueKnownHosts = Join-Path $script:StateRoot 'known_hosts_rescue'
        if (Test-Path -LiteralPath $rescueKnownHosts) { Remove-Item -LiteralPath $rescueKnownHosts -Force }
        $server = Start-Ex20vServer -ServeRoot $script:ImageRoot -UploadRoot $backup
        [void](Invoke-RemoteAgent -Target $target -Action restore-stock -PcIp $pcIp -HostKeyGroup rescue)
    }
    finally {
        Stop-Ex20vServer $server
    }

    Write-Ok 'STOK SLOT B VE RESERVE_AREA GERI YUKLENDI.'
    Write-Warn 'Rescue slot A henuz korunuyor. Stok firmware sorunsuz acilmadan ikinci asamayi calistirmayin.'
    Invoke-RebootPrompt -Target $target -HostKeyGroup rescue
}

function Invoke-RestoreStockStageTwo {
    Write-Section '3B - Stok donusu tamamla (slot A)'
    Write-Host "Bu adim yalnizca stok firmware slot B'den calisirken aktif olmayan slot A'yi geri yukler."
    $backup = Select-BackupDirectory
    $target = Read-SshTarget 'root@192.168.1.1'
    $pcIp = Read-IPv4 'Stok routerin erisecegi bilgisayar IPv4 adresi'
    if (-not (Confirm-Word -Message 'Stok sistemin sorunsuz acildigini dogruladiysaniz slot A da stok yedekle degistirilecek.' -Word 'TAM-STOK')) {
        Write-Warn 'Islem iptal edildi.'
        return
    }

    $server = $null
    try {
        $server = Start-Ex20vServer -ServeRoot $script:ImageRoot -UploadRoot $backup
        [void](Invoke-RemoteAgent -Target $target -Action restore-stock-finalize -PcIp $pcIp -HostKeyGroup stock)
    }
    finally {
        Stop-Ex20vServer $server
    }

    Write-Ok 'TAM STOK GERI YUKLEME TAMAMLANDI; HER IKI SLOT DA STOK.'
    Write-Host 'Cihaz slot B uzerinde calismaya devam eder; yeniden baslatma gerekmez.'
}

function Show-StockRestoreMenu {
    Write-Section '3 - Stok firmware geri yukleme'
    Write-Host 'Geri donus iki adimlidir ve cihazin kendi tam yedegini kullanir.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  1) Adim 1/2 - Rescue sistemden stok firmware geri yukle'
    Write-Host '     Slot B ve reserve_area geri gelir; rescue korunur.' -ForegroundColor DarkGray
    Write-Host '  2) Adim 2/2 - Stok sistem acildiktan sonra tamamla'
    Write-Host "     Stok slot B'den calisirken slot A da geri yuklenir." -ForegroundColor DarkGray
    Write-Host '  0) Ana menuye don'
    switch (Read-Host 'Secim') {
        '1' { Invoke-RestoreStockStageOne }
        '2' { Invoke-RestoreStockStageTwo }
        '0' { return }
        default { Write-Warn 'Gecersiz secim.' }
    }
}

function Show-SlotMenu {
    Write-Section '4 - Kurtarma ve acilis slotu'
    Write-Host '  1) Durumu goster (salt okunur)'
    Write-Host '  2) Sonraki acilis: slot A / rescue'
    Write-Host '  3) Sonraki acilis: slot B / ana sistem'
    Write-Host '  0) Ana menuye don'
    $choice = Read-Host 'Secim'
    if ($choice -eq '0') { return }
    if ($choice -notin @('1', '2', '3')) { Write-Warn 'Gecersiz secim.'; return }
    $target = Read-SshTarget
    Write-Host '  1) Stok firmware SSH'
    Write-Host '  2) Rescue OpenWrt SSH'
    Write-Host '  3) Ana OpenWrt SSH'
    $systemChoice = Read-Default 'Calisan sistem' '3'
    $group = switch ($systemChoice) { '1' { 'stock' } '2' { 'rescue' } default { 'main' } }
    if ($group -eq 'rescue') {
        $rescueKnownHosts = Join-Path $script:StateRoot 'known_hosts_rescue'
        if (Test-Path -LiteralPath $rescueKnownHosts) { Remove-Item -LiteralPath $rescueKnownHosts -Force }
    }
    if ($choice -eq '1') {
        [void](Invoke-RemoteAgent -Target $target -Action slot-show -HostKeyGroup $group)
        return
    }
    $slot = if ($choice -eq '2') { '0' } else { '1' }
    $description = if ($slot -eq '0') { 'slot A / rescue' } else { 'slot B / ana sistem' }
    if (-not (Confirm-Word -Message "Bootflag $description olarak degistirilecek." -Word $slot)) {
        Write-Warn 'Islem iptal edildi.'
        return
    }
    [void](Invoke-RemoteAgent -Target $target -Action slot-set -Extra $slot -HostKeyGroup $group)
    Invoke-RebootPrompt -Target $target -HostKeyGroup $group
}

function Invoke-LocalCheck {
    Test-ImageFiles -ShowHashes
    $addresses = @(Get-LocalIPv4)
    Write-Host ''
    Write-Host ('Yerel IPv4: ' + $(if ($addresses.Count) { $addresses -join ', ' } else { 'bulunamadi' }))
    [void](Get-SshExecutable)
    Write-Ok 'Windows OpenSSH istemcisi bulundu.'
    $backups = @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'md5.txt') })
    Write-Host ("Tamamlanmis yedek adayi: {0}" -f $backups.Count)
}

function Show-MainMenu {
    Clear-Host
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host '  TP-Link EX20v v2 - OpenWrt Yonetim Araci' -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host 'Yonetici yetkisi: etkin' -ForegroundColor Green
    Write-Host 'Yedekleme, kurulum ve geri donus islemlerini tek yerden yonetir.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Warn 'Ilk kurulumdan once stok firmware uzerinde root SSH erisimi acilmis olmalidir.'
    Write-Host ''
    Write-Host '  1) Stok firmware tam yedegi al'
    Write-Host '  2) OpenWrt kurulumu'
    Write-Host '  3) Stok firmware geri yukleme'
    Write-Host '  4) Kurtarma ve acilis slotu'
    Write-Host '  5) Dosyalari ve gereksinimleri kontrol et'
    Write-Host '  0) Cikis'
    Write-Host ''
    Write-Host 'Ilk kurulum: 1 ile yedek alin, sonra 2 ile kuruluma devam edin.' -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $script:BackupRoot)) { [void](New-Item -ItemType Directory -Path $script:BackupRoot -Force) }
if (-not (Test-Path -LiteralPath $script:StateRoot)) { [void](New-Item -ItemType Directory -Path $script:StateRoot -Force) }

while ($true) {
    Show-MainMenu
    $choice = Read-Host 'Secim'
    if ($choice -eq '0') { break }
    try {
        switch ($choice) {
            '1' { Invoke-Backup }
            '2' { Show-InstallMenu }
            '3' { Show-StockRestoreMenu }
            '4' { Show-SlotMenu }
            '5' { Invoke-LocalCheck }
            default { Write-Warn 'Gecersiz secim.' }
        }
    }
    catch {
        Write-Host ''
        Write-Host ('HATA: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Warn 'Yazma islemi basladiysa cihazi yeniden baslatmadan once hata mesajini kontrol edin.'
    }
    Write-Host ''
    [void](Read-Host 'Ana menu icin Enter')
}

