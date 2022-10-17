#!/bin/bash

default_vars() {
    # An nginx caching proxy is expected but not required. Multiple downloads of
    # the same file happen during the bootstrap process.
    SDB_PROXY="${SDB_PROXY:-}"

    SDB_PARALLEL="${SDB_PARALLEL:-$(getconf _NPROCESSORS_ONLN)}"

    ## Aarch64/arm64 builds would export these vars
    #SDB_ARCH="arm64"
    #SDB_APT_SOURCES_URL="ports.ubuntu.com/ubuntu-ports"
    SDB_ARCH="${SDB_ARCH:-amd64}"
    SDB_APT_SOURCES_URL="${SDB_APT_SOURCES_URL:-archive.ubuntu.com/ubuntu}"
    SDB_APT_RELEASE="${SDB_APT_RELEASE:-jammy}"

    # HACK: Having the user pass a bash array for packages is problematic
    #       statically defining my desired endstate for now
    SDB_APT_COMPONENTS=(
        main
        universe
        multiverse
        restricted
    )


    # Internal variables used during execution
    __internal_vars
}

__internal_vars() {
    __PACKAGES_FETCHED=0
    __AWK_FIND_PACKAGE_HASH='
        $0 ~ "^" hashtype ":" { hashsection=1 }
        $0 ~ filename && hashsection { print $1 }
    '

    __AWK_FIND_REQUIRED_PACKAGES='
        /^Package:/ { pkgname=$2 }
        /^Priority:/ && $2 == "required" { print pkgname }
    '

    __AWK_FIND_PACKAGES_FILENAMES='
        BEGIN {
            split(PKGS, pkgs, ",")
        }
        /^Package:/ {
            for (pkg in pkgs) {
                if (pkgs[pkg] == $2) {
                    needed=1
                }
            }
        }
        /^Filename:/ && needed {
            array_length = split($2, urlpath, "/")
            url = urlprefix "/" $2
            out = outputdir "/" urlpath[array_length]
            print "url=" url
            print "output=" out
            needed=0;
        }
    '
}

fetch_packages_list() {
    [[ ${__PACKAGES_FETCHED} != 0 ]] && return

    # HACK: take first component in list (hopefully its main lol)
    #       seriously though, this needs to be main and this function should
    #       fetch multiple lists kinda like apt does....
    local component="${SDB_APT_COMPONENTS}"

    local base_url="http://${SDB_APT_SOURCES_URL}/dists/${SDB_APT_RELEASE}"
    local inrelease_url="${base_url}/InRelease"
    __INRELEASE=$(curl --proxy "${SDB_PROXY}" "${inrelease_url}")

    local hashtype="SHA256"
    local filename="${component}/binary-${SDB_ARCH}/Packages.xz"
    local package_hash=$( \
        awk -v hashtype="${hashtype}" \
            -v filename="${filename}" \
            "${__AWK_FIND_PACKAGE_HASH}" <<< "${__INRELEASE}"
    )

    local packages_url="${base_url}/${component}/binary-${SDB_ARCH}"
    packages_url="${packages_url}/by-hash/${hashtype}/${package_hash}"
    __PACKAGES=$(curl --proxy "${SDB_PROXY}" "${packages_url}" | xz -d)

    __PACKAGES_FETCHED=1
}

download_pkgs() {
    local target="$1"; shift
    local -n __pkgs="$1"; shift

    # Populate our packages "cache" in memory
    [[ ${__PACKAGES_FETCHED} == 0 ]] && fetch_packages_list

    # Add all packages with 'Priority: Required'
    __pkgs+=( $(awk "${__AWK_FIND_REQUIRED_PACKAGES}" <<< "${__PACKAGES}") )

    # Convert bash array into comma,seperated,string
    local pkgs_csv="$(IFS=,; echo "${__pkgs[*]}")"

    local curl_list="${target}/sdb_temp/curl.txt"
    awk -v urlprefix="http://${SDB_APT_SOURCES_URL}" \
        -v outputdir="${target}/sdb_temp" \
        -v PKGS="${pkgs_csv}" \
        "${__AWK_FIND_PACKAGES_FILENAMES}" > "${curl_list}" <<< "${__PACKAGES}"

    curl --parallel \
         --parallel-immediate \
         --parallel-max ${SDB_PARALLEL} \
         --proxy "${SDB_PROXY}" \
         --config ${curl_list}
}

