#!/bin/bash

set -e -u

# archiso settings
#
# Do not change this variable.
# To change the settings permanently, edit the config file.

iso_name=alterlinux
iso_label="ALTER_$(date +%Y%m)"
iso_publisher="Alter Linux <http://www.archlinux.org>"
iso_application="Alter Linux Live/Rescue CD"
iso_version=$(date +%Y.%m.%d)
install_dir=alter
work_dir=work
out_dir=out
gpg_key=
verbose="-v"

# AlterLinux settings
password=alter
boot_splash=false
kernel=
theme_name="alter-logo"
theme_pkg="plymouth-theme-alter-logo-git"
sfs_comp="zstd"
sfs_comp_opt=""

# Load extra settings
[[ -f ./config ]] && source config

script_path=$(readlink -f ${0%/*})

function mkarchiso () {
    ./mkalteriso "${@}"
}

umask 0022

_usage () {
    echo "usage ${0} [options]"
    echo
    echo " General options:"
    echo "    -b                 Enable boot splash"
    echo "                        Default: disable"
    echo "    -c <comp_type>     Set SquashFS compression type (gzip, lzma, lzo, xz, zstd)"
    echo "                        Default: ${sfs_comp}"
    echo "    -g <gpg_key>       Set gpg key"
    if [[ -z "${gpg_key}" ]]; then
        echo "                        Default: empty"
    else
        echo "                        Default: ${gpg_key}"
    fi
    echo "    -k <kernel>        Set special kernel type."
    if [[ -z "${kernel}" ]]; then
        echo "                        Default: empty"
    else
        echo "                        Default: ${kernel}"
    fi
    echo "    -o <out_dir>       Set the output directory"
    echo "                        Default: ${out_dir}"
    echo "    -p <password>      Set a live user password"
    echo "                        Default: ${password}"
    echo "    -t <options>       Set compressor-specific options."
    echo "                        Default: empty"
    echo "    -w <work_dir>      Set the working directory"
    echo "                        Default: ${work_dir}"
    echo "    -h                 This help message"
    exit ${1}
}

# Helper function to run make_*() only one time per architecture.
run_once() {
    if [[ ! -e ${work_dir}/build.${1} ]]; then
        $1
        touch ${work_dir}/build.${1}
    fi
}

# Setup custom pacman.conf with current cache directories.
make_pacman_conf() {
    local _cache_dirs
    _cache_dirs=($(pacman -v 2>&1 | grep '^Cache Dirs:' | sed 's/Cache Dirs:\s*//g'))
    sed -r "s|^#?\\s*CacheDir.+|CacheDir = $(echo -n ${_cache_dirs[@]})|g" ${script_path}/pacman.conf > ${work_dir}/pacman.conf
}

# Base installation, plus needed packages (airootfs)
make_basefs() {
    mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" init
    # mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "haveged intel-ucode amd-ucode memtest86+ mkinitcpio-nfs-utils nbd zsh efitools" install
    mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "haveged intel-ucode amd-ucode mkinitcpio-nfs-utils nbd efitools" install

    # Install plymouth.
    if [[ ${boot_splash} = true ]]; then
        if [[ -n ${theme_pkg} ]]; then
            mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "plymouth ${theme_pkg}" install
        else
            mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "plymouth" install
        fi
    fi

    # Install kernel.
    if [[ -n ${kernel} ]]; then
        mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "linux-${kernel} linux-${kernel}-headers" install
    else
        mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "linux linux-headers" install
    fi
}

# Additional packages (airootfs)
make_packages() {
    mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -p "$(grep -h -v ^'#' ${script_path}/packages.x86_64)" install
}

# Copy mkinitcpio archiso hooks and build initramfs (airootfs)
make_setup_mkinitcpio() {
    local _hook
    mkdir -p ${work_dir}/x86_64/airootfs/etc/initcpio/hooks
    mkdir -p ${work_dir}/x86_64/airootfs/etc/initcpio/install
    for _hook in archiso archiso_shutdown archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs archiso_loop_mnt; do
        cp /usr/lib/initcpio/hooks/${_hook} ${work_dir}/x86_64/airootfs/etc/initcpio/hooks
        cp /usr/lib/initcpio/install/${_hook} ${work_dir}/x86_64/airootfs/etc/initcpio/install
    done
    sed -i "s|/usr/lib/initcpio/|/etc/initcpio/|g" ${work_dir}/x86_64/airootfs/etc/initcpio/install/archiso_shutdown
    cp /usr/lib/initcpio/install/archiso_kms ${work_dir}/x86_64/airootfs/etc/initcpio/install
    cp /usr/lib/initcpio/archiso_shutdown ${work_dir}/x86_64/airootfs/etc/initcpio
    if [[ ${boot_splash} = true ]]; then
        cp ${script_path}/mkinitcpio/archiso/mkinitcpio-plymouth.conf ${work_dir}/x86_64/airootfs/etc/mkinitcpio-archiso.conf
    else
        cp ${script_path}/mkinitcpio/archiso/mkinitcpio.conf ${work_dir}/x86_64/airootfs/etc/mkinitcpio-archiso.conf
    fi
    gnupg_fd=
    if [[ ${gpg_key} ]]; then
      gpg --export ${gpg_key} >${work_dir}/gpgkey
      exec 17<>${work_dir}/gpgkey
    fi

    if [[ -n ${kernel} ]]; then
        ARCHISO_GNUPG_FD=${gpg_key:+17} mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r "mkinitcpio -c /etc/mkinitcpio-archiso.conf -k /boot/vmlinuz-linux-${kernel} -g /boot/archiso.img" run
    else
        ARCHISO_GNUPG_FD=${gpg_key:+17} mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r 'mkinitcpio -c /etc/mkinitcpio-archiso.conf -k /boot/vmlinuz-linux -g /boot/archiso.img' run
    fi

    if [[ ${gpg_key} ]]; then
      exec 17<&-
    fi
}

# Customize installation (airootfs)
make_customize_airootfs() {
    cp -af ${script_path}/airootfs ${work_dir}/x86_64

    if [[ ${boot_splash} = true ]]; then
        cp ${script_path}/mkinitcpio/mkinitcpio-plymouth.conf ${work_dir}/x86_64/airootfs/etc/mkinitcpio.conf
    fi

    cp ${script_path}/pacman.conf ${work_dir}/x86_64/airootfs/etc

    curl -o ${work_dir}/x86_64/airootfs/etc/pacman.d/mirrorlist 'https://www.archlinux.org/mirrorlist/?country=all&protocol=http&use_mirror_status=on'

    # lynx -dump -nolist 'https://wiki.archlinux.org/index.php/Installation_Guide?action=render' >> ${work_dir}/x86_64/airootfs/root/install.txt


    # customize_airootfs.sh options
    # -p <password> : Set password.
    # -b            : Enable boot splash.
    # -t            : Set plymouth theme.
    # -k <kernel>   : Set kernel name.


    local options
    options=
    if [[ ${boot_splash} = true ]]; then
        if [[ -z ${theme_name} ]]; then
            options="-b"
        else
            options="-b -t ${theme_name}"
        fi
    fi
    if [[ -n ${kernel} ]]; then
        options="${options} -k ${kernel}"
    fi
    if [[ -z ${options} ]]; then
        mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r "/root/customize_airootfs.sh -p ${password}" run
    else
        mkarchiso ${verbose} -w "${work_dir}/x86_64" -C "${work_dir}/pacman.conf" -D "${install_dir}" -r "/root/customize_airootfs.sh -p ${password} ${options}" run
    fi
    rm ${work_dir}/x86_64/airootfs/root/customize_airootfs.sh
}

# Prepare kernel/initramfs ${install_dir}/boot/
make_boot() {
    mkdir -p ${work_dir}/iso/${install_dir}/boot/x86_64
    cp ${work_dir}/x86_64/airootfs/boot/archiso.img ${work_dir}/iso/${install_dir}/boot/x86_64/archiso.img

    if [[ -n ${kernel} ]]; then
        cp ${work_dir}/x86_64/airootfs/boot/vmlinuz-linux-${kernel} ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz-linux-${kernel}
    else
        cp ${work_dir}/x86_64/airootfs/boot/vmlinuz-linux ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz
    fi

}

# Add other aditional/extra files to ${install_dir}/boot/
make_boot_extra() {
    # cp ${work_dir}/x86_64/airootfs/boot/memtest86+/memtest.bin ${work_dir}/iso/${install_dir}/boot/memtest
    # cp ${work_dir}/x86_64/airootfs/usr/share/licenses/common/GPL2/license.txt ${work_dir}/iso/${install_dir}/boot/memtest.COPYING
    cp ${work_dir}/x86_64/airootfs/boot/intel-ucode.img ${work_dir}/iso/${install_dir}/boot/intel_ucode.img
    cp ${work_dir}/x86_64/airootfs/usr/share/licenses/intel-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/intel_ucode.LICENSE
    cp ${work_dir}/x86_64/airootfs/boot/amd-ucode.img ${work_dir}/iso/${install_dir}/boot/amd_ucode.img
    cp ${work_dir}/x86_64/airootfs/usr/share/licenses/amd-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/amd_ucode.LICENSE
}

# Prepare /${install_dir}/boot/syslinux
make_syslinux() {
    if [[ -n ${kernel} ]]; then
        _uname_r=$(file -b ${work_dir}/x86_64/airootfs/boot/vmlinuz-linux-${kernel} | awk 'f{print;f=0} /version/{f=1}' RS=' ')
    else
        _uname_r=$(file -b ${work_dir}/x86_64/airootfs/boot/vmlinuz-linux | awk 'f{print;f=0} /version/{f=1}' RS=' ')
    fi
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux

    for _cfg in ${script_path}/syslinux/*.cfg; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g" ${_cfg} > ${work_dir}/iso/${install_dir}/boot/syslinux/${_cfg##*/}
    done

    if [[ -n ${kernel} ]]; then
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${script_path}/syslinux/archiso_pxe/archiso_pxe-${kernel}.cfg > ${work_dir}/iso/${install_dir}/boot/syslinux/archiso_pxe.cfg

        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${script_path}/syslinux/archiso_sys/archiso_sys-${kernel}.cfg > ${work_dir}/iso/${install_dir}/boot/syslinux/archiso_sys.cfg
    else
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${script_path}/syslinux/archiso_pxe/archiso_pxe.cfg > ${work_dir}/iso/${install_dir}/boot/syslinux/archiso_pxe.cfg

        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${script_path}/syslinux/archiso_sys/archiso_sys.cfg > ${work_dir}/iso/${install_dir}/boot/syslinux/archiso_sys.cfg
    fi

    cp ${script_path}/syslinux/splash.png ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/*.c32 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/lpxelinux.0 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/memdisk ${work_dir}/iso/${install_dir}/boot/syslinux
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux/hdt
    gzip -c -9 ${work_dir}/x86_64/airootfs/usr/share/hwdata/pci.ids > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/pciids.gz
    gzip -c -9 ${work_dir}/x86_64/airootfs/usr/lib/modules/${_uname_r}/modules.alias > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/modalias.gz
}

# Prepare /isolinux
make_isolinux() {
    mkdir -p ${work_dir}/iso/isolinux
    sed "s|%INSTALL_DIR%|${install_dir}|g" ${script_path}/isolinux/isolinux.cfg > ${work_dir}/iso/isolinux/isolinux.cfg
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/isolinux.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/isohdpfx.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/x86_64/airootfs/usr/lib/syslinux/bios/ldlinux.c32 ${work_dir}/iso/isolinux/
}

# Prepare /EFI
make_efi() {
    mkdir -p ${work_dir}/iso/EFI/boot
    cp ${work_dir}/x86_64/airootfs/usr/share/efitools/efi/PreLoader.efi ${work_dir}/iso/EFI/boot/bootx64.efi
    cp ${work_dir}/x86_64/airootfs/usr/share/efitools/efi/HashTool.efi ${work_dir}/iso/EFI/boot/

    cp ${work_dir}/x86_64/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/iso/EFI/boot/loader.efi

    mkdir -p ${work_dir}/iso/loader/entries
    cp ${script_path}/efiboot/loader/loader.conf ${work_dir}/iso/loader/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/iso/loader/entries/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/iso/loader/entries/

    if [[ -n ${kernel} ]]; then
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${script_path}/efiboot/loader/entries/usb/archiso-x86_64-usb-${kernel}.conf > ${work_dir}/iso/loader/entries/archiso-x86_64.conf
    else
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${script_path}/efiboot/loader/entries/usb/archiso-x86_64-usb.conf > ${work_dir}/iso/loader/entries/archiso-x86_64.conf
    fi

    # EFI Shell 2.0 for UEFI 2.3+
    curl -o ${work_dir}/iso/EFI/shellx64_v2.efi https://raw.githubusercontent.com/tianocore/edk2/UDK2018/ShellBinPkg/UefiShell/X64/Shell.efi
    # EFI Shell 1.0 for non UEFI 2.3+
    curl -o ${work_dir}/iso/EFI/shellx64_v1.efi https://raw.githubusercontent.com/tianocore/edk2/UDK2018/EdkShellBinPkg/FullShell/X64/Shell_Full.efi
}

# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
make_efiboot() {
    mkdir -p ${work_dir}/iso/EFI/archiso
    truncate -s 64M ${work_dir}/iso/EFI/archiso/efiboot.img
    mkfs.fat -n ARCHISO_EFI ${work_dir}/iso/EFI/archiso/efiboot.img

    mkdir -p ${work_dir}/efiboot
    mount ${work_dir}/iso/EFI/archiso/efiboot.img ${work_dir}/efiboot

    mkdir -p ${work_dir}/efiboot/EFI/archiso

    if [[ -n ${kernel} ]]; then
        cp ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz-linux-${kernel} ${work_dir}/efiboot/EFI/archiso/vmlinuz-linux-${kernel}.efi
    else
        cp ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz ${work_dir}/efiboot/EFI/archiso/vmlinuz.efi
    fi

    cp ${work_dir}/iso/${install_dir}/boot/x86_64/archiso.img ${work_dir}/efiboot/EFI/archiso/archiso.img

    cp ${work_dir}/iso/${install_dir}/boot/intel_ucode.img ${work_dir}/efiboot/EFI/archiso/intel_ucode.img
    cp ${work_dir}/iso/${install_dir}/boot/amd_ucode.img ${work_dir}/efiboot/EFI/archiso/amd_ucode.img

    mkdir -p ${work_dir}/efiboot/EFI/boot
    cp ${work_dir}/x86_64/airootfs/usr/share/efitools/efi/PreLoader.efi ${work_dir}/efiboot/EFI/boot/bootx64.efi
    cp ${work_dir}/x86_64/airootfs/usr/share/efitools/efi/HashTool.efi ${work_dir}/efiboot/EFI/boot/

    cp ${work_dir}/x86_64/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/efiboot/EFI/boot/loader.efi

    mkdir -p ${work_dir}/efiboot/loader/entries
    cp ${script_path}/efiboot/loader/loader.conf ${work_dir}/efiboot/loader/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/efiboot/loader/entries/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/efiboot/loader/entries/

    #${script_path}/efiboot/loader/entries/archiso-x86_64-cd.conf

    if [[ -n ${kernel} ]]; then
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${script_path}/efiboot/loader/entries/cd/archiso-x86_64-cd-${kernel}.conf > ${work_dir}/efiboot/loader/entries/archiso-x86_64.conf
    else
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
            s|%INSTALL_DIR%|${install_dir}|g" \
            ${script_path}/efiboot/loader/entries/cd/archiso-x86_64-cd.conf > ${work_dir}/efiboot/loader/entries/archiso-x86_64.conf
    fi

    cp ${work_dir}/iso/EFI/shellx64_v2.efi ${work_dir}/efiboot/EFI/
    cp ${work_dir}/iso/EFI/shellx64_v1.efi ${work_dir}/efiboot/EFI/

    umount -d ${work_dir}/efiboot
}

# Build airootfs filesystem image
make_prepare() {
    cp -a -l -f ${work_dir}/x86_64/airootfs ${work_dir}
    mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" pkglist
    mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" ${gpg_key:+-g ${gpg_key}} -c "${sfs_comp}" -t "${sfs_comp_opt}" prepare
    rm -rf ${work_dir}/airootfs
    # rm -rf ${work_dir}/x86_64/airootfs (if low space, this helps)
}

# Build ISO
make_iso() {
    mkarchiso ${verbose} -w "${work_dir}" -D "${install_dir}" -L "${iso_label}" -P "${iso_publisher}" -A "${iso_application}" -o "${out_dir}" iso "${iso_name}-${iso_version}-x86_64.iso"
}

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root."
    _usage 1
fi

while getopts 'w:o:g:p:c:t:hbk:' arg; do
    case "${arg}" in
        p) password="${OPTARG}" ;;
        w) work_dir="${OPTARG}" ;;
        o) out_dir="${OPTARG}" ;;
        g) gpg_key="${OPTARG}" ;;
        c)
            # compression format check.
            if [[ ${OPTARG} = "gzip" ||  ${OPTARG} = "lzma" ||  ${OPTARG} = "lzo" ||  ${OPTARG} = "lz4" ||  ${OPTARG} = "xz" ||  ${OPTARG} = "zstd" ]]; then
                sfs_comp="${OPTARG}"
            else
                echo "Invalid compressors ${arg}"
                _usage 1
            fi
            ;;
        t) sfs_comp_opt=${OPTARG} ;;
        b) boot_splash=true ;;
        k) 
            case ${OPTARG} in
                "lts") kernel=lts ;;
                "lqx") kernel=lqx ;;
                "zen") kernel=zen ;;
                 "ck") kernel=ck  ;;
                    *)
                        echo "Invalid kernel ${OPTARG}"
                        _usage 1
                        ;;
            esac
            ;;
        h) _usage 0 ;;
        *)
           echo "Invalid argument '${arg}'"
           _usage 1
           ;;
    esac
done

mkdir -p ${work_dir}

# Show Alter Linux build options.
[[ ${boot_splash} = true ]] && echo "Boot splash is enabled."; echo "Theme is used ${theme_name}."
[[ -n "${kernel}" ]] && echo "kernel is changed to ${kernel}"
echo "Live user password is ${password}."
echo "The compression method of squashfs is ${sfs_comp}."
sleep 2


run_once make_pacman_conf
run_once make_basefs
run_once make_packages
run_once make_setup_mkinitcpio
run_once make_customize_airootfs
run_once make_boot
run_once make_boot_extra
run_once make_syslinux
run_once make_isolinux
run_once make_efi
run_once make_efiboot
run_once make_prepare
run_once make_iso
