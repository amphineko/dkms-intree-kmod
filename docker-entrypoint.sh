#!/usr/bin/env bash
set -Eeuo pipefail

shopt -s nullglob

readonly PROGRAM="dkms-intree-kmod"
readonly DEFAULT_CONFIG_FILE="/etc/dkms-intree-kmod/dkms.conf"
readonly DEFAULT_KERNEL_TREE="/kernel-devel"
readonly DEFAULT_OUTPUT_DIR="/out"
readonly DEFAULT_SOURCE_CACHE="/source-cache"
readonly DEFAULT_PATCH_DIR="/patches"

config_file="${KMOD_CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
kernel_tree="${KERNEL_DEVEL:-$DEFAULT_KERNEL_TREE}"
source_tree="${KERNEL_SOURCE:-}"
kernel_release="${KERNEL_RELEASE:-}"
target_distro=""
target_distro_version=""
output_dir="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
source_rpm_path="${SOURCE_RPM:-}"
source_cache="${SOURCE_CACHE:-$DEFAULT_SOURCE_CACHE}"
patch_dir="${KMOD_PATCH_DIR:-$DEFAULT_PATCH_DIR}"
stage_dir=""

log() {
    printf '[%s] %s\n' "$PROGRAM" "$*"
}

warn() {
    printf '[%s] warning: %s\n' "$PROGRAM" "$*" >&2
}

die() {
    printf '[%s] error: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
        rm -rf -- "$stage_dir" || true
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Build the module named by BUILT_MODULE_NAME[0] in dkms.conf.

Usage:
  dkms-intree-kmod [options]

Options:
  --kernel-devel DIR        Mounted kernel source/devel tree (default: /kernel-devel)
  --kernel-source DIR       Full kernel source tree (default: /kernel-source when present,
                            otherwise /kernel-devel)
  --kernel-release VER      Kernel release; auto-detected when omitted
  --target-distro DISTRO    RPM target distro (fedora or rhel; required with --source-rpm)
  --target-distro-version N RPM target distro version (required with --source-rpm)
  --source-rpm FILE         Prepare this matching kernel source RPM
  --source-cache DIR        Cache prepared kernel sources (default: /source-cache)
  --patch-dir DIR           Module patch directory (default: /patches)
  --output DIR              Output directory (default: /out)
  --config-file FILE        Override the image's dkms.conf
  --help                    Show this help

The host-side DKMS wrapper builds the container image on first use, then runs
it with the host kernel-devel tree mounted at /kernel-devel.
EOF
}

