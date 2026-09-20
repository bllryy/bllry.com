# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2021-2023 Leah Rowe <leah@libreboot.org>

check_site_changed()
{
	_sitedir="${1}"; shift 1
	sitechanged="n"

	filelist=$(mktemp -t untitled_www.XXXXXXXXXX)
	for f in "${_sitedir}"/site/footer*.include \
	    "${_sitedir}"/site/nav*.include; do
		[ -f "${f}" ] || continue
		printf "%s\n" "${f}" >> "${filelist}"
	done
	for f in "${_sitedir}/site.cfg" "${_sitedir}/site/template.include" \
	    $(cat "${filelist}"); do
		filehasnotchanged "${f}" || sitechanged="y"
	done
	rm -f "${filelist}"

	if [ "${sitechanged}" = "y" ]; then
		printf "Sitewide changes detected in %s. Will re-build.\n" \
		    "${_sitedir}"
		tmproll="y"
	fi
}

check_site_config()
{
	_sitedir="${1}"

	for sitefile in "${_sitedir}/site.cfg" \
	    "${_sitedir}/site/template.include"; do
		if [ ! -f "${sitefile}" ]; then
			printf "%s missing for site, %s. Skipping!\n" \
			    "${sitefile}" "${_sitedir}" 1>&2
			return 1
		fi
	done

	eval "$(getConfigValues "${_sitedir}/site.cfg" TITLE CSS DOMAIN \
	    BLOGTITLE LAZY BLOGDESCRIPTION DEFAULTLANG BLOGDIR SITEMAP)"

	[ -z "${TITLE}" ] && TITLE="UNTITLED PAGE"
	if [ -z "${DOMAIN}" ]; then
		printf "%s/site.cfg does not specify DOMAIN. Exiting\n" \
		    "${_sitedir}" 1>&2
		return 1
	fi
	[ -z "${BLOGTITLE}" ] && BLOGTITLE="News"
	[ "${LAZY}" != "y" ] && LAZY="n"
	[ -z "${BLOGDESCRIPTION}" ] && BLOGDESCRIPTION="News"

	DEFAULTLANG="${DEFAULTLANG##*/}"
	[ -z "${DEFAULTLANG}" ] && DEFAULTLANG="en"
	check_path d "lang/${DEFAULTLANG}" || DEFAULTLANG="en"

	# optional. if not set, this will be empty, and blog will be homepage
	_testdir="${_sitedir}/site/${BLOGDIR%/}"
	check_path d "${_testdir}" || return 0
	check_symlinks "${_testdir}" BLOGDIR || return 0
	if [ -f "${_testdir}" ]; then
		printf "%s: BLOGDIR is a file. skipping\n" \
		    "${BLOGDIR}" && "${_sitedir}" 1>&2
		return 1
	fi
}

# uses the last modified date
# returns 1 if the file has changed
filehasnotchanged()
{
	# return 1 means yes, needs to be changed
	# 0 means no, doesn't need to be changed
	_f="${1}"
	[ ! -f "${_f}" ] && return 0
	[ -d "${_f}.date" ] && return 1

	_moddate=$(date -r "${_f}" +%s)

	if [ ! -f "${_f}.date" ]; then
		printf "%s\n" "${_moddate}" > "${_f}.date"
		return 1
	fi
	[ "$(cat "${_f}.date")" = "${_moddate}" ] && \
		return 0

	printf "%s\n" "${_moddate}" > "${_f}.date"
	return 1
}

getlangname()
{
	_file="${1%.md}" # path to markdown file
	_defaultlang="${2}"

	_realpage="${_file##*/}"
	_pagelang="${_realpage##*.}"
	[ "${_pagelang}" = "${_realpage}" ] && \
		_pagelang="${_defaultlang}"

	_strconf="lang/${_pagelang}/strings.cfg"

	if [ ! -f "${_strconf}" ]; then
		printf "%s\n" "${_pagelang}"
		return 0
	fi

	_langname="$(getConfigValue "${_strconf}" "LANGNAME")"

	if [ "${_langname}" != "" ]; then
		printf "%s\n" "${_langname}"
		return 0
	fi

	printf "%s\n" "${_pagelang}"
	return 0
}

getConfigValues()
{
	[ $# -lt 2 ] && return 1
	__cfgfile="${1}" && shift 1
	printf "%s\n" "${@}" > "${tmpdir}/confvals"
	while read -r c; do
		setvars "$(getConfigValue "$__cfgfile" "$c")" "$c"
	done < "${tmpdir}/confvals"
}

getConfigValue()
{
	_cfgfile="${1}" # e.g. www/foo/site.cfg
	_item="${2}" # e.g. _title
	_tmpcfg=$(mktemp -t untitled_www.XXXXXXXXXX)
	grep "${_item}" "${_cfgfile}" > "${_tmpcfg}"
	_value="$(head -n1 "$_tmpcfg")"
	_value="${_value##*"$_item=\""}"
	_value="${_value%\"*}"
	printf "%s\n" "${_value}"
	rm -f "${_tmpcfg}"
}

newspages()
{
	_newsdir="${1%/}"
	cat "${2}" > "${tmpdir}/xnewspages"
	while read -r xnewspage; do
		_xfile="$(sanitizefilename "${_newsdir}/${xnewspage}")"
		printf "%s\n" "${_xfile}"
	done < "${tmpdir}/xnewspages"
}

sanitizefilename()
{
	_page="${1##*/}"
	_page="${_page%/}" # avoid refering to directory
	_page="$(printf "%s\n" "${1}" | sed -e 's/\ //g')"
	_page="$(printf "%s\n" "${1}" | sed -e 's/\.\.//g')"
	printf "%s\n" "${_page}"
}
