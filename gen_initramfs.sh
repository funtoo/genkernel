#!/bin/bash
# $Id$

CPIO_ARGS="--quiet -o -H newc"

# The copy_binaries function is explicitly released under the CC0 license to
# encourage wide adoption and re-use.  That means:
# - You may use the code of copy_binaries() as CC0 outside of genkernel
# - Contributions to this function are licensed under CC0 as well.
# - If you change it outside of genkernel, please consider sending your
#	modifications back to genkernel@gentoo.org.
#
# On a side note: "Both public domain works and the simple license provided by
#				   CC0 are compatible with the GNU GPL."
#				  (from https://www.gnu.org/licenses/license-list.html#CC0)
#
# Written by:
# - Sebastian Pipping <sebastian@pipping.org> (error checking)
# - Robin H. Johnson <robbat2@gentoo.org> (complete rewrite)
# - Richard Yao <ryao@cs.stonybrook.edu> (original concept)
# Usage:
# copy_binaries DESTDIR BINARIES...
copy_binaries() {
	local destdir=$1
	shift

	for binary in "$@"; do
		[[ -e "${binary}" ]] \
				|| gen_die "Binary ${binary} could not be found"

		if LC_ALL=C lddtree "${binary}" 2>&1 | fgrep -q 'not found'; then
			gen_die "Binary ${binary} is linked to missing libraries and may need to be re-built"
		fi
	done
	# This must be OUTSIDE the for loop, we only want to run lddtree etc ONCE.
	# lddtree does not have the -V (version) nor the -l (list) options prior to version 1.18
	(
	if lddtree -V > /dev/null 2>&1 ; then
		lddtree -l "$@"
	else
		lddtree "$@" \
			| tr ')(' '\n' \
			| awk  '/=>/{ if($3 ~ /^\//){print $3}}'
	fi ) \
			| sort \
			| uniq \
			| cpio -p --make-directories --dereference --quiet "${destdir}" \
			|| gen_die "Binary ${f} or some of its library dependencies could not be copied"
}

log_future_cpio_content() {
	if [[ "${LOGLEVEL}" -gt 1 ]]; then
		echo =================================================================
		echo "About to add these files from '${PWD}' to cpio archive:"
		find . | xargs ls -ald
		echo =================================================================
	fi
}

append_to_cpio() {
	cd "$1" || gen_die "Can't find directory: $1"
	log_future_cpio_content
	# Normalize lib directory structure to all be in /lib:
	for libdir in lib64 usr/lib usr/lib64; do
		if [ -d $libdir ] && ! [ -L $libdir ]; then
			rsync -a $libdir/ lib/
			rm -rf $libdir
		fi
	done
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" || gen_die "appending $1 cpio"
	cd ${TEMP}
	rm -rf "${1}" > /dev/null
}

try() {
	$* || gen_die "command fail: $*"
}

append_base_layout() {
	if [ -d "${TEMP}/initramfs-base-temp" ]
	then
		rm -rf "${TEMP}/initramfs-base-temp" > /dev/null
	fi

	try mkdir -p ${TEMP}/initramfs-base-temp/dev 
	try mkdir -p ${TEMP}/initramfs-base-temp/bin 
	try mkdir -p ${TEMP}/initramfs-base-temp/etc
	try mkdir -p ${TEMP}/initramfs-base-temp/usr
	try mkdir -p ${TEMP}/initramfs-base-temp/lib
	try ln -s lib ${TEMP}/initramfs-base-temp/lib64
	try ln -s ../lib ${TEMP}/initramfs-base-temp/usr/lib
	try ln -s ../lib ${TEMP}/initramfs-base-temp/usr/lib64
	try mkdir -p ${TEMP}/initramfs-base-temp/mnt
	try mkdir -p ${TEMP}/initramfs-base-temp/run
	try mkdir -p ${TEMP}/initramfs-base-temp/sbin
	try mkdir -p ${TEMP}/initramfs-base-temp/proc
	try mkdir -p ${TEMP}/initramfs-base-temp/temp
	try mkdir -p ${TEMP}/initramfs-base-temp/tmp
	try mkdir -p ${TEMP}/initramfs-base-temp/sys
	try mkdir -p ${TEMP}/initramfs-temp/.initrd
	try mkdir -p ${TEMP}/initramfs-base-temp/var/lock/dmraid
	try mkdir -p ${TEMP}/initramfs-base-temp/sbin
	try mkdir -p ${TEMP}/initramfs-base-temp/usr/bin
	try mkdir -p ${TEMP}/initramfs-base-temp/usr/sbin
	echo "/dev/ram0     /           ext2    defaults        0 0" > ${TEMP}/initramfs-base-temp/etc/fstab
	echo "proc          /proc       proc    defaults    0 0" >> ${TEMP}/initramfs-base-temp/etc/fstab
	date -u '+%Y%m%d-%H%M%S' > ${TEMP}/initramfs-base-temp/etc/build_date
	append_to_cpio "${TEMP}/initramfs-base-temp/" baselayout
}

