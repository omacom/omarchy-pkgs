#!/bin/bash
# Prepare a fast libmakepkg overlay under a given directory and print its path.
#
# Arch's /usr/share/makepkg/util/pkgbuild.sh runs a subshell and pipes
# `declare -f` through `grep -E` for every attribute of every package function,
# and srcinfo.sh forks `$(shopt -p extglob)` per attribute. Indexing each
# function's assignments once in a bash associative array keeps makepkg and
# lint_pkgbuild intact while cutting fork/exec churn ~50x.
#
# Falls back to stock /usr/share/makepkg if the system libmakepkg layout differs.
set -euo pipefail

prepare_fast_makepkg_library() {
  local dest="$1"
  local src="${2:-/usr/share/makepkg}"

  if [[ ! -f "$src/util/pkgbuild.sh" || ! -f "$src/srcinfo.sh" ]] ||
     ! grep -q "^extract_function_variable()" "$src/util/pkgbuild.sh"; then
    echo "$src"
    return 0
  fi

  rm -rf "$dest"
  cp -a "$src" "$dest"
  chmod -R a+rX "$dest"

  cat << 'PATCH' >> "$dest/util/pkgbuild.sh"

declare -gA _FAST_FUNC_PARSED=()
declare -gA _FAST_FUNC_VARS=()

_fast_index_func() {
	local _fm_funcname=$1 _fm_body _fm_line _fm_key _fm_vname _fm_op _fm_rhs _fm_isarr
	_FAST_FUNC_PARSED[$_fm_funcname]=1
	_fm_body=$(declare -f "$_fm_funcname" 2>/dev/null || declare -f package 2>/dev/null || true)
	[[ -n $_fm_body ]] || return 0
	while IFS= read -r _fm_line; do
		if [[ $_fm_line =~ ^[[:space:]]*\ ([a-zA-Z_][a-zA-Z0-9_]*)(\+?=)(.*)$ ]]; then
			_fm_vname=${BASH_REMATCH[1]}
			_fm_op=${BASH_REMATCH[2]}
			_fm_rhs=${BASH_REMATCH[3]}
			_fm_isarr=0
			[[ $_fm_rhs == \(* ]] && _fm_isarr=1
			_fm_key="${_fm_funcname}:${_fm_vname}:${_fm_isarr}"
			if [[ -n ${_FAST_FUNC_VARS[$_fm_key]:-} ]]; then
				_FAST_FUNC_VARS[$_fm_key]+=$'\n'"${_fm_vname}${_fm_op}${_fm_rhs}"
			else
				_FAST_FUNC_VARS[$_fm_key]="${_fm_vname}${_fm_op}${_fm_rhs}"
			fi
		fi
	done <<<"$_fm_body"
}

extract_function_variable() {
	local _fm_funcname=$1 _fm_attr=$2 _fm_isarray=$3 _fm_outputvar=$4 _fm_key _fm_decls _fm_line _fm_r=1
	[[ -n ${_FAST_FUNC_PARSED[$_fm_funcname]+x} ]] || _fast_index_func "$_fm_funcname"
	_fm_key="${_fm_funcname}:${_fm_attr}:${_fm_isarray}"
	_fm_decls=${_FAST_FUNC_VARS[$_fm_key]:-}
	[[ -n $_fm_decls ]] || return 1
	while IFS= read -r _fm_line; do
		eval "${_fm_line/#$_fm_attr/$_fm_outputvar}"
		_fm_r=0
	done <<<"$_fm_decls"
	return $_fm_r
}
PATCH

  cat << 'PATCH' >> "$dest/srcinfo.sh"

srcinfo_write_attr() {
	local attrname=$1 attrvalues=("${@:2}")
	local had_extglob=0
	shopt -q extglob && had_extglob=1
	(( had_extglob )) || shopt -s extglob
	attrvalues=("${attrvalues[@]//+([[:space:]])/ }")
	attrvalues=("${attrvalues[@]#[[:space:]]}")
	attrvalues=("${attrvalues[@]%[[:space:]]}")
	(( had_extglob )) || shopt -u extglob
	printf "\t$attrname = %s\n" "${attrvalues[@]}"
}
PATCH

  if [[ -f "$dest/util/message.sh" ]]; then
    cat << 'PATCH' >> "$dest/util/message.sh"

case "${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}" in
  ""|C|C.*|POSIX) gettext() { printf '%s' "$1"; } ;;
esac
PATCH
  fi

  chmod -R a+rX "$dest"
  echo "$dest"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  prepare_fast_makepkg_library "${1:?usage: fast-makepkg.sh <dest-dir>}"
fi
