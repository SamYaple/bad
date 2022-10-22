#!/bin/bash

default_vars() {
    # An nginx caching proxy is expected but not required. Multiple downloads of
    # the same file happen during the bootstrap process.
    BAD_PROXY="${BAD_PROXY:-}"

    BAD_PARALLEL="${BAD_PARALLEL:-$(getconf _NPROCESSORS_ONLN)}"

    ## Aarch64/arm64 builds would export these vars
    #BAD_ARCH="arm64"
    #BAD_APT_SOURCES_URL="ports.ubuntu.com/ubuntu-ports"
    BAD_ARCH="${BAD_ARCH:-amd64}"
    BAD_APT_SOURCES_URL="${BAD_APT_SOURCES_URL:-archive.ubuntu.com/ubuntu}"
    BAD_APT_RELEASE="${BAD_APT_RELEASE:-jammy}"

    # HACK: Having the user pass a bash array for packages is problematic
    #       statically defining my desired endstate for now
    BAD_APT_COMPONENTS=(
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

    __AWK_FIND_PACKAGES_BY_PRIORITY='
        /^Package:/ { pkgname=$2 }
        /^Priority:/ && $2 == priority { print pkgname }
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
    local component="${BAD_APT_COMPONENTS}"

    local base_url="http://${BAD_APT_SOURCES_URL}/dists/${BAD_APT_RELEASE}"
    local inrelease_url="${base_url}/InRelease"
    __INRELEASE=$(curl --proxy "${BAD_PROXY}" "${inrelease_url}")

    local hashtype="SHA256"
    local filename="${component}/binary-${BAD_ARCH}/Packages.xz"
    local package_hash=$( \
        awk -v hashtype="${hashtype}" \
            -v filename="${filename}" \
            "${__AWK_FIND_PACKAGE_HASH}" <<< "${__INRELEASE}"
    )

    local packages_url="${base_url}/${component}/binary-${BAD_ARCH}"
    packages_url="${packages_url}/by-hash/${hashtype}/${package_hash}"
    __PACKAGES=$(curl --proxy "${BAD_PROXY}" "${packages_url}" | xz -d)

    __PACKAGES_FETCHED=1
}

download_pkgs() {
    local target="$1"; shift
    local -n __pkgs="$1"; shift

    # Populate our packages "cache" in memory
    [[ ${__PACKAGES_FETCHED} == 0 ]] && fetch_packages_list

    # Convert bash array into comma,seperated,string
    local pkgs_csv="$(IFS=,; echo "${__pkgs[*]}")"

    local curl_list="${target}/bad_temp/curl.txt"
    awk -v urlprefix="http://${BAD_APT_SOURCES_URL}" \
        -v outputdir="${target}/bad_temp" \
        -v PKGS="${pkgs_csv}" \
        "${__AWK_FIND_PACKAGES_FILENAMES}" > "${curl_list}" <<< "${__PACKAGES}"

    curl --parallel \
         --parallel-immediate \
         --parallel-max ${BAD_PARALLEL} \
         --proxy "${BAD_PROXY}" \
         --config ${curl_list}
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
    case "${extention}" in
        bz2) tar_opts+=(--bzip2) ;;
        gz)  tar_opts+=(--gzip) ;;
        xz)  tar_opts+=(--xz) ;;
        zst) tar_opts+=(--zstd) ;;
        tar) ;;
        *)   echo "WARNING: There is an unknown archive extention, letting " \
                  "tar attempt decompression anyway -- ${compression_type}"  \
             ;;
    esac
    ar -p "${pkg}" "data.tar.${extention}" | tar "${tar_opts[@]}"
}