require_value() {
    (($# >= 2)) || die "option $1 needs a value"
    [[ -n "$2" ]] || die "option $1 needs a non-empty value"
}

prepared_source_cache_valid() {
    local prepared_source="$1"
    local expected_source_rpm="$2"
    local source_dir="$prepared_source/tree"

    [[ -s "$prepared_source/.source-rpm" && \
       "$(<"$prepared_source/.source-rpm")" == "$expected_source_rpm" && \
       -f "$source_dir/Makefile" && \
       -f "$source_dir/init/main.c" ]]
}

prepare_source_tree() {
    local safe_release="$1"
    local prepared_parent="$2"
    local prepared_source="$3"
    local expected_source_rpm="$4"
    local rpmbuild_topdir prep_log
    local -a spec_files rpmbuild_distro_args=()
    local main_source_file="" candidate source_candidate

    stage_dir="$(mktemp -d "$source_cache/staging-${safe_release}.XXXXXX")"
    rpmbuild_topdir="$stage_dir/rpmbuild"
    mkdir -p "$rpmbuild_topdir"
    log "preparing kernel source RPM: $expected_source_rpm"
    rpm -i --nodeps --define "_topdir $rpmbuild_topdir" "$source_rpm_path"

    spec_files=("$rpmbuild_topdir"/SPECS/*.spec)
    ((${#spec_files[@]} == 1)) || \
        die "expected one spec file in $expected_source_rpm; found ${#spec_files[@]}"

    # The build image's macros describe Fedora. Set the host target explicitly
    # and remove the opposite distro macro before evaluating the source spec.
    case "$target_distro" in
        fedora)
            rpmbuild_distro_args+=(--undefine=rhel --define "fedora $target_distro_version")
            ;;
        rhel)
            rpmbuild_distro_args+=(--undefine=fedora --define "rhel $target_distro_version")
            ;;
        *)
            die "unsupported RPM target distro: ${target_distro:-unset}"
            ;;
    esac

    prep_log="$source_cache/$safe_release-rpmbuild.log"
    if ! rpmbuild -bp --nodeps --define "_topdir $rpmbuild_topdir" \
        "${rpmbuild_distro_args[@]}" "${spec_files[0]}" >"$prep_log" 2>&1; then
        tail -n 80 "$prep_log" >&2 || true
        die "rpmbuild could not prepare the kernel source; see $prep_log"
    fi

    while IFS= read -r -d '' candidate; do
        main_source_file="$candidate"
        break
    done < <(find "$rpmbuild_topdir/BUILD" -type f -path '*/init/main.c' -print0)

    [[ -n "$main_source_file" ]] || \
        die "could not find the prepared Linux source tree in $rpmbuild_topdir/BUILD"
    source_candidate="$(dirname "$(dirname "$main_source_file")")"
    [[ -f "$source_candidate/Makefile" && -d "$source_candidate/drivers" && -d "$source_candidate/include/linux" ]] || \
        die "prepared source tree is incomplete: $source_candidate"

    mkdir -p "$prepared_parent"
    mv "$source_candidate" "$stage_dir/tree"
    printf '%s\n' "$expected_source_rpm" > "$stage_dir/.source-rpm"
    mv "$stage_dir" "$prepared_source"
    stage_dir=""
    source_tree="$prepared_source/tree"
    log "cached kernel source: $source_tree"
}

prepare_kernel_source() {
    local source_rpm_name cached_source_rpm safe_release prepared_parent prepared_source lock_fd

    [[ -f "$source_rpm_path" ]] || die "kernel source RPM not found: $source_rpm_path"
    source_rpm_name="${source_rpm_path##*/}"
    [[ "$source_rpm_name" =~ ^[A-Za-z0-9._+~_-]+\.src\.rpm$ ]] || \
        die "invalid kernel source RPM filename: $source_rpm_name"
    cached_source_rpm="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.src.rpm' "$source_rpm_path" 2>/dev/null)" || \
        die "kernel source RPM is invalid: $source_rpm_path"
    [[ "$cached_source_rpm" == "$source_rpm_name" ]] || \
        die "kernel source RPM identity mismatch: expected $source_rpm_name, found $cached_source_rpm"

    safe_release="${kernel_release//[^A-Za-z0-9._+~_-]/_}"
    prepared_parent="$source_cache/source/$safe_release"
    prepared_source="$prepared_parent/${source_rpm_name%.src.rpm}"
    mkdir -p "$prepared_parent" "$source_cache/locks"

    exec {lock_fd}>"$source_cache/locks/$safe_release.lock"
    flock "$lock_fd"
    if prepared_source_cache_valid "$prepared_source" "$source_rpm_name"; then
        source_tree="$prepared_source/tree"
        log "using cached kernel source: $source_tree"
    else
        [[ ! -e "$prepared_source" ]] || \
            die "source cache entry is incomplete: $prepared_source; remove that cache directory and retry"
        prepare_source_tree "$safe_release" "$prepared_parent" "$prepared_source" "$source_rpm_name"
    fi
    flock -u "$lock_fd"
}

while (($# > 0)); do
    case "$1" in
        --kernel-devel)
            require_value "$1" "${2-}"
            kernel_tree="$2"
            shift 2
            ;;
        --kernel-source)
            require_value "$1" "${2-}"
            source_tree="$2"
            shift 2
            ;;
        --kernel-release)
            require_value "$1" "${2-}"
            kernel_release="$2"
            shift 2
            ;;
        --target-distro)
            require_value "$1" "${2-}"
            target_distro="$2"
            shift 2
            ;;
        --target-distro-version)
            require_value "$1" "${2-}"
            target_distro_version="$2"
            shift 2
            ;;
        --source-rpm)
            require_value "$1" "${2-}"
            source_rpm_path="$2"
            shift 2
            ;;
        --source-cache)
            require_value "$1" "${2-}"
            source_cache="$2"
            shift 2
            ;;
        --patch-dir)
            require_value "$1" "${2-}"
            patch_dir="$2"
            shift 2
            ;;
        --output)
            require_value "$1" "${2-}"
            output_dir="$2"
            shift 2
            ;;
        --config-file)
            require_value "$1" "${2-}"
            config_file="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument '$1' (use --help for usage)"
            ;;
    esac
