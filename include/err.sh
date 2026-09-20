# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2021-2023 Leah Rowe <leah@libreboot.org>

setvars()
{
	_setvars=""
	[ $# -lt 2 ] && fail "setvars: too few arguments"
	xval="${1}"
	shift 1
	printf "%s\n" "${@}" > "${tmpdir}/xvars"
	while read -r xvar; do
		_setvars="${xvar}=\"${xval}\"; ${_setvars}"
	done < "${tmpdir}/xvars"
	printf "%s\n" "${_setvars% }"
}

check_symlinks()
{
	__sitedir="${1}"
	_dirtype="${2}"

	# check if there are symlinks in the site directory
	[ -L "${__sitedir}" ] && \
		printf "%s %s is a symlink. skipping\n" \
		    "${__sitedir}" "${_dirtype}" 1>&2 && \
		return 1

	find -L "${__sitedir}" ! -path "${__sitedir}/.git" > "${tmpdir}/flist"
	while read -r i; do
		check_path l "${i}" || return 1
	done < "${tmpdir}/flist"
}

check_paths()
{
	_chk="${1}"
	shift 1
	printf "%s\n" "${@}" > "${tmpdir}/xpaths"
	while read -r xpath; do
		check_path "${_chk}" "${xpath}" || return 1
	done < "${tmpdir}/xpaths"
}

# check_Path X path
# X can be f, d or l (file, directory or symlink)
check_path()
{
	_chk="d"; _chkstr="directory"
	[ "${1}" = "f" ] && _chk="f" && _chkstr="file"
	[ "${1}" = "l" ] && _chkstr="path"

	[ -L "${2}" ] && \
		printf "%s %s is a symlink\n" "${2}" "${_chkstr}" 1>&2 && \
		return 1
	[ "${1}" = "l" ] && return 0
	eval "[ -${_chk} \"${2}\" ]" && return 0
	printf "%s is not a %s\n" "${2}" "${_chkstr}" 1>&2
	return 1
}

untitled_exit()
{
	tmp_cleanup || \
	    err "untitled_exit: can't rm tmpdir upon exit $1: ${tmpdir}"
	exit $1
}

fail()
{
	tmp_cleanup || printf "WARNING: can't rm tmpdir: %s\n" "${tmpdir}" 1>&2
	err "${1}"
}

tmp_cleanup()
{
	[ "${tmpdir_was_set}" = "n" ] || return 0
	rm -Rf "${tmpdir}" || return 1
}

err()
{
	printf "ERROR %s: %s\n" "${0}" "${1}" 1>&2
	exit 1
}
