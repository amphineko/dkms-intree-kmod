#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROGRAM="dkms-intree-kmod-host"
readonly DEFAULT_CACHE_ROOT="/var/cache/dkms-intree-kmod"

die() {
    printf '[%s] error: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

log() {
    printf '[%s] %s\n' "$PROGRAM" "$*"
}

cleanup() {
    if [[ -n "${stage_dir:-}" && -d "$stage_dir" ]]; then
        rm -rf -- "$stage_dir" || true
    fi
    if [[ -n "${download_dir:-}" && -d "$download_dir" ]]; then
        rm -rf -- "$download_dir" || true
    fi
    if [[ -n "${output_dir:-}" && -d "$output_dir" ]]; then
        rm -rf -- "$output_dir" || true
    fi
}

load_config() {
    config_file="$PWD/dkms.conf"
    [[ -f "$config_file" ]] || die "dkms.conf is missing from the DKMS build directory: $PWD"
    # shellcheck disable=SC1090
    source "$config_file"

    module_name="${BUILT_MODULE_NAME[0]:-}"
    module_name="${module_name%.ko}"
    [[ "$module_name" =~ ^[A-Za-z0-9_-]+$ ]] || \
        die "invalid BUILT_MODULE_NAME[0]: $module_name"

    kernelver="${kernelver:-${KERNELRELEASE:-${KERNEL_RELEASE:-}}}"
    [[ -n "$kernelver" ]] || die "DKMS did not provide kernelver"
    [[ "$kernelver" =~ ^[A-Za-z0-9][A-Za-z0-9._+~_-]*$ ]] || \
        die "invalid kernel release '$kernelver'"
}

check_host_distribution() {
    [[ -r /etc/os-release ]] || \
        die "/etc/os-release is missing; cannot identify the host distribution"
    # shellcheck disable=SC1091
    source /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" fedora "*|*" rhel "*|*" centos "*) ;;
        *) die "host distribution '${PRETTY_NAME:-${ID:-unknown}}' is unsupported; use Fedora or an RHEL-family distribution" ;;
    esac
}

require_command() {
    local command_name="$1"
    local install_hint="$2"
    command -v "$command_name" >/dev/null 2>&1 || die "$install_hint"
}

detect_source_download_option() {
    local download_help
    if ! download_help="$(dnf download --help 2>&1)"; then
        die "the DNF download command is missing; install dnf-plugins-core on DNF4 systems"
    fi

    if [[ "$download_help" == *--srpm* ]]; then
        source_download_option="--srpm"
    elif [[ "$download_help" == *--source* ]]; then
        source_download_option="--source"
    else
        die "the DNF download command cannot fetch source RPMs; install dnf-plugins-core"
    fi
}

require_host_tools() {
    check_host_distribution
    require_command dnf "DNF is required on Fedora/RHEL hosts"
    require_command rpm "RPM is required on Fedora/RHEL hosts"
    require_command flock "flock is required; install util-linux"
    detect_source_download_option
}

resolve_kernel_devel() {
    kernel_devel_host="${KMOD_KERNEL_DEVEL_DIR:-/lib/modules/$kernelver/build}"
    kernel_devel_host="$(readlink -e "$kernel_devel_host")" || \
        die "kernel-devel path does not resolve for $kernelver"
    [[ -f "$kernel_devel_host/Makefile" ]] || \
        die "kernel-devel tree is missing Makefile: $kernel_devel_host"
}

resolve_source_rpm() {
    local source_package="kernel-devel-$kernelver"
    if ! source_rpm="$(rpm -q --qf '%{SOURCERPM}' "$source_package" 2>/dev/null)"; then
        die "matching RPM package '$source_package' is not installed; install kernel-devel for $kernelver"
    fi
    [[ "$source_rpm" =~ ^[A-Za-z0-9._+~_-]+\.src\.rpm$ ]] || \
        die "could not read a valid source RPM name from '$source_package': $source_rpm"

    # dnf download --source takes a binary package spec and maps it to its SRPM.
    source_package_spec="$source_package"
}

