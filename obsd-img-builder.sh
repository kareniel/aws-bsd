#!/bin/ksh
# Copyright (c) 2021 Jonathan Dupre <jonathan@diagonal.sh>
# Copyright (c) 2015, 2016, 2019 Antoine Jacoutot <ajacoutot@openbsd.org>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -e
umask 022

timestamp=$(date -u +%G%m%dT%H%M%SZ)
workdir=$(mktemp -d -p "${TMPDIR:=/tmp}" aws-ami.XXXXXXXXXX)

log_info() {
	echo "===> ${*}"
}

log_error() {
	echo "${0##*/}: ${1}" 1>&2 && return "${2:-1}"
}

create_install_site() {
	log_info "creating install.site" 
	echo "(XXX bsd.mp + relink directory)"

	cat <<-'EOF' >> "${workdir}/install.site"
	chown root:bin /usr/local/libexec/ec2-init
	chmod 0555 /usr/local/libexec/ec2-init
	echo "!/usr/local/libexec/ec2-init" >>/etc/hostname.vio0
	cp -p /etc/hostname.vio0 /etc/hostname.xnf0
	echo "https://cdn.openbsd.org/pub/OpenBSD" >/etc/installurl
	echo "sndiod_flags=NO" >/etc/rc.conf.local
	echo "permit keepenv nopass ec2-user" >/etc/doas.conf
	rm /install.site
	EOF

	chmod 0555 "${workdir}/install.site"
}

create_install_site_disk() {
	echo "(XXX trap vnd and mount)"

	local _rel _relint _retrydl=true _vndev
	local _siteimg=${workdir}/siteXX.img _sitemnt=${workdir}/siteXX

	[[ ${RELEASE} == snapshots ]] && _rel=$(uname -r) || _rel=${RELEASE}
	_relint=${_rel%.*}${_rel#*.}

	create_install_site

	log_info "creating install_site disk"

	vmctl create -s 1G "$_siteimg"
	_vndev="$(vnconfig "$_siteimg")"
	fdisk -iy "${_vndev}"
	printf "a a\n\n\n\nw\nq\n" | disklabel -E "${_vndev}"
	newfs "${_vndev}a"

	install -d "${_sitemnt}"
	mount "/dev/${_vndev}a" "${_sitemnt}"
	install -d "${_sitemnt}/${_rel}/${ARCH}"

	log_info "downloading installation ISO"
	while ! ftp -o "${workdir}/installXX.iso" \
		"${MIRROR}/${RELEASE}/${ARCH}/install${_relint}.iso"; do
		# in case we're running an X.Y snapshot while X.Z is out;
		# (e.g. running on 6.4-current and installing 6.5-beta)
		${_retrydl} || log_error "cannot download installation ISO"
		_relint=$((_relint+1))
		_retrydl=false
	done

	log_info "downloading ec2-init"
	install -d "${workdir}/usr/local/libexec/"
	ftp -o "${workdir}/usr/local/libexec/ec2-init" \
		"https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/ec2-init.sh"

	log_info "storing siteXX.tgz into install_site disk"
	cd "${workdir}" && \
		tar czf \
			"${_sitemnt}/${_rel}/${ARCH}/site${_relint}.tgz" \
			"./install.site" \
			"./usr/local/libexec/ec2-init"

	umount "${_sitemnt}"
	vnconfig -u "${_vndev}"
}

create_autoinstallconf() {
	local _autoinstallconf=${workdir}/auto_install.conf
	local _mirror=${MIRROR}

	_mirror=${_mirror#*://}
	_mirror=${_mirror%%/*}

	log_info "creating auto_install.conf"

	cat <<-EOF >> "${_autoinstallconf}"
	System hostname = openbsd
	Password for root = *************
	Change the default console to com0 = yes
	Setup a user = ec2-user
	Full name for user ec2-user = EC2 Default User
	Password for user = *************
	What timezone are you in = UTC
	Location of sets = cd
	Set name(s) = done
	EOF

	# XXX if checksum fails
	for i in $(jot 11); do
		echo "Checksum test for = yes" >> "${_autoinstallconf}"
	done
	echo "Continue without verification = yes" >> "${_autoinstallconf}"

	cat <<-EOF >> "${_autoinstallconf}"
	Location of sets = disk
	Is the disk partition already mounted = no
	Which disk contains the install media = sd1
	Which sd1 partition has the install sets = a
	INSTALL.${ARCH} not found. Use sets found here anyway = yes
	Set name(s) = site*
	Checksum test for = yes
	Continue without verification = yes
	EOF
}

create_img() {
	local _bsdrd="${workdir}/bsd.rd" _rdextract="${workdir}/bsd.rd.extract"
	local _rdmnt="${workdir}/rdmnt" _vndev _compress=0

	create_install_site_disk

	create_autoinstallconf

	log_info "creating modified bsd.rd for autoinstall"
	ftp -MV -o "${_bsdrd}" "${MIRROR}/${RELEASE}/${ARCH}/bsd.rd"

	# 6.9 onwards has a compressed rd file
	# bsd.rd: gzip compressed data, max compression, from Unix
	set +e
	file "${_bsdrd}" | grep "gzip compressed data"
	if [ $? = "0" ]; then
		log_info "decompressing bsd.rd"
		# bsd.rd is compressed, decompress it so rdsetroot works
		_compress=1
		mv "${_bsdrd}" "${_bsdrd}.gz"
		gunzip "${_bsdrd}.gz"
	fi
	set -e

	rdsetroot -x "${_bsdrd}" "${_rdextract}"
	_vndev=$(vnconfig "${_rdextract}")
	install -d "${_rdmnt}"
	mount "/dev/${_vndev}a" "${_rdmnt}"
	cp "${workdir}/auto_install.conf" "${_rdmnt}"
	umount "${_rdmnt}"
	vnconfig -u "${_vndev}"
	rdsetroot "${_bsdrd}" "${_rdextract}"
	rdsetroot -x "${_bsdrd}" "${_rdextract}"

	if [ "${_compress}" = "1" ]; then	
		log_info "recompressing bsd.rd"
		# 6.9 onwards
		gzip "${_bsdrd}"
		mv "${_bsdrd}.gz" "${_bsdrd}"
	fi

	log_info "starting autoinstall inside vmm(4)"

	vmctl create -s "${IMGSIZE}G" "${IMGPATH}"

	# handle cu(1) EOT
	(sleep 10 && vmctl wait "${_IMGNAME}" && _tty=$(get_tty "${_IMGNAME}") &&
		vmctl stop -f "${_IMGNAME}" && pkill -f "/usr/bin/cu -l ${_tty}")&

	# XXX handle installation error
	# (e.g. ftp: raw.githubusercontent.com: no address associated with name)
	vmctl start -b "${workdir}/bsd.rd" -c -L -d "${IMGPATH}" -d \
		"${workdir}/siteXX.img" -r "${workdir}/installXX.iso" "${_IMGNAME}"
}

get_tty() {
	local _tty _vmname=$1
	[[ -n ${_vmname} ]]

	vmctl status | grep "${_vmname}" | while read -r _ _ _ _ _ _tty _; do
		echo "/dev/${_tty}"
	done
}

setup_vmd() {
	vmd_running=$(rcctl check vmd > /dev/null)

	if ! $vmd_running; then
		log_info "starting vmd(8)"
		rcctl start vmd
		_RESET_VMD=true
	fi
}

trap_handler() {
	set +e # we're trapped

	if aws iam get-role --role-name "${_IMGNAME}" >/dev/null 2>&1; then
		log_info "removing IAM role"
		aws iam delete-role-policy --role-name "${_IMGNAME}" \
			--policy-name "${_IMGNAME}" 2>/dev/null
		aws iam delete-role --role-name "${_IMGNAME}" 2>/dev/null
	fi

	if ${_RESET_VMD:-false}; then
		log_info "stopping vmd(8)"
		rcctl stop vmd >/dev/null
	fi

	if [[ -n ${workdir} ]]; then
		rmdir "${workdir}" 2>/dev/null ||
			log_info "work directory: ${workdir}"
	fi
}

usage() {
	echo "usage: ${0##*/}
       -a \"architecture\" -- default to \"amd64\"
       -d \"description\" -- AMI description; defaults to \"openbsd-\$release-\$timestamp\"
       -i \"path to RAW image\" -- use image at path instead of creating one
       -m \"install mirror\" -- defaults to installurl(5) or \"https://cdn.openbsd.org/pub/OpenBSD\"
       -n -- only create a RAW image (don't convert to an AMI nor push to AWS)
       -r \"release\" -- e.g \"6.5\"; default to \"snapshots\"
       -s \"image size in GB\" -- default to \"12\""

	return 1
}

while getopts a:d:i:m:nr:s: arg; do
	case ${arg} in
	a)	ARCH="${OPTARG}" ;;
	d)	DESCR="${OPTARG}" ;;
	i)	IMGPATH="${OPTARG}" ;;
	m)	MIRROR="${OPTARG}" ;;
	n)	CREATE_AMI=false ;;
	r)	RELEASE="${OPTARG}" ;;
	s)	IMGSIZE="${OPTARG}" ;;
	*)	usage ;;
	esac