done

[[ -f "$config_file" ]] || die "dkms.conf not found: $config_file"
# The config is part of this repository and is intentionally a shell-compatible
# DKMS config. It supplies BUILT_MODULE_NAME[0] and optional project overrides.
# shellcheck disable=SC1090
source "$config_file"

if [[ -n "$source_rpm_path" || -n "$target_distro" || -n "$target_distro_version" ]]; then
    [[ "$target_distro" == fedora || "$target_distro" == rhel ]] || \
        die "--target-distro must be fedora or rhel"
    [[ "$target_distro_version" =~ ^[1-9][0-9]*$ ]] || \
        die "--target-distro-version must be a positive integer"
fi
if [[ -d "$patch_dir" ]]; then
    patch_dir="$(cd "$patch_dir" && pwd -P)" || die "cannot access patch directory: $patch_dir"
fi

module_name="${BUILT_MODULE_NAME[0]:-}"
module_name="${module_name%.ko}"
[[ -n "$module_name" ]] || die "dkms.conf must set BUILT_MODULE_NAME[0]"
[[ "$module_name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid module name '$module_name' in dkms.conf"

[[ -d "$kernel_tree" ]] || die "kernel tree does not exist: $kernel_tree"
[[ -f "$kernel_tree/Makefile" ]] || die "$kernel_tree is not a kernel source/devel tree: Makefile is missing"

if [[ -z "$kernel_release" ]]; then
    if [[ -f "$kernel_tree/include/config/kernel.release" ]]; then
        kernel_release="$(<"$kernel_tree/include/config/kernel.release")"
    else
        log "detecting kernel release from $kernel_tree"
        kernel_release="$(make -s -C "$kernel_tree" kernelrelease)" || \
            die "could not detect kernel release; pass --kernel-release"
    fi
fi
[[ "$kernel_release" =~ ^[A-Za-z0-9][A-Za-z0-9._+~_-]*$ ]] || \
    die "invalid kernel release '$kernel_release'"

if [[ -n "$source_rpm_path" ]]; then
    prepare_kernel_source
elif [[ -z "$source_tree" ]]; then
    if [[ -d "/kernel-source" ]]; then
        source_tree="/kernel-source"
    else
        source_tree="$kernel_tree"
    fi
fi
[[ -d "$source_tree" ]] || die "kernel source tree does not exist: $source_tree"
[[ -f "$source_tree/Makefile" ]] || die "$source_tree is not a kernel source tree: Makefile is missing"

escape_ere() {
    printf '%s' "$1" | sed 's/[.[\\*^$()+?{|]/\\&/g'
}

resolve_module_dir() {
    local source_dir makefile candidate module_pattern normalized_pattern
    local -a matches=()
    declare -A seen=()

    if [[ -n "${KMOD_SOURCE_DIR:-}" ]]; then
        if [[ "$KMOD_SOURCE_DIR" = /* ]]; then
            source_dir="$KMOD_SOURCE_DIR"
        else
            source_dir="$source_tree/${KMOD_SOURCE_DIR#./}"
        fi
        [[ -d "$source_dir" ]] || die "KMOD_SOURCE_DIR does not exist: $source_dir"
        printf '%s\n' "${source_dir%/}"
        return
    fi

    module_pattern="$(escape_ere "$module_name")"
    normalized_pattern="$(escape_ere "${module_name//-/_}")"
    while IFS= read -r -d '' makefile; do
        if grep -Eq "(^|[^[:alnum:]_])(${module_pattern}|${normalized_pattern})(\\.o|[-_]y|\\.ko)([^[:alnum:]_]|$)" "$makefile"; then
            candidate="$(dirname "$makefile")"
            if [[ -z "${seen[$candidate]+yes}" ]]; then
                seen[$candidate]=1
                matches+=("$candidate")
            fi
        fi
    done < <(find "$source_tree" -type f \( -name Makefile -o -name Kbuild \) -print0)

    case "${#matches[@]}" in
        0)
            die "could not locate '$module_name' in the kernel tree; set KMOD_SOURCE_DIR in dkms.conf"
            ;;
        1)
            printf '%s\n' "${matches[0]}"
            ;;
        *)
            printf '[%s] module name matched multiple source directories:\n' "$PROGRAM" >&2
            printf '  %s\n' "${matches[@]}" >&2
            die "set KMOD_SOURCE_DIR in dkms.conf to disambiguate"
            ;;
    esac
}

module_dir="$(resolve_module_dir)"
module_dir="${module_dir%/}"
case "$module_dir/" in
    "$source_tree"/*) ;;
    *) die "module source must be inside the mounted kernel source tree: $module_dir" ;;
esac
[[ -f "$module_dir/Makefile" || -f "$module_dir/Kbuild" ]] || \
    die "module source directory has neither Makefile nor Kbuild: $module_dir"

module_source_file=""
while IFS= read -r -d '' candidate; do
    module_source_file="$candidate"
    break
done < <(find "$module_dir" -type f \( -name '*.c' -o -name '*.cc' -o -name '*.S' -o -name '*.rs' \) -print0)
[[ -n "$module_source_file" ]] || \
    die "no C/assembly/Rust source files found below $module_dir; mount the complete kernel source at /kernel-source"

declare -a config_overrides=()
if [[ -n "${KMOD_CONFIG:-}" ]]; then
    # KMOD_CONFIG is deliberately limited to simple CONFIG_NAME={m,y,n} words.
    read -r -a config_overrides <<< "$KMOD_CONFIG"
else
    # Most in-tree modules are selected by obj-$(CONFIG_FOO) += <module>.o.
    # Extract those symbols so changing only BUILT_MODULE_NAME[0] is enough.
    module_pattern="$(escape_ere "$module_name")"
    normalized_pattern="$(escape_ere "${module_name//-/_}")"
    while IFS= read -r line; do
        while IFS= read -r symbol; do
            [[ -n "$symbol" ]] && config_overrides+=("${symbol}=m")
        done < <(grep -oE 'CONFIG_[A-Za-z0-9_]+' <<< "$line" | sort -u)
    done < <(grep -hE "(^|[^[:alnum:]_])(${module_pattern}|${normalized_pattern})(\\.o|[-_]y|\\.ko)([^[:alnum:]_]|$)" \
        "$module_dir/Makefile" "$module_dir/Kbuild" 2>/dev/null || true)
fi

declare -A seen_config=()
declare -a unique_config_overrides=()
for config_override in "${config_overrides[@]}"; do
    [[ "$config_override" =~ ^CONFIG_[A-Za-z0-9_]+=(m|y|n)$ ]] || \
        die "invalid Kconfig override '$config_override' in dkms.conf"
    if [[ -z "${seen_config[$config_override]+yes}" ]]; then
        seen_config[$config_override]=1
        unique_config_overrides+=("$config_override")
    fi
done
config_overrides=()
if ((${#unique_config_overrides[@]} > 0)); then
    config_overrides=("${unique_config_overrides[@]}")
fi

safe_module="${module_name//-/_}"
safe_release="${kernel_release//[^A-Za-z0-9._+~-]/_}"
package_base="${PACKAGE_NAME:-dkms-intree-kmod}"
package_base="${package_base//[^A-Za-z0-9._+-]/-}"
case "$package_base" in
    *-"$safe_module") package_name="$package_base" ;;
    *) package_name="${package_base}-${safe_module}" ;;
esac
package_version="${PACKAGE_VERSION:-0.1.1}"
package_version="${package_version//[^A-Za-z0-9._+~-]/_}"
dkms_source="/usr/src/${package_name}-${package_version}"
dkms_build_tree="/var/lib/dkms/${package_name}/${package_version}/build"
dkms_build_root="/var/lib/dkms/${package_name}/${package_version}/${kernel_release}"

mkdir -p "$output_dir" /usr/src /var/lib/dkms "/lib/modules/$kernel_release"
if [[ -e "/lib/modules/$kernel_release/build" && ! -L "/lib/modules/$kernel_release/build" ]]; then
    die "/lib/modules/$kernel_release/build already exists; use a clean container"
fi
if [[ -e "/lib/modules/$kernel_release/source" && ! -L "/lib/modules/$kernel_release/source" ]]; then
    die "/lib/modules/$kernel_release/source already exists; use a clean container"
fi
ln -sfn "$kernel_tree" "/lib/modules/$kernel_release/build"
ln -sfn "$kernel_tree" "/lib/modules/$kernel_release/source"

rm -rf "$dkms_source"
mkdir -p "$dkms_source"
cp -a "$module_dir/." "$dkms_source/"

apply_matching_patches() {
    local LC_ALL=C
    local patch_file
    # These patches fix behavior, so apply them before any build attempt.
    # A source tree can predate the affected code or already contain the fix.
    for patch_file in "$patch_dir/$module_name/always/"*.patch; do
        if git -C "$dkms_source" apply --check "$patch_file" >/dev/null 2>&1; then
            git -C "$dkms_source" apply "$patch_file" || die "could not apply patch: $patch_file"
            log "applied matching patch: ${patch_file##*/}"
        elif git -C "$dkms_source" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
            log "patch already present: ${patch_file##*/}"
        else
            log "patch does not match source, skipping: ${patch_file##*/}"
        fi
    done
}

apply_matching_patches

prepare_module_patches() {
    local LC_ALL=C
    local patch_root patch_file patch_stage patch_target patch_name index=0
    local -a patch_files=() selected_patches=()

    [[ -n "$target_distro" && -n "$target_distro_version" ]] || return 1
    patch_root="$patch_dir/$module_name/$target_distro/$target_distro_version"
    [[ -d "$patch_root" ]] || return 1
    patch_files=("$patch_root"/*.patch)
    ((${#patch_files[@]} > 0)) || return 1

    patch_stage="$(mktemp -d)" || return 1
    if ! cp -a "$dkms_source/." "$patch_stage/"; then
        warn "could not stage compatibility patches"
        rm -rf "$patch_stage"
        return 1
    fi

    for patch_file in "${patch_files[@]}"; do
        if git -C "$patch_stage" apply --check "$patch_file" >/dev/null 2>&1; then
            if ! git -C "$patch_stage" apply "$patch_file"; then
                warn "could not stage compatibility patch: $patch_file"
                rm -rf "$patch_stage"
                return 1
            fi
            selected_patches+=("$patch_file")
        elif git -C "$patch_stage" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
            log "compatibility patch already present: ${patch_file##*/}"
        else
            warn "compatibility patch does not apply: $patch_file"
            rm -rf "$patch_stage"
            return 1
        fi
    done
    rm -rf "$patch_stage"
    ((${#selected_patches[@]} > 0)) || return 1

    if [[ -L "$dkms_source/patches" ]]; then
        warn "cannot place DKMS patches in a symlink: $dkms_source/patches"
        return 1
    fi
    patch_target="$dkms_source/patches/dkms-intree-kmod"
    if [[ -e "$patch_target" || -L "$patch_target" ]]; then
        warn "DKMS patch directory already exists: $patch_target"
        return 1
    fi
    if ! mkdir -p "$patch_target"; then
        warn "could not create DKMS patch directory: $patch_target"
        return 1
    fi

    for patch_file in "${selected_patches[@]}"; do
        patch_name="$(printf '%04d.patch' "$index")"
        if ! cp "$patch_file" "$patch_target/$patch_name"; then
            warn "could not stage compatibility patch: $patch_file"
            return 1
        fi
        printf 'PATCH[%d]="dkms-intree-kmod/%s"\n' "$index" "$patch_name" >> "$dkms_source/dkms.conf" || return 1
        log "selected compatibility patch: ${patch_file##*/}"
        index=$((index + 1))
    done
}

make_config_args=""
for config_override in "${config_overrides[@]}"; do
    make_config_args+=" $config_override"
done

cat > "$dkms_source/dkms.conf" <<EOF
PACKAGE_NAME="$package_name"
PACKAGE_VERSION="$package_version"
BUILT_MODULE_NAME[0]="$module_name"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="no"
MAKE[0]="make -C $kernel_tree M=$dkms_build_tree ${module_name}.ko$make_config_args"
EOF

log "kernel release: $kernel_release"
log "kernel devel:   $kernel_tree"
log "kernel source:  $source_tree"
log "module source:  $module_dir"
log "module name:    $module_name"
log "Kconfig:        ${config_overrides[*]:-(auto/none)}"
log "adding temporary DKMS package $package_name/$package_version"

dkms add -m "$package_name" -v "$package_version"
# The mounted kernel-devel may contain a sign-file binary linked against a
# different OpenSSL ABI than the builder image. Leave signing to the host,
# where its Secure Boot/MOK policy and matching crypto libraries are available.
dkms_log="$dkms_build_tree/make.log"
run_dkms_build() {
    dkms build -m "$package_name" -v "$package_version" -k "$kernel_release" --force \
        --directive=try_sign_modules=false
}

show_dkms_log() {
    local log_file="$1" label="$2"
    if [[ -s "$log_file" ]]; then
        log "last 160 lines of $label:" >&2
        tail -n 160 "$log_file" >&2 || true
    else
        warn "DKMS failed without producing $label"
    fi
}

log "building module source"
if ! run_dkms_build; then
    original_dkms_log="$(mktemp)"
    if [[ -f "$dkms_log" ]]; then
        cp "$dkms_log" "$original_dkms_log"
    fi
    if prepare_module_patches; then
        log "retrying DKMS build with compatibility patches"
        if ! run_dkms_build; then
            show_dkms_log "$original_dkms_log" "the original DKMS build log"
            show_dkms_log "$dkms_log" "the patched DKMS build log"
            rm -f "$original_dkms_log"
            die "DKMS failed to build $module_name for $kernel_release"
        fi
    else
        show_dkms_log "$original_dkms_log" "the DKMS build log"
        rm -f "$original_dkms_log"
        die "DKMS failed to build $module_name for $kernel_release"
    fi
    rm -f "$original_dkms_log"
fi

module_file=""
if [[ -d "$dkms_build_root" ]]; then
    while IFS= read -r -d '' candidate; do
        module_file="$candidate"
        break
    done < <(find "$dkms_build_root" -type f \( -name "${module_name}.ko" -o -name "${module_name}.ko.*" \) -print0)
fi
[[ -n "$module_file" ]] || \
    die "DKMS completed without producing ${module_name}.ko; check BUILT_MODULE_NAME[0] and the source tree"

flat_output="$output_dir/${module_name}.ko"
install_output="$output_dir/lib/modules/$kernel_release/updates/${module_name}.ko"
mkdir -p "$(dirname "$install_output")"
cp -L "$module_file" "$flat_output"
cp -L "$module_file" "$install_output"

# kernel-devel commonly omits these package-level metadata files. Empty files
# make depmod produce a clean metadata set for the output tree.
touch \
    "$output_dir/lib/modules/$kernel_release/modules.order" \
    "$output_dir/lib/modules/$kernel_release/modules.builtin" \
    "$output_dir/lib/modules/$kernel_release/modules.builtin.modinfo"

if command -v depmod >/dev/null 2>&1; then
    depmod -b "$output_dir" "$kernel_release" || \
        warn "depmod could not generate metadata; the module itself was copied successfully"
fi

if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
    chown -R "$HOST_UID:$HOST_GID" "$output_dir" 2>/dev/null || \
        warn "could not change output ownership to $HOST_UID:$HOST_GID"
fi

log "built module: $flat_output"
log "install-tree: $install_output"