initialize_cache() {
    cache_root="${KMOD_SOURCE_CACHE:-$DEFAULT_CACHE_ROOT}"
    srpm_cache="$cache_root/srpm"
    lock_root="$cache_root/locks"
    mkdir -p "$srpm_cache" "$lock_root"

    source_rpm_path="$srpm_cache/$source_rpm"
}

download_source_rpm() {
    local srpm_lock_fd

    # Serialize downloads so concurrent DKMS builds cannot race on one SRPM.
    exec {srpm_lock_fd}>"$lock_root/srpm-download.lock"
    flock "$srpm_lock_fd"

    if [[ ! -s "$source_rpm_path" ]]; then
        log "downloading matching source RPM: $source_rpm"
        download_dir="$(mktemp -d "$srpm_cache/.download.XXXXXX")"
        if ! dnf download "$source_download_option" --destdir "$download_dir" "$source_package_spec"; then
            die "could not download $source_rpm; enable a repository that provides the matching kernel source RPM"
        fi
        [[ -s "$download_dir/$source_rpm" ]] || \
            die "DNF did not download the expected source RPM: $source_rpm"
        mv "$download_dir/$source_rpm" "$source_rpm_path"
        rmdir "$download_dir"
        download_dir=""
    fi

    [[ -s "$source_rpm_path" ]] || \
        die "DNF did not place the expected source RPM in $srpm_cache: $source_rpm"
    local cached_srpm_name
    cached_srpm_name="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.src.rpm' "$source_rpm_path" 2>/dev/null)" || \
        die "cached source RPM is invalid: $source_rpm_path"
    [[ "$cached_srpm_name" == "$source_rpm" ]] || \
        die "cached source RPM identity mismatch: expected $source_rpm, found $cached_srpm_name"
    flock -u "$srpm_lock_fd"
}

select_container_engine() {
    engine="${KMOD_CONTAINER_ENGINE:-}"
    if [[ -z "$engine" ]]; then
        if command -v docker >/dev/null 2>&1; then
            engine="docker"
        elif command -v podman >/dev/null 2>&1; then
            engine="podman"
        else
            die "neither docker nor podman is available"
        fi
    fi
    command -v "$engine" >/dev/null 2>&1 || die "container engine is unavailable: $engine"
}

run_container_build() {
    local image host_uid host_gid container_uid container_gid module_file

    image="${KMOD_IMAGE:-}"
    if [[ -z "$image" ]]; then
        if [[ "${engine##*/}" == podman ]]; then
            image="localhost/dkms-intree-kmod:latest"
        else
            image="dkms-intree-kmod:latest"
        fi
    fi
    output_dir="$(mktemp -d "$PWD/.dkms-intree-output.XXXXXX")"
    host_uid="$(id -u)"
    host_gid="$(id -g)"
    container_uid="$host_uid"
    container_gid="$host_gid"
    if [[ "${engine##*/}" == podman && "$host_uid" != 0 ]]; then
        # Rootless Podman's container UID 0 maps to the invoking host user.
        # Chowning to the host numeric UID inside the container maps to a
        # subordinate host UID and makes the result unreadable to DKMS.
        container_uid=0
        container_gid=0
    fi

    "$engine" run --rm \
        -v "$kernel_devel_host:/kernel-devel:ro" \
        -v "$cache_root:/source-cache:z" \
        -v "$config_file:/config/dkms.conf:ro,z" \
        -v "$output_dir:/out:z" \
        -e "HOST_UID=$container_uid" \
        -e "HOST_GID=$container_gid" \
        "$image" \
        --kernel-release "$kernelver" \
        --kernel-devel /kernel-devel \
        --source-rpm "/source-cache/srpm/$source_rpm" \
        --source-cache /source-cache \
        --config-file /config/dkms.conf

    module_file="$output_dir/$module_name.ko"
    [[ -s "$module_file" ]] || die "container did not produce $module_name.ko"
    cp -f "$module_file" "$PWD/$module_name.ko"
}

main() {
    load_config
    require_host_tools
    resolve_kernel_devel
    resolve_source_rpm
    initialize_cache
    download_source_rpm
    select_container_engine
    run_container_build
}

trap cleanup EXIT
main "$@"