populate_tar_compression_opts() {
    local -n arr="$1";           shift
    local compression_type="$1"; shift

    case "${compression_type}" in
        bz2) arr+=(--bzip2) ;;
        gz)  arr+=(--gzip) ;;
        xz)  arr+=(--xz) ;;
        zst) arr+=(--zstd) ;;
        tar) ;;
        *)   echo "WARNING: There is an unknown archive extention, letting " \
                  "tar attempt decompression anyway -- ${compression_type}"  \
             ;;
    esac
}

extract_pkg() {
    local target="$1"; shift
    local pkg="$1";    shift
    local extention="$(ar -t ${pkg} | awk -F. '/^data.tar/ {print $(NF)}')"
    local tar_opts=(
        --verbose
        --file -
        --extract
        --keep-old-files        # don't replace links; failure if file exists
        --directory "${target}"
    )
    populate_tar_compression_opts tar_opts "${extention}"
    ar -p "${pkg}" "data.tar.${extention}" | tar "${tar_opts[@]}"
}

install_pkgs() {
    local target="$1";  shift
    local debs=( $(
        find "${target}/sdb_temp" -name '*.deb' -printf '/sdb_temp/%f\n'
    ) )

    # unpack all packages
    # The binaries and libraries needed to run dpkg are extracted properly,
    # however, dpkg itself did not extract them so it has not updated its
    # database for version reasons.
    # This will throw dependancy warnings, but it should not throw any errors
    systemd-nspawn \
        --setenv PATH=/sbin:/bin \
        --setenv DEBIAN_FRONTEND=noninteractive \
        --setenv DEBCONF_NONINTERACTIVE_SEEN=true \
        --directory "${target}" \
            dpkg \
                --force-depends \
                --unpack \
                "${debs[@]}"

    # run configure on all packages
    # We do not need to force any depends because all installed versions should
    # be compatible with each other (trusting the mirror heavily here)
    systemd-nspawn \
        --setenv PATH=/sbin:/bin \
        --setenv DEBIAN_FRONTEND=noninteractive \
        --setenv DEBCONF_NONINTERACTIVE_SEEN=true \
        --directory "${target}" \
            dpkg \
                --force-configure-any \
                --force-confnew \
                --force-overwrite \
                --configure \
                --pending
}

bootstrap_config() {
    local target="$1"; shift

    # HACK: called by libc in preinst but dpkg hasnt created the symlink yet
    #       ultimately, these links get overriden once all of the packages have
    #       run dpkg postinst properly
    [[ ! -f "${target}/usr/bin/which" ]] && ln -s /usr/bin/which.debianutils "${target}/usr/bin/which"
    [[ ! -f "${target}/usr/bin/awk"   ]] && ln -s /usr/bin/mawk              "${target}/usr/bin/awk"
    touch ${target}/var/lib/dpkg/status

    # Install apt and dpkg configs
    cat <<-EOF > "${target}/etc/apt/sources.list"
	deb http://${SDB_APT_SOURCES_URL} ${SDB_APT_RELEASE}           ${SDB_APT_COMPONENTS[@]}
	deb http://${SDB_APT_SOURCES_URL} ${SDB_APT_RELEASE}-updates   ${SDB_APT_COMPONENTS[@]}
	deb http://${SDB_APT_SOURCES_URL} ${SDB_APT_RELEASE}-backports ${SDB_APT_COMPONENTS[@]}
	deb http://${SDB_APT_SOURCES_URL} ${SDB_APT_RELEASE}-security  ${SDB_APT_COMPONENTS[@]}
	EOF

    if [[ ! -z "${SDB_PROXY}" ]]; then
        cat <<-EOF > "${target}/etc/apt/apt.conf.d/99-proxy"
		Acquire {
		  HTTP::proxy  "${SDB_PROXY}";
		  HTTPS::proxy "${SDB_PROXY}";
		}
		EOF
    fi
    cat <<-EOF > "${target}/etc/apt/apt.conf.d/99-overrides"
	Acquire {
	  Languages "none";
	}
	Apt {
	  Install-Recommends "0";
	  Install-Suggests   "0";
	}
	EOF

    # do not call 'sync' when installing packages with dpkg
    cat <<-EOF > "${target}/etc/dpkg/dpkg.cfg.d/99-overrides"
	force-unsafe-io
	EOF


    #####
    # Prevent services from starting during the build process 
    #####
    local prevent_service_startup=(
        "${target}/usr/sbin/policy-rc.d"
        "${target}/usr/sbin/start-stop-daemon"
        "${target}/usr/sbin/initctl"
    )
    # make a backup of existing files
    for path in "${prevent_service_startup[@]}"; do
        [[ ! -f "${path}" ]] && continue
        mv "${path}"{,.REAL}
    done

    cat <<-EOF > "${target}/usr/sbin/policy-rc.d"
	#!/bin/sh
	exit 101
	EOF

    cat <<-EOF > "${target}/usr/sbin/start-stop-daemon"
	#!/bin/sh
	echo -e "\nWarning: Fake start-stop-daemon called, doing nothing"
	EOF

    cat <<-EOF > "${target}/usr/sbin/initctl"
	#!/bin/bash
	[[ "\$1" == version ]] && exec /usr/sbin/initctl.REAL "\$@"
	echo -e "\nWarning: Fake initctl called, doing nothing"
	EOF

    chmod 755 "${prevent_service_startup[@]}"
}