install_pkgs() {
    local target="$1";  shift
    local debs=( $(
        find "${target}/bad_temp" -name '*.deb' -printf '/bad_temp/%f\n'
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

    # Install apt and dpkg configs
    cat <<-EOF > "${target}/etc/apt/sources.list"
	deb http://${BAD_APT_SOURCES_URL} ${BAD_APT_RELEASE}           ${BAD_APT_COMPONENTS[@]}
	deb http://${BAD_APT_SOURCES_URL} ${BAD_APT_RELEASE}-updates   ${BAD_APT_COMPONENTS[@]}
	deb http://${BAD_APT_SOURCES_URL} ${BAD_APT_RELEASE}-backports ${BAD_APT_COMPONENTS[@]}
	deb http://${BAD_APT_SOURCES_URL} ${BAD_APT_RELEASE}-security  ${BAD_APT_COMPONENTS[@]}
	EOF

    if [[ ! -z "${BAD_PROXY}" ]]; then
        cat <<-EOF > "${target}/etc/apt/apt.conf.d/99-proxy"
		Acquire {
		  HTTP::proxy  "${BAD_PROXY}";
		  HTTPS::proxy "${BAD_PROXY}";
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

populate_pkgs_from_priority() {
    local -n __pkgs="$1"; shift
    local priority="$1";  shift

    # Populate our packages "cache" in memory
    [[ ${__PACKAGES_FETCHED} == 0 ]] && fetch_packages_list

    # Add all packages with 'Priority: required'
    __pkgs+=( $( \
        awk -v priority="${priority}" \
            "${__AWK_FIND_PACKAGES_BY_PRIORITY}" <<< "${__PACKAGES}"
    ) )
}

bootstrap_base() {
    local target="$1"; shift
    local pkgs=()
    populate_pkgs_from_priority pkgs "required"
    download_pkgs "${target}" pkgs

    for deb in ${target}/bad_temp/*.deb; do
        extract_pkg "${target}" "${deb}"
    done
    bootstrap_config  "${target}"
}

install_base() {
    local target="$1"; shift
    local pkgs=()
    populate_pkgs_from_priority pkgs "required"

    # Instead of manually declaring apt, we can use the "important" tag to get
    # apt plus the most common utilities you would expect
    # TODO: This is too bloated for a container base, but im more comfortable
    #       with this than manually declaring deps
    populate_pkgs_from_priority pkgs "important"

    # Even more packages, including snap and other very non-essential bits
    #populate_pkgs_from_priority pkgs "standard"

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
        "${target}/bad_temp" # used to transfer deb files before dpkg is init
    )
    local symlinks=()

    # `;&` syntax in the case statement indicates fallthrough matching; neat!
    case "${BAD_ARCH}" in
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
        "${target}/bad_temp"
        "${target}/usr/share/doc"
        "${target}/usr/share/man"
        "${target}/var/lib/apt/lists"
    )
    rm -r "${folders_to_remove[@]}"

    # sync the disk because dpkg has 'force-unsafe-io`
    sync "${target}"
}

bad_usage() {
    default_vars
    cat <<-EOF
	Usage: ./bad.bash /path/to/bootstrap
	Current Configuration:
	    BAD_PROXY="${BAD_PROXY}"
	    BAD_APT_RELEASE="${BAD_APT_RELEASE}"
	    BAD_APT_SOURCES_URL="${BAD_APT_SOURCES_URL}"
	    BAD_ARCH="${BAD_ARCH}"
	    BAD_MINIMAL="${BAD_MINIMAL}"
	    BAD_APT_COMPONENTS="${BAD_APT_COMPONENTS[@]}"
	EOF
}

# This function should not be called directly, only via subshells or bad()
_bad() {
    if [[ ! -v 1 ]]; then
        bad_usage
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
	# Target directory ("${target}") has been bootstrapped
	########
	EOF
}

bad() {
    # If you source this script and call _bad directly, any failure will exit
    # your main shell. This wrapper ensures that all of the shell changes
    # happen in a subshell and do not propogate to the main bash shell.
    (_bad "$@")
}

# AKA --python-- if __name__ == '__main__':
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && bad "$@"