done

trap 'trap_handler' EXIT
trap exit HUP INT TERM

ARCH=${ARCH:-amd64}
CREATE_AMI=${CREATE_AMI:-true}
IMGSIZE=${IMGSIZE:-12}
RELEASE=${RELEASE:-snapshots}

if [[ -z ${MIRROR} ]]; then
	MIRROR=$(while read -r _line; do _line=${_line%%#*}; [[ -n ${_line} ]] &&
		print -r -- "${_line}"; done </etc/installurl | tail -1) \
		2>/dev/null
	[[ ${MIRROR} == @(http|https)://* ]] ||
		MIRROR="https://cdn.openbsd.org/pub/OpenBSD"
fi

_IMGNAME=openbsd-${RELEASE}-${ARCH}-${timestamp}

[[ ${RELEASE} == snapshots ]] &&
	_IMGNAME=${_IMGNAME%snapshots*}current${_IMGNAME#*snapshots}

[[ -n ${IMGPATH} ]] && _IMGNAME=${IMGPATH##*/} ||
	IMGPATH=${workdir}/${_IMGNAME}

DESCR=${DESCR:-${_IMGNAME}}

readonly _IMGNAME timestamp workdir
readonly CREATE_AMI DESCR IMGPATH IMGSIZE MIRROR RELEASE

# requirements checks to build the RAW image
if [[ ! -f ${IMGPATH} ]]; then
	(($(id -u) != 0)) && log_error "need root privileges"
	grep -q ^vmm0 /var/run/dmesg.boot || log_error "need vmm(4) support"
	[[ "${_IMGNAME}}" != [[:alpha:]]* ]] &&
		log_error "image name must start with a letter"
fi

if [[ ! -f ${IMGPATH} ]]; then
	setup_vmd
	create_img
fi