bootstrap_base() {
    local target="$1"; shift
    local pkgs=()
    download_pkgs "${target}" pkgs

    for deb in ${target}/sdb_temp/*.deb; do
        extract_pkg "${target}" "${deb}"
    done
    bootstrap_config  "${target}"
}

install_base() {
    local target="$1"; shift
    local pkgs=()
    local debs=()

    # HACK
    # Even in debootstrap, these deps are spelled out explicitly... All the info
    # we need to make this list exists in the $__PACKAGES variable. maybe some
    # more awk magic makes this hardcoded list go away?
    # all of these are all non-duplicate requirements listed for apt
    pkgs+=( apt )
    # Add direct apt requirements
    pkgs+=(
        adduser
        gpgv
        libapt-pkg6.0
        libgnutls30
        libseccomp2
        libstdc++6
        ubuntu-keyring
    )
    # Add dependencies of direct apt requirements
    pkgs+=(
        libffi8
        libhogweed6
        libidn2-0
        libnettle8
        libp11-kit0
        libtasn1-6
        libunistring2
        libxxhash0
    )
    #ENDHACK

    download_pkgs "${target}" pkgs
    install_pkgs  "${target}"
}

setup_root_fs() {
    local target="$1"; shift
    if [[ ! -d "${target}" ]]; then
        mkdir "${target}"
    fi

    #####
    # aka $MERGED_USR in debootstrap
    #
    # Example output for "amd64" arch:
    #   ${target}/bin -> usr/bin
    #   ${target}/dev
    #   ${target}/etc
    #   ${target}/lib -> usr/lib
    #   ${target}/lib32 -> usr/lib32
    #   ${target}/lib64 -> usr/lib64
    #   ${target}/libx32 -> usr/libx32
    #   ${target}/sbin -> usr/sbin
    #   ${target}/usr
    #####
    local mkdir_list=(
        "${target}/usr"
        "${target}/dev"
        "${target}/etc"
        "${target}/sdb_temp" # used to transfer deb files before dpkg is init
    )
    local symlinks=()

    # `;&` syntax in the case statement indicates fallthrough matching; neat!
    case "${SDB_ARCH}" in
        amd64)      symlinks+=(lib64) ;&
        amd64|i386) symlinks+=(lib32 libx32) ;&
        *)          symlinks+=(bin sbin lib) ;;
    esac
    # ${symlinks[@]} will now contain, at minimum, ("bin" "sbin" lib")
  
    for link_dir in "${symlinks[@]}"; do
        mkdir_list+=("${target}/usr/${link_dir}")
    done

    mkdir "${mkdir_list[@]}"
    for link in "${symlinks[@]}"; do
        ln -s "usr/${link}" "${target}/${link}"
    done

    #####
    # Setup /dev
    #   Requires linux CAP_MKNOD permissions to make the device nodes
    #####
    local devices=(
        "null    c 1 3"
        "zero    c 1 5"
        "full    c 1 7"
        "random  c 1 8"
        "urandom c 1 9"
        "tty     c 5 0"
        "console c 5 1"
        "ptmx    c 5 2"
    )
    for dev in "${devices[@]}"; do
        set -- ${dev}
        mknod -m 666 ${target}/dev/$@  # requires linux CAP_MKNOD
    done
    mkdir "${target}/dev/pts" "${target}/dev/shm"
    ln -s /proc/self/fd   "${target}/dev/fd"
    ln -s /proc/self/fd/0 "${target}/dev/stdin"
    ln -s /proc/self/fd/1 "${target}/dev/stdout"
    ln -s /proc/self/fd/2 "${target}/dev/stderr"
}

nspawn_wrapper() {
    local target="$1"; shift
    # pass through all args to nspawn
    systemd-nspawn \
        --setenv DEBIAN_FRONTEND=noninteractive \
        --directory "${target}" \
        "$@"
}

cleanup() {
    local target="$1"; shift
    local files_to_remove=(
        "${target}/etc/apt/apt.conf.d/99-proxy"
        "${target}/etc/apt/apt.conf.d/99-overrides"
        "${target}/etc/dpkg/dpkg.cfg.d/99-overrides"
    )
    local prevent_service_startup=(
        "${target}/usr/sbin/policy-rc.d"
        "${target}/usr/sbin/start-stop-daemon"
        "${target}/usr/sbin/initctl"
    )
    rm -f "${files_to_remove[@]}" "${prevent_service_startup[@]}"

    # restore original startup files if they exist
    for path in "${prevent_service_startup[@]}"; do
        [[ ! -f "${path}.REAL" ]] && continue
        mv "${path}"{.REAL,}
    done

    # cleanup after apt
    nspawn_wrapper "${target}" apt-get autoremove --purge -y
    nspawn_wrapper "${target}" apt-get autoclean
    nspawn_wrapper "${target}" apt-get clean

    # excessive cleanup
    local folders_to_remove=(
        "${target}/sdb_temp"
        "${target}/usr/share/doc"
        "${target}/usr/share/man"
        "${target}/var/lib/apt/lists"
    )
    rm -r "${folders_to_remove[@]}"

    # sync the disk because dpkg has 'force-unsafe-io`
    sync "${target}"
}

sdb_usage() {
    default_vars
    cat <<-EOF
	Usage: sdb /path/to/bootstrap
	Current Configuration:
	    SDB_PROXY="${SDB_PROXY}"
	    SDB_APT_RELEASE="${SDB_APT_RELEASE}"
	    SDB_APT_SOURCES_URL="${SDB_APT_SOURCES_URL}"
	    SDB_ARCH="${SDB_ARCH}"
	    SDB_MINIMAL="${SDB_MINIMAL}"
	    SDB_APT_COMPONENTS="${SDB_APT_COMPONENTS[@]}"
	EOF
}

# This function should not be called directly, only via subshells or sdb()
_sdb() {
    if [[ ! -v 1 ]]; then
        sdb_usage
        exit 1
    fi
    set -eEuxo pipefail

    default_vars
    local target="$1"; shift
    trap 'rc=$?; echo "ERR at line ${LINENO} (rc: $rc)"; exit $rc' ERR

    cat <<-EOF
	########
	# Stage 1
	#   * all commands execute in host environment using host tools
	#   * any architecture can be targeted for extraction
	#   * base filesystem layout is established
	#   * deb packages marked as 'Priority: required' are unpacked
	########
	EOF
    setup_root_fs  "${target}"
    bootstrap_base "${target}"

    # the target is now similar to a first stage 'debootstrap --foreign'

    cat <<-EOF
	########
	# Stage 2
	#   * commands are executed using systemd-nspawn
	#   * fully supports running foreign architectures
	#   * all packages marked 'Priority: required' are installed with dpkg
	#   * apt and its dependencies of dependencies are installed with dpkg
	#   * apt update/upgrade system
	########
	EOF
    install_base   "${target}"
    nspawn_wrapper "${target}" apt-get update
    nspawn_wrapper "${target}" apt-get dist-upgrade -y
    cleanup "${target}"
    cat <<-EOF
	########
	# All Done!
	#
	# Target directory ("${target}")
	# has been bootstrapped with dpkg/apt, but not an init system.
	#
	# Use 'systemd-nspawn -D "${target}" bash' to spawn a shell
	########
	EOF
}

sdb() {
    # If you source this script and call _sdb directly, any failure will exit
    # your main shell. This wrapper ensures that all of the shell changes
    # happen in a subshell and do not propogate to the main bash shell.
    (_sdb "$@")
}

# AKA --python-- if __name__ == '__main__':
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && sdb "$@"
