#!/usr/bin/env bash
# Smoke tests for eessi_riscv_optarch.map (format / ⊆spec / compiler flags).
# Production map lookup is Lua-only in EESSI-extend-easybuild.eb; helpers below
# are test-oracle only and must not be installed or called from build scripts.
# Validates GCC and LLVM/Clang flag slices, and (when available) that compilers
# accept those flags for RISC-V.
set -euo pipefail

TOPDIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${EESSI_RISCV_OPTARCH_MAP:=${TOPDIR}/init/arch_specs/eessi_riscv_optarch.map}"

fail=0
pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

# --- test-only map readers (mirror Lua key/value + multi-compiler split) ---
eessi_riscv_optarch_for() {
    local subdir="${1:-}"
    if [ -z "${subdir}" ]; then
        echo "eessi_riscv_optarch_for: missing software subdirectory argument" >&2
        return 2
    fi
    case "${subdir}" in
        riscv64/*) ;;
        *) return 0 ;;
    esac
    if [ ! -f "${EESSI_RISCV_OPTARCH_MAP}" ]; then
        echo "eessi_riscv_optarch_for: map file not found: ${EESSI_RISCV_OPTARCH_MAP}" >&2
        return 2
    fi
    local key rest
    while read -r key rest; do
        [ -z "${key}" ] && continue
        if [ "${key}" = "${subdir}" ]; then
            if [ -z "${rest}" ]; then
                echo "eessi_riscv_optarch_for: empty optarch for '${subdir}' in ${EESSI_RISCV_OPTARCH_MAP}" >&2
                return 1
            fi
            printf '%s\n' "${rest}"
            return 0
        fi
    done < <(sed -E 's/(^|[[:space:]])#.*$//g;/^[[:space:]]*$/d' "${EESSI_RISCV_OPTARCH_MAP}")
    echo "eessi_riscv_optarch_for: no optarch mapping for '${subdir}' (add it to ${EESSI_RISCV_OPTARCH_MAP})" >&2
    return 1
}

eessi_riscv_optarch_compiler_flags() {
    local optarch="${1:-}"
    local compiler="${2:-}"
    if [ -z "${optarch}" ] || [ -z "${compiler}" ]; then
        echo "eessi_riscv_optarch_compiler_flags: need <optarch> <compiler>" >&2
        return 2
    fi
    if [ "${optarch}" = "GENERIC" ]; then
        printf '%s\n' "GENERIC"
        return 0
    fi
    local part key val rest="${optarch}"
    while [ -n "${rest}" ]; do
        part="${rest%%;*}"
        if [ "${part}" = "${rest}" ]; then
            rest=""
        else
            rest="${rest#*;}"
        fi
        key="${part%%:*}"
        val="${part#*:}"
        if [ "${key}" = "${compiler}" ]; then
            if [ -z "${val}" ] || [ "${val}" = "${part}" ]; then
                echo "eessi_riscv_optarch_compiler_flags: missing flags for ${compiler} in '${optarch}'" >&2
                return 1
            fi
            printf '%s\n' "${val}"
            return 0
        fi
    done
    echo "eessi_riscv_optarch_compiler_flags: no entry for compiler '${compiler}' in '${optarch}'" >&2
    return 1
}

SUBDIRS=(
    riscv64/generic/rva20u64
    riscv64/generic/rva22u64
    riscv64/generic/rva23u64
    riscv64/sifive/p550
    riscv64/sifive/u74-mc
    riscv64/spacemit/x60
    riscv64/spacemit/x60-k6.6
)

# --- map structure ---
got=$(eessi_riscv_optarch_for 'riscv64/generic')
if [[ "${got}" == "GENERIC" ]]; then
    pass "riscv64/generic -> GENERIC"
else
    fail_msg "riscv64/generic: got='${got}' expected='GENERIC'"
fi

for sub in "${SUBDIRS[@]}"; do
    optarch=$(eessi_riscv_optarch_for "${sub}") || {
        fail_msg "${sub}: lookup failed"
        continue
    }
    missing=0
    for compiler in GCC Clang LLVM; do
        if ! eessi_riscv_optarch_compiler_flags "${optarch}" "${compiler}" >/dev/null; then
            fail_msg "${sub}: missing ${compiler}: entry in '${optarch}'"
            missing=1
        fi
    done
    [[ ${missing} -eq 0 ]] && pass "${sub} has GCC + Clang + LLVM entries"
done

# Spot-check known GCC / Clang / LLVM slices for u74-mc
u74=$(eessi_riscv_optarch_for 'riscv64/sifive/u74-mc')
gcc_u74=$(eessi_riscv_optarch_compiler_flags "${u74}" GCC)
clang_u74=$(eessi_riscv_optarch_compiler_flags "${u74}" Clang)
llvm_u74=$(eessi_riscv_optarch_compiler_flags "${u74}" LLVM)
if [[ "${gcc_u74}" == '-mcpu=sifive-u74 -mabi=lp64d' ]]; then
    pass "GCC flags for u74-mc"
else
    fail_msg "GCC u74-mc flags: '${gcc_u74}'"
fi
if [[ "${clang_u74}" == '-mcpu=sifive-u74 -mabi=lp64d' ]]; then
    pass "Clang flags for u74-mc"
else
    fail_msg "Clang u74-mc flags: '${clang_u74}'"
fi
if [[ "${llvm_u74}" == '-mcpu=sifive-u74 -mabi=lp64d' ]]; then
    pass "LLVM flags for u74-mc"
else
    fail_msg "LLVM u74-mc flags: '${llvm_u74}'"
fi
if [[ "${gcc_u74}" == "${clang_u74}" && "${clang_u74}" == "${llvm_u74}" ]]; then
    pass "GCC/Clang/LLVM flags match for u74-mc"
else
    fail_msg "compiler flag mismatch for u74-mc"
fi

# Profile paths use explicit rv64* -march (not profile names); no -mtune=generic
for sub in riscv64/generic/rva20u64 riscv64/generic/rva22u64 riscv64/generic/rva23u64 \
           riscv64/spacemit/x60 riscv64/spacemit/x60-k6.6; do
    got=$(eessi_riscv_optarch_for "${sub}")
    if [[ "${got}" == *'-march=rv64'* && "${got}" == *'-mabi=lp64d'* && "${got}" != *'-mtune=generic'* && "${got}" != *'-march=rva'* ]]; then
        pass "${sub} optarch shape OK"
    else
        fail_msg "${sub}: unexpected optarch '${got}'"
    fi
done

# --- map -march tokens ⊆ archdetect spec (HaoZeke safety) ---
# A host labeled for software_subdir must advertise every userspace extension
# the optarch map compiles with. Parse -march from GCC flags.
# Skips:
#   - GENERIC: EasyBuild's rv64gc floor, not an explicit map -march string
#   - -mcpu-only rows (u74-mc): intentional; ISA comes from the named CPU
#     (see eessi_riscv_optarch.map), so there is no -march token list to ⊆-check
SPEC_FILE="${TOPDIR}/init/arch_specs/eessi_arch_riscv.spec"
# Reuse archdetect expansion without running the script's CLI entrypoint.
# shellcheck disable=SC1091
eval "$(sed -n '/^riscv_expand_base(){/,/^}$/p' "${TOPDIR}/init/eessi_archdetect.sh")"

spec_features_for() {
    local subdir="$1"
    local line
    local -a row
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        # Spec lines are eval-safe: "path" "vendor" "features" ...
        eval "row=(${line})"
        if [ "${row[0]}" = "${subdir}" ]; then
            printf '%s\n' "${row[2]}"
            return 0
        fi
    done < <(sed -E 's/(^|[[:space:]])#.*$//g;/^[[:space:]]*$/d' "${SPEC_FILE}")
    return 1
}

march_to_tokens() {
    # Turn -march=rv64gc_zba_zbb into expanded space-separated tokens.
    local march="$1"
    local isa="${march#-march=}"
    isa="${isa//_/ }"
    # shellcheck disable=SC2086
    riscv_expand_base ${isa}
}

check_map_subseteq_spec() {
    local sub="$1"
    local optarch gcc_flags march spec_feats expanded_spec tok missing
    optarch=$(eessi_riscv_optarch_for "${sub}") || {
        fail_msg "${sub}: map lookup failed for ⊆spec check"
        return
    }
    if [[ "${optarch}" == "GENERIC" ]]; then
        pass "${sub}: GENERIC has no -march to ⊆-check"
        return
    fi
    gcc_flags=$(eessi_riscv_optarch_compiler_flags "${optarch}" GCC) || {
        fail_msg "${sub}: no GCC flags for ⊆spec check"
        return
    }
    march=""
    # shellcheck disable=SC2086
    for tok in ${gcc_flags}; do
        case "${tok}" in
            -march=*) march="${tok}" ;;
        esac
    done
    if [[ -z "${march}" ]]; then
        # Deliberate for u74-mc (-mcpu=sifive-u74): no map -march to ⊆ vs spec.
        pass "${sub}: no -march in GCC flags (skip ⊆spec; -mcpu defines ISA)"
        return
    fi
    spec_feats=$(spec_features_for "${sub}") || {
        fail_msg "${sub}: no archdetect spec line for ⊆spec check"
        return
    }
    # shellcheck disable=SC2086
    expanded_spec=$(riscv_expand_base ${spec_feats})
    missing=""
    # shellcheck disable=SC2086
    for tok in $(march_to_tokens "${march}"); do
        [[ " ${expanded_spec} " == *" ${tok} "* ]] || missing="${missing} ${tok}"
    done
    if [[ -z "${missing}" ]]; then
        pass "${sub}: map -march ⊆ spec (${march})"
    else
        fail_msg "${sub}: map -march tokens not in spec:${missing} (march=${march} spec='${spec_feats}')"
    fi
}

for sub in riscv64/generic "${SUBDIRS[@]}"; do
    check_map_subseteq_spec "${sub}"
done

# Non-riscv / unknown
got=$(eessi_riscv_optarch_for 'x86_64/amd/zen4' || true)
[[ -z "${got}" ]] && pass "non-riscv no-op" || fail_msg "non-riscv should print nothing, got='${got}'"

if eessi_riscv_optarch_for 'riscv64/unknown/cpu' >/dev/null 2>&1; then
    fail_msg "unknown riscv target should not succeed"
else
    pass "unknown riscv target rejected"
fi

# EESSI-extend (sole production apply path, Lua): missing map entry must warn +
# fall through, not LmodError. Structural check only — full module load is
# covered by tests_eessi_extend_module.yml.
extend_eb="${TOPDIR}/EESSI-extend-easybuild.eb"
if [[ -f "${extend_eb}" ]]; then
    if grep -q 'LmodError("No RISC-V EASYBUILD_OPTARCH mapping' "${extend_eb}"; then
        fail_msg "EESSI-extend still hard-fails on missing RISC-V optarch map entry"
    elif grep -q 'LmodWarning("No RISC-V EASYBUILD_OPTARCH mapping' "${extend_eb}" \
        && grep -q 'leaving EASYBUILD_OPTARCH unset' "${extend_eb}"; then
        pass "EESSI-extend warns and falls through on missing map entry"
    else
        fail_msg "EESSI-extend missing-map fallthrough (LmodWarning) not found"
    fi
    # Confirm apply is Lua in EESSI-extend, not a bash helper
    if grep -q 'setenv("EASYBUILD_OPTARCH", optarch)' "${extend_eb}" \
        && grep -q 'eessi_riscv_optarch.map' "${extend_eb}"; then
        pass "EESSI-extend Lua sets EASYBUILD_OPTARCH from map"
    else
        fail_msg "EESSI-extend Lua map apply not found"
    fi
else
    fail_msg "EESSI-extend-easybuild.eb not found at ${extend_eb}"
fi

# Production must not ship a bash map parser (Lua-only for EESSI-extend).
if [[ -f "${TOPDIR}/init/eessi_riscv_optarch.sh" ]]; then
    fail_msg "init/eessi_riscv_optarch.sh should be removed (Lua-only production path)"
else
    pass "no production bash optarch parser under init/"
fi
if grep -q 'eessi_riscv_optarch\.sh' "${TOPDIR}/install_scripts.sh"; then
    fail_msg "install_scripts.sh still installs eessi_riscv_optarch.sh"
else
    pass "install_scripts.sh does not install bash optarch helper"
fi

# --- compiler acceptance: GCC and Clang/LLVM ---
# EasyBuild GENERIC expands per-compiler; we check the shared generic baseline.
# Only run when EESSI_RISCV_OPTARCH_REQUIRE_COMPILERS=1 (CI), so host Apple
# Clang without a RISC-V backend does not fail structural map tests.
#
# Prefer compilers from the EESSI RISC-V stack (dev.eessi.io/riscv).
# CI pins GCC/14.3.0 and llvm-compilers/20.1.8 (foss/lfoss 2025b) deliberately —
# bump pins + EESSI_RISCV_OPTARCH_EXPECT_* when that stack rebuilds / modules move.
# Set EESSI_RISCV_GCC / EESSI_RISCV_CLANG to those binaries (CI does this).
#
# Flag checks use -fsyntax-only (not -c): under qemu on x86 CI, PATH often hits
# the host x86_64 Gentoo as, which rejects -march=rv64*. Syntax-only validates
# -march/-mtune/-mcpu without assembling. CI-on-qemu limitation only — not fixed
# by EESSI-extend. Clang also uses --target=riscv64-unknown-linux-gnu on purpose
# so the same EESSI clang binary can check RISC-V flags on an x86 runner.
GENERIC_FLAGS='-march=rv64gc -mabi=lp64d'

find_riscv_gcc() {
    if [[ -n "${EESSI_RISCV_GCC:-}" ]]; then
        if [[ -x "${EESSI_RISCV_GCC}" ]]; then
            printf '%s\n' "${EESSI_RISCV_GCC}"
            return 0
        fi
        echo "EESSI_RISCV_GCC='${EESSI_RISCV_GCC}' is not executable" >&2
        return 1
    fi
    # Native EESSI/module gcc when already targeting RISC-V
    if command -v gcc >/dev/null 2>&1; then
        if gcc -dumpmachine 2>/dev/null | grep -q '^riscv64'; then
            command -v gcc
            return 0
        fi
    fi
    if command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then
        command -v riscv64-linux-gnu-gcc
        return 0
    fi
    if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
        command -v riscv64-unknown-elf-gcc
        return 0
    fi
    if command -v riscv64-elf-gcc >/dev/null 2>&1; then
        command -v riscv64-elf-gcc
        return 0
    fi
    return 1
}

find_clang() {
    if [[ -n "${EESSI_RISCV_CLANG:-}" ]]; then
        if [[ -x "${EESSI_RISCV_CLANG}" ]]; then
            printf '%s\n' "${EESSI_RISCV_CLANG}"
            return 0
        fi
        echo "EESSI_RISCV_CLANG='${EESSI_RISCV_CLANG}' is not executable" >&2
        return 1
    fi
    # Prefer Homebrew LLVM on macOS; Apple clang often lacks RISC-V
    local c
    for c in clang clang-20 clang-19 clang-18 clang-17; do
        if command -v "${c}" >/dev/null 2>&1; then
            if "${c}" --target=riscv64-unknown-linux-gnu -c -x c /dev/null -o /dev/null 2>/dev/null; then
                command -v "${c}"
                return 0
            fi
        fi
    done
    return 1
}

expect_version() {
    local label="$1"
    local bin="$2"
    local expect="$3"
    local ver_out
    ver_out=$("${bin}" --version 2>&1) || {
        fail_msg "${label} --version failed"
        return 1
    }
    if [[ "${ver_out}" == *"${expect}"* ]]; then
        pass "${label} version contains '${expect}'"
        return 0
    fi
    fail_msg "${label} version does not contain '${expect}': $(echo "${ver_out}" | tr '\n' ' ')"
    return 1
}

check_gcc_flags() {
    local gcc_bin="$1"
    local label="$2"
    shift 2
    # -fsyntax-only: validate -march/-mtune/-mcpu without assembling (avoids
    # picking up an x86_64 as under qemu on GitHub Actions). CI limitation only.
    if "${gcc_bin}" "$@" -fsyntax-only -x c /dev/null 2>/tmp/eessi_riscv_gcc.err; then
        pass "GCC accepts ${label}: $*"
        return 0
    fi
    fail_msg "GCC rejects ${label}: $* ($(tr '\n' ' ' </tmp/eessi_riscv_gcc.err))"
    return 1
}

check_clang_flags() {
    local clang_bin="$1"
    local label="$2"
    shift 2
    # --target=...: intentional CI triple so x86-hosted EESSI Clang accepts RISC-V flags.
    if "${clang_bin}" --target=riscv64-unknown-linux-gnu "$@" -fsyntax-only -x c /dev/null 2>/tmp/eessi_riscv_clang.err; then
        pass "Clang/LLVM accepts ${label}: $*"
        return 0
    fi
    fail_msg "Clang/LLVM rejects ${label}: $* ($(tr '\n' ' ' </tmp/eessi_riscv_clang.err))"
    return 1
}

flags_to_args() {
    # shellcheck disable=SC2206
    local -a arr=( $1 )
    printf '%s\n' "${arr[@]}"
}

if [[ "${EESSI_RISCV_OPTARCH_REQUIRE_COMPILERS:-0}" == "1" ]]; then
    if GCC_BIN=$(find_riscv_gcc); then
        pass "using RISC-V GCC: ${GCC_BIN}"
        echo "=== ${GCC_BIN} --version ==="
        "${GCC_BIN}" --version
        if [[ -n "${EESSI_RISCV_OPTARCH_EXPECT_GCC_VERSION:-}" ]]; then
            expect_version "GCC" "${GCC_BIN}" "${EESSI_RISCV_OPTARCH_EXPECT_GCC_VERSION}" || true
        fi
        # shellcheck disable=SC2046
        check_gcc_flags "${GCC_BIN}" "GENERIC" $(flags_to_args "${GENERIC_FLAGS}") || true
        for sub in "${SUBDIRS[@]}"; do
            optarch=$(eessi_riscv_optarch_for "${sub}")
            gcc_flags=$(eessi_riscv_optarch_compiler_flags "${optarch}" GCC)
            # shellcheck disable=SC2046
            check_gcc_flags "${GCC_BIN}" "${sub}" $(flags_to_args "${gcc_flags}") || true
        done
    else
        fail_msg "RISC-V GCC not found but EESSI_RISCV_OPTARCH_REQUIRE_COMPILERS=1"
    fi

    if CLANG_BIN=$(find_clang); then
        pass "using Clang/LLVM: ${CLANG_BIN}"
        echo "=== ${CLANG_BIN} --version ==="
        "${CLANG_BIN}" --version
        if [[ -n "${EESSI_RISCV_OPTARCH_EXPECT_CLANG_VERSION:-}" ]]; then
            expect_version "Clang/LLVM" "${CLANG_BIN}" "${EESSI_RISCV_OPTARCH_EXPECT_CLANG_VERSION}" || true
        fi
        # shellcheck disable=SC2046
        check_clang_flags "${CLANG_BIN}" "GENERIC" $(flags_to_args "${GENERIC_FLAGS}") || true
        for sub in "${SUBDIRS[@]}"; do
            optarch=$(eessi_riscv_optarch_for "${sub}")
            for compiler in Clang LLVM; do
                cflags=$(eessi_riscv_optarch_compiler_flags "${optarch}" "${compiler}")
                # shellcheck disable=SC2046
                check_clang_flags "${CLANG_BIN}" "${sub}/${compiler}" $(flags_to_args "${cflags}") || true
            done
        done
    else
        fail_msg "RISC-V-capable Clang not found but EESSI_RISCV_OPTARCH_REQUIRE_COMPILERS=1"
    fi
else
    echo "SKIP compiler acceptance checks (set EESSI_RISCV_OPTARCH_REQUIRE_COMPILERS=1 in CI)"
fi

exit "${fail}"
