# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2017,2021-2023 Leah Rowe <leah@libreboot.org>
# SPDX-FileCopyrightText: 2017 Alyssa Rosenzweig <alyssa@rosenzweig.io>
# SPDX-FileCopyrightText: 2017 Michael Reed <michael@michaelreed.io>

prevlink=""
nextlink=""
currlink=""
firstlink=""

mknews()
{
	find -L "${1}/site/" -type f -name "MANIFEST" > "${tmpdir}/xmanifest"
	while read -r y; do
		check_path f "${y}" || continue
		mkarticle "${1}" "${y}"
	done < "${tmpdir}/xmanifest"
}

mkarticle()
{
	_sitedir="${1}"
	y="${2}"
	[ -f "${y}" ] || return 0

	eval "$(setvars "" BLOGINDEX BLOGINDEXLATEST)"
	eval "$(setvars "News" BLOGTITLE BLOGDESCRIPTION)"
	_manifestdir="${y##"${_sitedir}/site/"}"
	_manifestdir="${_manifestdir%MANIFEST}"
	_manifestdir="${_manifestdir%/}"

	# generate next/prev links on news articles
	# TODO: this should probably be moved to its own function
	# TODO: this code is ****ABSOLUTE SHIT****. FIX THAT.
	firstlink="`tail -n 1 "$y"`" || err "!tail -n 1 '$y'"
	currlink="`head -n 1 "$y"`" || err "!head -n 1 '$y'"
	if [ -z "$_manifestdir" ]; then
		# TODO: check if any of these any empty strings,
		# though right now it'd just result in <a href=""> (meh)
		printf "%s\n" "$firstlink" > "$_sitedir/site/first.link" || \
		    err "!write '$_sitedir/site/first.link'"
		printf "%s\n" "$currlink" > "$_sitedir/site/current.link" || \
		    err "!write '$_sitedir/site/current.link'"
	else
		# TODO: ditto
		printf "%s\n" "$firstlink" > \
		    "$_sitedir/site/$_manifestdir/first.link" || \
		    err "!write '$_sitedir/site/$_manifestdir/first.link'"
		printf "%s\n" "$currlink" > \
		    "$_sitedir/site/$_manifestdir/current.link" || \
		    err "!write '$_sitedir/site/$_manifestdir/current.link'"
	fi
	was_on_current=0
	newslast="" # previous page stored here by the loop, so that on
		# next iteration, the previously handled page can have a prev
		# link added. yes, this is horribly hacky and i'm going to hell.
	while read -r newspage; do
		newsprev="$_manifestdir/$newspage.prev"
		newsnext="$_manifestdir/$newspage.next"

		if [ -z "$_manifestdir" ]; then
			newsprev="${newsprev#/}"
			newsnext="${newsnext#/}"
		fi

		if [ -z "$_manifestdir" ]; then
			[ -f "$_sitedir/site/$newspage" ] || return 0; :
		else
			[ -f "$_sitedir/site/$_manifestdir/$newspage" ] || \
			    return 0; :
		fi
		rm -f "$newsprev" || err "!rm '$newsprev'"
		rm -f "$newsnext" || err "!rm '$newsnext'"

		[ -n "$nextlink" ] || was_on_current=1
		if [ $was_on_current -gt 0 ] && [ -z "$nextlink" ]; then
			nextlink="$newspage"
			continue
		elif [ $was_on_current -gt 0 ] && [ -n "$nextlink" ]; then
			was_on_current=0
			if [ -z "$_manifestdir" ]; then
				printf "%s\n" "$newspage" > \
				    "$_sitedir/site/$currlink.prev" || \
				    err "!write '$currlink.prev'"
			else
				printf "%s\n" "$newspage" > \
				"$_sitedir/site/$_manifestdir/$currlink.prev" \
				|| err "!write '$_manifestdir/$currlink.prev'"
			fi
		fi
		[ -z "$nextlink" ] || printf "%s\n" "$nextlink" > \
		    "$_sitedir/site/$newsnext" || err "!write '$newsnext'"
		[ -n "$nextlink" ] && nextlink="$newspage"
		[ -z "$newslast" ] || printf "%s\n" "$newspage" > \
		    "$_sitedir/site/$newslast.prev" || err "!write '$newslast'"

		newslast="$newspage"
		[ -n "$_manifestdir" ] && newslast="$_manifestdir/$newspage"; :
	done < "$y" || err "Cannot read manifest: '$y'"

	check_path f "$_sitedir/site/${_manifestdir}/news-list.md.include" || \
	    return 0

	newspages "${_sitedir}/site/${_manifestdir}" "${y}" > "${tmpdir}/xnews"
	while read -r f; do
		check_path f "${f}" || return 0
	done < "${tmpdir}/xnews"

	eval "$(getConfigValues \
	    "${_sitedir}/site/${_manifestdir}/news.cfg" \
	    BLOGTITLE BLOGDESCRIPTION BLOGINDEX BLOGINDEXLATEST)"

	[ -z "${BLOGTITLE}" ] && BLOGTITLE="News"
	[ -z "${BLOGDESCRIPTION}" ] && BLOGDESCRIPTION="News"
	[ "${BLOGINDEX##*/}" = "$BLOGINDEX" ] || BLOGINDEX="index.md"
	[ -z "$BLOGINDEX" ] && BLOGINDEX="index.md"
	[ "${BLOGINDEXLATEST}" = "y" ] || BLOGINDEXLATEST="y"
	[ "$BLOGINDEXLATEST" = "y" ] && [ "$BLOGINDEX" = "index.md" ] && \
	    BLOGINDEXLATEST="" # archive must be different if y

	# generate the index file
	cat "$_sitedir/site/${_manifestdir}/news-list.md.include" \
	    > "${_sitedir}/site/${_manifestdir}/$BLOGINDEX"
	printf "\nSubscribe to RSS: [feed.xml](feed.xml)\n\n" \
	    >> "${_sitedir}/site/${_manifestdir}/$BLOGINDEX"
	while read -r f; do
		_page="$(sanitizefilename "${f#"${_sitedir}/site/"}")"

		_protocol="$(echo "${DOMAIN%/}" | sed 's#://.*##')"

		_domain="$(echo "${DOMAIN%/}" | \
		    sed "s#${_protocol}://##" | sed 's#/.*##')"

		_path="$(echo "${DOMAIN%/}" | \
		    sed "s#^${_protocol}://${_domain}/\?##")"

		meta "${_page}" "${_sitedir}/site" "${_path}" \
		    >> "${_sitedir}/site/${_manifestdir}/$BLOGINDEX"
	done < "${tmpdir}/xnews"

	# generate the RSS index
	rss_header "$BLOGTITLE" "$DOMAIN" "$BLOGDESCRIPTION" "$_manifestdir" \
	    > "${_sitedir}/site/${_manifestdir}/feed.xml"
	while read -r f; do
		_page="$(sanitizefilename "${f#"${_sitedir}/site/"}")"
		rss_main "$_page" "$_sitedir" "$DOMAIN" \
		    >> "${_sitedir}/site/${_manifestdir}/feed.xml"
	done < "${tmpdir}/xnews"
	rss_footer >> "${_sitedir}/site/${_manifestdir}/feed.xml"

	if [ "${_sitedir}/site/${_manifestdir}/feed.xml" \
	    != "${_sitedir}/site/feed.xml" ] && \
	    [ "${_manifestdir}" = "${BLOGDIR%/}" ] && \
	    [ -n "${BLOGDIR%/}" ]; then
		rm -f "${_sitedir}/site/feed.xml"
		[ -f "${_sitedir}/site/${_manifestdir}/feed.xml" ] && \
			cp "${_sitedir}/site/${_manifestdir}/feed.xml" \
			    "${_sitedir}/site/feed.xml"
	fi

	mkhtml "$_sitedir/site/${_manifestdir}/$BLOGINDEX" "${_sitedir##*/}"

	# if index not the archive of news posts, make latest article
	# the index instead. next/prev buttons mean articles are still
	# possible to navigate, and an archive page would also be present
	if [ "$BLOGINDEXLATEST" = "y" ]; then
		if [ -z "$_manifestdir" ]; then
			mkhtml "$_sitedir/site/$currlink" "${_sitedir##*/}"
			cp "$_sitedir/site/${currlink%.md}.html" \
			    "$_sitedir/site/index.html" || \
			    err "mk !sitedir/index.md latest"
		else
			mkhtml "$_sitedir/site/$_manifestdir/$currlink" \
			    "${_sitedir##*/}"
			cp "$_sitedir/site/$_manifestdir/${currlink%.md}.html" \
			    "$_sitedir/site/$_manifestdir/index.html" || \
			    err "mk !sitedir/$_manifestdir/index.md latest"
		fi
	fi
}

# usage: meta file filedir
meta()
{
	if [ -n "${3}" ] ; then
		printf '%s\n' \
		"[$(mktitle "${2}/${1}")](/${3}/${1}){.title}"
	else
		printf '%s\n' \
		"[$(mktitle "${2}/${1}")](/${1}){.title}"
	fi

	printf '%s\n' \
	"[$(sed -n 3p "${2}/${1}" | sed -e s-^..--)]{.date}"
	printf "\n\n"
}

# usage: rss_header
rss_header()
{
	_blogtitle="${1}"
	_domain="${2}" # without a / at the end, but with http:// or https://
	_blogdescription="${3}"
	_blog="${4}"

	printf "%s\n" "<rss version=\"2.0\">"
	printf "%s\n" "<channel>"

	printf "%s\n" "<title>${_blogtitle}</title>"
	printf "%s\n" "<link>${_domain}${_blog}</link>"
	printf "%s\n" "<description>$_blogdescription</description>"
}

# usage: rss_main file
rss_main()
{
	_file="${1}"
	_sitedir="${2}"
	_domain="${3}"

	# render content and escape
	_htmlfile="${_file%.md}.html"

	_pagetitle=$(mktitle "${_sitedir}/site/${_file}")
	_pageurl="${_domain}${_htmlfile}"

	printf "%s\n" '<item>'
	printf "%s\n" "<title>${_pagetitle}</title>"
	printf "%s\n" "<link>${_pageurl}</link>"
	printf "%s" "<description><p>Article: ${_pagetitle}</p>"
	printf "%s\n" "<p>Web link: ${_pageurl}</p></description>"
	printf "</item>\n"
}

# usage: title file
mktitle()
{
	_firstchar=$(head -c 1 "${1}")
	_firstthreechars=$(head -c 3 "${1}")
	_titlestr="$(head -n1 "${1}")"
	if [ "${_firstchar}" = "%" ] || [ "${_firstchar}" = "#" ]; then
		_titlestr="$(sed -n 1p "${1}" | sed -e s-^..--)"
	elif [ "${_firstthreechars}" = "---" ]; then
		_titlestr="$(sed -n 2p "${1}" | sed -e s-^..--)"
		_titlestr="${_titlestr#* }"
	fi
	printf "%s\n" "${_titlestr}"
}

# usage: rss_footer
rss_footer()
{
	printf '%s\n' '</channel>'
	printf '%s\n' '</rss>'
}