append_busybox() {
	if [ -d "${TEMP}/initramfs-busybox-temp" ]
	then
		rm -rf "${TEMP}/initramfs-busybox-temp" > /dev/null
	fi

	mkdir -p "${TEMP}/initramfs-busybox-temp/bin/" 
	tar -xjf "${BUSYBOX_BINCACHE}" -C "${TEMP}/initramfs-busybox-temp/bin" busybox ||
		gen_die 'Could not extract busybox bincache!'
	chmod +x "${TEMP}/initramfs-busybox-temp/bin/busybox"

	mkdir -p "${TEMP}/initramfs-busybox-temp/usr/share/udhcpc/"
	cp "${GK_SHARE}/defaults/udhcpc.scripts" ${TEMP}/initramfs-busybox-temp/usr/share/udhcpc/default.script
	chmod +x "${TEMP}/initramfs-busybox-temp/usr/share/udhcpc/default.script"

	# Set up a few default symlinks
	for i in ${BUSYBOX_APPLETS:-[ ash sh mount uname echo cut cat}; do
		rm -f ${TEMP}/initramfs-busybox-temp/bin/$i > /dev/null
		ln -s busybox ${TEMP}/initramfs-busybox-temp/bin/$i ||
			gen_die "Busybox error: could not link ${i}!"
	done
	append_to_cpio "${TEMP}/initramfs-busybox-temp/" busybox
}

append_blkid(){
	if [ -d "${TEMP}/initramfs-blkid-temp" ]
	then
		rm -r "${TEMP}/initramfs-blkid-temp/"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-blkid-temp/"

	if [[ "${DISKLABEL}" = "1" ]]; then
		copy_binaries "${TEMP}"/initramfs-blkid-temp/ /sbin/blkid
	fi
	append_to_cpio "${TEMP}/initramfs-blkid-temp/" blkid
}

append_unionfs_fuse() {
	if [ -d "${TEMP}/initramfs-unionfs-fuse-temp" ]
	then
		rm -r "${TEMP}/initramfs-unionfs-fuse-temp"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-unionfs-fuse-temp/sbin/"
	bzip2 -dc "${UNIONFS_FUSE_BINCACHE}" > "${TEMP}/initramfs-unionfs-fuse-temp/sbin/unionfs" ||
		gen_die 'Could not extract unionfs-fuse binary cache!'
	chmod a+x "${TEMP}/initramfs-unionfs-fuse-temp/sbin/unionfs"
	append_to_cpio "${TEMP}/initramfs-unionfs-fuse-temp/" unionfs_fuse
}

append_multipath(){
	if [ -d "${TEMP}/initramfs-multipath-temp" ]
	then
		rm -r "${TEMP}/initramfs-multipath-temp"
	fi
	print_info 1 '	Multipath support being added'
	mkdir -p "${TEMP}"/initramfs-multipath-temp/{bin,etc,sbin,lib}/

	# Copy files
	copy_binaries "${TEMP}/initramfs-multipath-temp" /sbin/{multipath,kpartx,mpath_prio_*,dmsetup} /lib/udev/scsi_id /bin/mountpoint

	if [ -x /sbin/multipath ]
	then
		cp /etc/multipath.conf "${TEMP}/initramfs-multipath-temp/etc/" || gen_die 'could not copy /etc/multipath.conf please check this'
	fi
	# /etc/scsi_id.config does not exist in newer udevs
	# copy it optionally.
	if [ -x /sbin/scsi_id -a -f /etc/scsi_id.config ]
	then
		cp /etc/scsi_id.config "${TEMP}/initramfs-multipath-temp/etc/" || gen_die 'could not copy scsi_id.config'
	fi
	append_to_cpio "${TEMP}/initramfs-multipath-temp" multipath
}

append_dmraid(){
	if [ -d "${TEMP}/initramfs-dmraid-temp" ]
	then
		rm -r "${TEMP}/initramfs-dmraid-temp/"
	fi
	print_info 1 'DMRAID: Adding support (compiling binaries)...'
	compile_dmraid
	mkdir -p "${TEMP}/initramfs-dmraid-temp/"
	/bin/tar -jxpf "${DMRAID_BINCACHE}" -C "${TEMP}/initramfs-dmraid-temp" ||
		gen_die "Could not extract dmraid binary cache!";
	cd "${TEMP}/initramfs-dmraid-temp/"
	RAID456=`find . -type f -name raid456.ko`
	if [ -n "${RAID456}" ]
	then
		cd "${RAID456/raid456.ko/}"
		ln -sf raid456.kp raid45.ko
		cd "${TEMP}/initramfs-dmraid-temp/"
	fi
	append_to_cpio "${TEMP}/initramfs-dmraid-temp/" dmraid
}

append_iscsi(){
	if [ -d "${TEMP}/initramfs-iscsi-temp" ]
	then
		rm -r "${TEMP}/initramfs-iscsi-temp/"
	fi
	print_info 1 'iSCSI: Adding support (compiling binaries)...'
	compile_iscsi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-iscsi-temp/bin/"
	/bin/bzip2 -dc "${ISCSI_BINCACHE}" > "${TEMP}/initramfs-iscsi-temp/bin/iscsistart" ||
		gen_die "Could not extract iscsi binary cache!"
	chmod a+x "${TEMP}/initramfs-iscsi-temp/bin/iscsistart"
	append_to_cpio "${TEMP}/initramfs-iscsi-temp/" iscsi
}

append_lvm(){
	if [ -d "${TEMP}/initramfs-lvm-temp" ]
	then
		rm -r "${TEMP}/initramfs-lvm-temp/"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-lvm-temp/bin/"
	mkdir -p "${TEMP}/initramfs-lvm-temp/etc/lvm/"
	print_info 1 '			LVM: Adding support (using local static binary /sbin/lvm.static)...'
	cp /sbin/lvm.static "${TEMP}/initramfs-lvm-temp/bin/lvm" || gen_die 'Could not copy over lvm!'
	if [ -e /etc/lvm/lvm.conf ]; then
		cp /etc/lvm/lvm.conf "${TEMP}/initramfs-lvm-temp/etc/lvm/" || gen_die 'Could not copy over lvm.conf!'
	fi
	append_to_cpio "${TEMP}/initramfs-lvm-temp/" lvm
}

append_mdadm(){
	if [ -d "${TEMP}/initramfs-mdadm-temp" ]
	then
			rm -r "${TEMP}/initramfs-mdadm-temp/"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-mdadm-temp/etc/"
	mkdir -p "${TEMP}/initramfs-mdadm-temp/sbin/"
	if [ "${MDADM}" = '1' ]
	then
			if [ -n "${MDADM_CONFIG}" ]
			then
					if [ -f "${MDADM_CONFIG}" ]
					then
							cp -a "${MDADM_CONFIG}" "${TEMP}/initramfs-mdadm-temp/etc/mdadm.conf" \
							 || gen_die "Could not copy mdadm.conf!"
					else
							gen_die 'sl${MDADM_CONFIG} does not exist!'
					fi
			else
					print_info 1 '			MDADM: Skipping inclusion of mdadm.conf'
			fi

			if [ -e '/sbin/mdadm' ] && LC_ALL="C" ldd /sbin/mdadm | grep -q 'not a dynamic executable' \
			&& [ -e '/sbin/mdmon' ] && LC_ALL="C" ldd /sbin/mdmon | grep -q 'not a dynamic executable'
			then
					print_info 1 '			MDADM: Adding support (using local static binaries /sbin/mdadm and /sbin/mdmon)...'
					copy_binaries "${TEMP}/initramfs-mdadm-temp" /sbin/{mdadm,mdmon} || gen_die 'Could not copy over mdadm!'
			else
					gen_die "Could not find /sbin/mdadm or /sbin/mdmon for initramfs"
			fi
	fi
	append_to_cpio "${TEMP}/initramfs-mdadm-temp/" mdadm
}

append_zfs(){
	if [ -d "${TEMP}/initramfs-zfs-temp" ]
	then
		rm -r "${TEMP}/initramfs-zfs-temp"
	fi

	mkdir -p "${TEMP}/initramfs-zfs-temp/etc/zfs"
	
	modprobe zfs 2>&1
	if [ $? -ne 0 ]; then
		gen_die "Trying to set up ZFS initramfs but can't load ZFS modules."
	fi

	# Copy cachefiles for each pool, if they exist
	for pool in $(zpool list -H|cut -f1)
	do
		# determine cachefile
		pool_cachefile=$(zpool get -H cachefile ${pool}|cut -f3)
		if [ ${pool_cachefile} == "-" ]
		then
			# no cachefile - warn about long startup delays
			print_warning 1 "------------------------ WARNING ------------------------"
			print_warning 1 " No cachefile set on ZFS pool '${pool}'!"
			print_warning 1 " Startup times will be VERY SLOW as a result."
			print_warning 1 " To set a cachefile, run a command like this:"
			print_warning 1 "	 zpool set cachefile=/etc/zfs/zpool-${pool}.cache ${pool}"
			print_warning 1 " ... then re-run genkernel."
			print_warning 1 "---------------------------------------------------------"
		else
			# cachefile set, copy to normalized location
			cp -a "${pool_cachefile}" "${TEMP}/initramfs-zfs-temp/etc/zfs/zpool-${pool}.cache" 2>/dev/null \
				|| gen_dir "Could not copy file ${pool_cachefile} for ZFS"
			fi
	done

	# Copy binaries
	# Include libgcc_s.so.1 to workaround zfsonlinux/zfs#4749
	local libgccpath
	if type gcc-config 2>&1 1>/dev/null; then
		libgccpath="/usr/lib/gcc/$(s=$(gcc-config -c); echo ${s%-*}/${s##*-})/libgcc_s.so.1"
	fi
	if [[ ! -f ${libgccpath} ]]; then
		libgccpath="/usr/lib/gcc/*/*/libgcc_s.so.1"
	fi

	copy_binaries "${TEMP}/initramfs-zfs-temp" /sbin/{mount.zfs,zdb,zfs,zpool} ${libgccpath}
	cd "${TEMP}/initramfs-zfs-temp/lib"
	ln -s ${libgccpath} libgcc_s.so.1
	append_to_cpio "${TEMP}/initramfs-zfs-temp/"
}

append_btrfs() {
	if [ -d "${TEMP}/initramfs-btrfs-temp" ]
	then
	rm -r "${TEMP}/initramfs-btrfs-temp"
	fi

	mkdir -p "${TEMP}/initramfs-btrfs-temp"

	# Copy binaries
	copy_binaries "${TEMP}/initramfs-btrfs-temp" /sbin/btrfs
	append_to_cpio "${TEMP}/initramfs-btrfs-temp/" btrfs
}

append_splash(){
	splash_geninitramfs=`which splash_geninitramfs 2>/dev/null`
	if [ -x "${splash_geninitramfs}" ]
	then
		[ -z "${SPLASH_THEME}" ] && [ -e /etc/conf.d/splash ] && source /etc/conf.d/splash
		[ -z "${SPLASH_THEME}" ] && SPLASH_THEME=default
		print_info 1 "	>> Installing splash [ using the ${SPLASH_THEME} theme ]..."
		if [ -d "${TEMP}/initramfs-splash-temp" ]
		then
			rm -r "${TEMP}/initramfs-splash-temp/"
		fi
		mkdir -p "${TEMP}/initramfs-splash-temp"
		cd /
		local tmp=""
		[ -n "${SPLASH_RES}" ] && tmp="-r ${SPLASH_RES}"
		splash_geninitramfs -c "${TEMP}/initramfs-splash-temp" ${tmp} ${SPLASH_THEME} || gen_die "Could not build splash cpio archive"
		if [ -e "/usr/share/splashutils/initrd.splash" ]; then
			mkdir -p "${TEMP}/initramfs-splash-temp/etc"
			cp -f "/usr/share/splashutils/initrd.splash" "${TEMP}/initramfs-splash-temp/etc"
		fi
		append_to_cpio "${TEMP}/initramfs-splash-temp/" splash
	else
		print_warning 1 '				>> No splash detected; skipping!'
	fi
}

append_overlay(){
	cd ${INITRAMFS_OVERLAY}
	log_future_cpio_content
	find . -print | cpio ${CPIO_ARGS} --append -F "${CPIO}" \
			|| gen_die "compressing overlay cpio"
}

append_luks() {
	local _luks_error_format="LUKS support cannot be included: %s.	Please emerge sys-fs/cryptsetup[static]."
	local _luks_source=/sbin/cryptsetup
	local _luks_dest=/sbin/cryptsetup

	if [ -d "${TEMP}/initramfs-luks-temp" ]
	then
		rm -r "${TEMP}/initramfs-luks-temp/"
	fi

	mkdir -p "${TEMP}/initramfs-luks-temp/lib/luks/"
	mkdir -p "${TEMP}/initramfs-luks-temp/sbin"
	cd "${TEMP}/initramfs-luks-temp"

	if isTrue ${LUKS}
	then
		[ -x "${_luks_source}" ] \
				|| gen_die "$(printf "${_luks_error_format}" "no file ${_luks_source}")"

		print_info 1 "Including LUKS support"
		copy_binaries "${TEMP}/initramfs-luks-temp/" /sbin/cryptsetup
	fi
	
	append_to_cpio "${TEMP}/initramfs-luks-temp" luks
}

append_dropbear(){
	if [ -d "${TEMP}"/initramfs-dropbear-temp ]
	then
		rm -r "${TEMP}"/initramfs-dropbear-temp
	fi

	if [ ! -d /etc/dropbear ]
	then
		mkdir /etc/dropbear
	fi
	if [ ! -e /etc/dropbear/dropbear_rsa_host_key ]
	then
		if [ -e /usr/bin/dropbearconvert -a /etc/ssh/ssh_host_rsa_key ]
		then
			/usr/bin/dropbearconvert openssh dropbear /etc/ssh/ssh_host_rsa_key /etc/dropbear/dropbear_rsa_host_key
		else
			/usr/bin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 4096 > /dev/null
		fi
	fi

	if [ ! -e /etc/dropbear/dropbear_dss_host_key ]
	then
		/usr/bin/dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key > /dev/null
	fi

	cd "${TEMP}" \
				|| gen_die "cd '${TEMP}' failed"
	mkdir -p ${TEMP}/initramfs-dropbear-temp/var/run
	mkdir -p ${TEMP}/initramfs-dropbear-temp/var/log
	mkdir -p ${TEMP}/initramfs-dropbear-temp/etc/dropbear
	mkdir -p ${TEMP}/initramfs-dropbear-temp/bin
	mkdir -p ${TEMP}/initramfs-dropbear-temp/root/.ssh

	cp -L ${GK_SHARE}/defaults/login-remote.sh ${TEMP}/initramfs-dropbear-temp/bin/
	cp -L /etc/dropbear/{dropbear_rsa_host_key,dropbear_dss_host_key} ${TEMP}/initramfs-dropbear-temp/etc/dropbear/
	cp -L /etc/dropbear/authorized_keys ${TEMP}/initramfs-dropbear-temp/root/.ssh
	cp -L /etc/localtime ${TEMP}/initramfs-dropbear-temp/etc/
	mkdir -p ${TEMP}/initramfs-dropbear-temp/lib
	cp -L /lib/libnss_files.so.2 ${TEMP}/initramfs-dropbear-temp/lib/

	sed "s/compat/files/g" /etc/nsswitch.conf > ${TEMP}/initramfs-dropbear-temp/etc/nsswitch.conf
	echo "root:x:0:0:root:/root:/bin/login-remote.sh" > ${TEMP}/initramfs-dropbear-temp/etc/passwd
	echo "/bin/login-remote.sh" > ${TEMP}/initramfs-dropbear-temp/etc/shells
	echo "root:!:0:0:99999:7:::" > ${TEMP}/initramfs-dropbear-temp/etc/shadow
	echo "root:x:0:root" > ${TEMP}/initramfs-dropbear-temp/etc/group
	echo "" > ${TEMP}/initramfs-dropbear-temp/var/log/lastlog

	chmod 0755 ${TEMP}/initramfs-dropbear-temp/bin/login-remote.sh
	chmod 0700 ${TEMP}/initramfs-dropbear-temp/root/.ssh
	chmod 0640 ${TEMP}/initramfs-dropbear-temp/etc/shadow
	chmod 0644 ${TEMP}/initramfs-dropbear-temp/etc/passwd
	chmod 0644 ${TEMP}/initramfs-dropbear-temp/etc/group
	mkfifo ${TEMP}/initramfs-dropbear-temp/etc/dropbear/fifo_root
	mkfifo ${TEMP}/initramfs-dropbear-temp/etc/dropbear/fifo_swap

	copy_binaries "${TEMP}"/initramfs-dropbear-temp/ /usr/sbin/dropbear \
		/bin/login /usr/bin/passwd

	append_to_cpio "${TEMP}"/initramfs-dropbear-temp dropbear
}

append_firmware() {
	if [ -z "${FIRMWARE_FILES}" -a ! -d "${FIRMWARE_SRC}" ]
	then
		gen_die "specified firmware source directory (${FIRMWARE_SRC}) does not exist"
	fi
	if [ -d "${TEMP}/initramfs-firmware-temp" ]
	then
		rm -r "${TEMP}/initramfs-firmware-temp/"
	fi
	mkdir -p "${TEMP}/initramfs-firmware-temp/lib/firmware"
	cd "${TEMP}/initramfs-firmware-temp"
	if [ -n "${FIRMWARE_FILES}" ]
	then
		OLD_IFS=$IFS
		IFS=","
		for i in ${FIRMWARE_FILES}
		do
			cp -L "${i}" ${TEMP}/initramfs-firmware-temp/lib/firmware/
		done
		IFS=$OLD_IFS
	else
		cp -a "${FIRMWARE_SRC}"/* ${TEMP}/initramfs-firmware-temp/lib/firmware/
	fi
	append_to_cpio `pwd` firmware
}

append_gpg() {
	if [ -d "${TEMP}/initramfs-gpg-temp" ]
	then
		rm -r "${TEMP}/initramfs-gpg-temp"
	fi
	cd ${TEMP}
	mkdir -p "${TEMP}/initramfs-gpg-temp/sbin/"
	if [ ! -e ${GPG_BINCACHE} ] ; then
		print_info 1 '		GPG: Adding support (compiling binaries)...'
		compile_gpg
	fi
	bzip2 -dc "${GPG_BINCACHE}" > "${TEMP}/initramfs-gpg-temp/sbin/gpg" ||
		gen_die 'Could not extract gpg binary cache!'
	chmod a+x "${TEMP}/initramfs-gpg-temp/sbin/gpg"
	append_to_cpio "${TEMP}/initramfs-gpg-temp/" gpg
}

print_list()
{
	local x
	for x in ${*}
	do
		echo ${x}
	done
}

append_modules() {
	local group
	local group_modules
	local MOD_EXT=".ko"

	print_info 2 "initramfs: >> Searching for modules..."
	if [ "${INSTALL_MOD_PATH}" != '' ]
	then
	  cd ${INSTALL_MOD_PATH}
	else
	  cd /
	fi

	if [ -d "${TEMP}/initramfs-modules-${KV}-temp" ]
	then
		rm -r "${TEMP}/initramfs-modules-${KV}-temp/"
	fi
	mkdir -p "${TEMP}/initramfs-modules-${KV}-temp/lib/modules/${KV}"
	for i in `gen_dep_list`
	do
		mymod=`find ./lib/modules/${KV} -name "${i}${MOD_EXT}" 2>/dev/null| head -n 1 `
		if [ -z "${mymod}" ]
		then
			print_warning 2 "Warning :: ${i}${MOD_EXT} not found; skipping..."
			continue;
		fi

		print_info 2 "initramfs: >> Copying ${i}${MOD_EXT}..."
		cp -ax --parents "${mymod}" "${TEMP}/initramfs-modules-${KV}-temp"
	done

	cp -ax --parents ./lib/modules/${KV}/modules* ${TEMP}/initramfs-modules-${KV}-temp 2>/dev/null

	mkdir -p "${TEMP}/initramfs-modules-${KV}-temp/etc/modules"
	for group_modules in ${!MODULES_*}; do
		group="$(echo $group_modules | cut -d_ -f2- | tr "[:upper:]" "[:lower:]")"
		print_list ${!group_modules} > "${TEMP}/initramfs-modules-${KV}-temp/etc/modules/${group}"
	done
	cd "${TEMP}/initramfs-modules-${KV}-temp/"
	# module strip:
	find -iname *.ko -exec strip --strip-debug {} \;
	append_to_cpio `pwd` modules
}

append_modprobed() {
	local TDIR="${TEMP}/initramfs-modprobe.d-temp"
	if [ -d "${TDIR}" ]
	then
		rm -r "${TDIR}"
	fi

	mkdir -p "${TDIR}/etc/module_options/"

	# Load module parameters
	for dir in $(find "${MODPROBEDIR}"/*)
	do
		while read x
		do
			case "${x}" in
				options*)
					module_name="$(echo "$x" | cut -d ' ' -f 2)"
					[ "${module_name}" != "$(echo)" ] || continue
					module_options="$(echo "$x" | cut -d ' ' -f 3-)"
					[ "${module_options}" != "$(echo)" ] || continue
					echo "${module_options}" >> "${TDIR}/etc/module_options/${module_name}.conf"
				;;
			esac
		done < "${dir}"
	done

	append_to_cpio "${TDIR}" modprobe.d
}

# check for static linked file with objdump
is_static() {
	LANG="C" LC_ALL="C" objdump -T $1 2>&1 | grep "not a dynamic object" > /dev/null
	return $?
}

append_auxilary() {
	if [ -d "${TEMP}/initramfs-aux-temp" ]
	then
		rm -r "${TEMP}/initramfs-aux-temp/"
	fi
	mkdir -p "${TEMP}/initramfs-aux-temp/etc"
	mkdir -p "${TEMP}/initramfs-aux-temp/sbin"
	if [ -f "${CMD_LINUXRC}" ]
	then
		cp "${CMD_LINUXRC}" "${TEMP}/initramfs-aux-temp/init"
		print_info 2 "		  >> Copying user specified linuxrc: ${CMD_LINUXRC} to init"
	else
		if isTrue ${NETBOOT}
		then
			cp "${GK_SHARE}/netboot/linuxrc.x" "${TEMP}/initramfs-aux-temp/init"
		else
			if [ -f "${GK_SHARE}/arch/${ARCH}/linuxrc" ]
			then
				cp "${GK_SHARE}/arch/${ARCH}/linuxrc" "${TEMP}/initramfs-aux-temp/init"
			else
				cp "${GK_SHARE}/defaults/linuxrc" "${TEMP}/initramfs-aux-temp/init"
			fi
		fi
	fi

	# Make sure it's executable
	chmod 0755 "${TEMP}/initramfs-aux-temp/init"

	# Make a symlink to init .. incase we are bundled inside the kernel as one
	# big cpio.
	cd ${TEMP}/initramfs-aux-temp
	ln -s init linuxrc
#	ln ${TEMP}/initramfs-aux-temp/init ${TEMP}/initramfs-aux-temp/linuxrc

	if [ -f "${GK_SHARE}/arch/${ARCH}/initrd.scripts" ]
	then
		cp "${GK_SHARE}/arch/${ARCH}/initrd.scripts" "${TEMP}/initramfs-aux-temp/etc/initrd.scripts"
	else
		cp "${GK_SHARE}/defaults/initrd.scripts" "${TEMP}/initramfs-aux-temp/etc/initrd.scripts"
	fi

	if [ -f "${GK_SHARE}/arch/${ARCH}/initrd.defaults" ]
	then
		cp "${GK_SHARE}/arch/${ARCH}/initrd.defaults" "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	else
		cp "${GK_SHARE}/defaults/initrd.defaults" "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	fi

	if [ -n "${REAL_ROOT}" ]
	then
		sed -i "s:^REAL_ROOT=.*$:REAL_ROOT='${REAL_ROOT}':" "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	fi

	echo -n 'HWOPTS="$HWOPTS ' >> "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	for group_modules in ${!MODULES_*}; do
		group="$(echo $group_modules | cut -d_ -f2 | tr "[:upper:]" "[:lower:]")"
		echo -n "${group} " >> "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	done
	echo '"' >> "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"

	if [ -f "${GK_SHARE}/arch/${ARCH}/modprobe" ]
	then
		cp "${GK_SHARE}/arch/${ARCH}/modprobe" "${TEMP}/initramfs-aux-temp/sbin/modprobe"
	else
		cp "${GK_SHARE}/defaults/modprobe" "${TEMP}/initramfs-aux-temp/sbin/modprobe"
	fi
	if isTrue $CMD_DOKEYMAPAUTO
	then
		echo 'MY_HWOPTS="${MY_HWOPTS} keymap"' >> ${TEMP}/initramfs-aux-temp/etc/initrd.defaults
	fi
	if isTrue $CMD_KEYMAP
	then
		print_info 1 "		  >> Copying keymaps"
		mkdir -p "${TEMP}/initramfs-aux-temp/lib/"
		cp -R "${GK_SHARE}/defaults/keymaps" "${TEMP}/initramfs-aux-temp/lib/" \
				|| gen_die "Error while copying keymaps"
	fi

	cd ${TEMP}/initramfs-aux-temp/sbin && ln -s ../init init
	cd ${TEMP}
	chmod +x "${TEMP}/initramfs-aux-temp/init"
	chmod +x "${TEMP}/initramfs-aux-temp/etc/initrd.scripts"
	chmod +x "${TEMP}/initramfs-aux-temp/etc/initrd.defaults"
	chmod +x "${TEMP}/initramfs-aux-temp/sbin/modprobe"

	if isTrue ${NETBOOT}
	then
		cd "${GK_SHARE}/netboot/misc"
		cp -pPRf * "${TEMP}/initramfs-aux-temp/"
	fi

	append_to_cpio "${TEMP}/initramfs-aux-temp/" auxilliary_cpio
}

append_data() {
	local name=$1 var=$2
	local func="append_${name}"

	[ $# -eq 0 ] && gen_die "append_data() called with zero arguments"
	if [ $# -eq 1 ] || isTrue ${var}
	then
		print_info 1 "		  >> Appending ${name} cpio data..."
		${func} || gen_die "${func}() failed"
	fi
}

create_initramfs() {
	local compress_ext=""
	print_info 1 "initramfs: >> Initializing..."
	CPIO="${TMPDIR}/initramfs-${KV}"
	# Grab starter cpio archive with device nodes in it (since we can't create these inside an ebuild)
	cp $GK_SHARE/initramfs.cpio "$CPIO" || gk_die "Could not get starter cpio"
	append_data 'base_layout'
	append_data 'auxilary' "${BUSYBOX}"
	append_data 'busybox' "${BUSYBOX}"
	append_data 'lvm' "${LVM}"
	append_data 'dmraid' "${DMRAID}"
	append_data 'iscsi' "${ISCSI}"
	append_data 'mdadm' "${MDADM}"
	append_data 'luks' "${LUKS}"
	append_data 'dropbear' "${SSH}"
	append_data 'multipath' "${MULTIPATH}"
	append_data 'gpg' "${GPG}"

	if [ "${RAMDISKMODULES}" = '1' ]
	then
		append_data 'modules'
	else
		print_info 1 "initramfs: Not copying modules..."
	fi

	append_data 'zfs' "${ZFS}"
	append_data 'btrfs' "${BTRFS}"
	append_data 'blkid' "${DISKLABEL}"
	append_data 'unionfs_fuse' "${UNIONFS}"
	append_data 'splash' "${SPLASH}"
	append_data 'modprobed'

	if isTrue "${FIRMWARE}" && [ -n "${FIRMWARE_SRC}" ]
	then
		append_data 'firmware'
	fi

	# This should always be appended last
	if [ "${INITRAMFS_OVERLAY}" != '' ]
	then
		append_data 'overlay'
	fi

	if isTrue "${INTEGRATED_INITRAMFS}"
	then
		# Explicitly do not compress if we are integrating into the kernel.
		# The kernel will do a better job of it than us.
		mv "$CPIO" "${CPIO}.cpio"
		sed -i '/^.*CONFIG_INITRAMFS_SOURCE=.*$/d' ${BUILD_DST}/.config
		cat >>${BUILD_DST}/.config	<<-EOF
		CONFIG_INITRAMFS_SOURCE="${CPIO}.cpio${compress_ext}"
		CONFIG_INITRAMFS_ROOT_UID=0
		CONFIG_INITRAMFS_ROOT_GID=0
		EOF
	else
		if isTrue "${COMPRESS_INITRD}"
		then
			cmd_xz=$(type -p xz)
			cmd_lzma=$(type -p lzma)
			cmd_bzip2=$(type -p bzip2)
			cmd_gzip=$(type -p gzip)
			cmd_lzop=$(type -p lzop)
			pkg_xz='app-arch/xz-utils'
			pkg_lzma='app-arch/xz-utils'
			pkg_bzip2='app-arch/bzip2'
			pkg_gzip='app-arch/gzip'
			pkg_lzop='app-arch/lzop'
			local compression
			case ${COMPRESS_INITRD_TYPE} in
				xz|lzma|bzip2|gzip|lzop) compression=${COMPRESS_INITRD_TYPE} ;;
				lzo) compression=lzop ;;
				best|fastest)
					for tuple in \
							'CONFIG_RD_XZ	 cmd_xz    xz' \
							'CONFIG_RD_LZMA  cmd_lzma  lzma' \
							'CONFIG_RD_BZIP2 cmd_bzip2 bzip2' \
							'CONFIG_RD_GZIP  cmd_gzip  gzip' \
							'CONFIG_RD_LZO	 cmd_lzop  lzop' \
							'CONFIG_KERNEL_LZMA  cmd_lzma  lzma' \
							'CONFIG_KERNEL_BZIP2 cmd_bzip2 bzip2' \
							'CONFIG_KERNEL_GZIP  cmd_gzip  gzip' \
							'CONFIG_KERNEL_LZO	 cmd_lzop  lzop'; do
						set -- ${tuple}
						kernel_option=$1
						cmd_variable_name=$2
						if grep -q "^${kernel_option}=y" "${BUILD_DST}/.config" && test -n "${!cmd_variable_name}" ; then
							compression=$3
							[[ ${COMPRESS_INITRD_TYPE} == best ]] && break
						fi
					done
					[[ -z "${compression}" ]] && gen_die "None of the initramfs we tried are supported by your kernel (config file \"$BUILD_DST/.config\"), strange!?"
					;;
				*)
					gen_die "Compression '${COMPRESS_INITRD_TYPE}' unknown"
					;;
			esac

			# Check for actual availability
			cmd_variable_name=cmd_${compression}
			pkg_variable_name=pkg_${compression}
			[[ -z "${!cmd_variable_name}" ]] && gen_die "Compression '${compression}' is not available. Please install package '${!pkg_variable_name}'."

			case $compression in
				xz) compress_ext='.xz' compress_cmd="${cmd_xz} -e --check=none -z -f -9" ;;
				lzma) compress_ext='.lzma' compress_cmd="${cmd_lzma} -z -f -9" ;;
				bzip2) compress_ext='.bz2' compress_cmd="${cmd_bzip2} -z -f -9" ;;
				gzip) compress_ext='.gz' compress_cmd="${cmd_gzip} -f -9" ;;
				lzop) compress_ext='.lzo' compress_cmd="${cmd_lzop} -f -9" ;;
			esac

			if [ -n "${compression}" ]; then
				print_info 1 "		  >> Compressing cpio data (${compress_ext})..."
				${compress_cmd} "${CPIO}" || gen_die "Compression (${compress_cmd}) failed"
				mv -f "${CPIO}${compress_ext}" "${CPIO}" || gen_die "Rename failed"
			else
				print_info 1 "		  >> Not compressing cpio data ..."
			fi
		fi
	fi

	if isTrue "${CMD_INSTALL}"
	then
		if ! isTrue "${INTEGRATED_INITRAMFS}"
		then
			copy_image_with_preserve "initramfs" \
				"${CPIO}" \
				"initramfs-${FULLNAME}"
		fi
	fi
}
