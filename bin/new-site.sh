#!/bin/bash
#
# Make this idempotent so as new features are added, this script
# can be run multiple times.
TOPDIR=$(realpath $(dirname $0)/..)
. $TOPDIR/etc/omd-build.env || exit 1
STARTDIR=$(pwd)
ONTTY=0
APACHETYPE=
tty -s && ONTTY=1

usage() {
    xval=$1
	shift
	[[ $@ ]] && echo "$@"
	echo "usage: OPTIONS [sitename]

Create a new OMD naemon site, configure NSCA, LiveStatus, and NRPD.

Options:
--------
    --site | -s sitename
        Use the site name specified.  Otherwise, it's determined based
        on the hostname.  This can be specified using the OMD_SITE envar.

    --query | -Q
        Query to to verify the site to install.
        This can be specified using the DO_QUERY envar, setting to 1 to
        query, and 0 to not query.

    --help | -h
	    Show this help.

    --verbose | -v
        Show a bit more information.

"
    exit $xval
}

# If the envars are set, make sure they are numbers.
test "$DO_QUERY" -eq "$DO_QUERY" >/dev/null 2>&1 || DO_QUERY=0
test "$VERBOSE" -eq "$VERBOSE" >/dev/null 2>&1 || VERBOSE=0
newtempfile TMPF1

while [[ $# -gt 0 ]]; do
	case "$1" in
		--query | -Q ) [[ $ONTTY -eq 1 ]] && DO_QUERY=1 ;;
		--help | -h ) usage 0 ;;
		--site | -s ) OMD_SITE="$2" ; shift ;;
		--verbose | -v ) VERBOSE=1 ;;
		-- ) break ;;
		* ) usage 2 "${1}: unknown option" ;;
	esac
	shift
done
export OMD_SITE

#
# This is very simple check that hopefully allows us to run this via
# an automatic script.
if [[ -z "$OMD_SITE" ]]; then
	LONGHOST=$(hostname)
	case "$LONGHOST" in
		*-nagios.fsautomation.com ) export OMD_SITE=$(basename $LONGHOST -nagios.fsautomation.com) ;;
		* )
			echo "This hostname is not of the {cust}-nagios.fsautomation.com format"
			echo "Rename the host properly, then run this script again, or specify"
			echo "the '-s' flag to override the site name."
			exit 1
			;;
	esac
fi

# See if it exists
SITE_EXISTS=0
# We exit 1 from awk if we DO find it.
if ! omd sites | awk '$1 == "'$OMD_SITE'" { exit(1); }' ; then
	out "Site exists.  Skipping creation step."
	SITE_EXISTS=1
fi

# Run an osm command for the site
# run_osm site command ...
run_omd() {
    typeset _site=$1
	shift
	echo "omd $@" | omd su $_site | egrep -v '^Last login'
}

#
# Initial configuration
if [[ $SITE_EXISTS -eq 0 ]]; then
	section "Installing new site: $OMD_SITE"
	if [[ $ONTTY -eq 1 && "$DO_QUERY" = "1" ]]; then
		read -p "Is this OK? > " ANS
		case "$ANS" in
			y* | Y* ) : ;;
			* ) out "Exiting"; exit 1 ;;
		esac
	fi
	newtempfile TMP_NSCA_PORTS
	newtempfile TMP_LIVE_PORTS
	
	# Grab a list of all of the NSCA and LIVESTATUS ports.
	for i in $(omd sites | awk '$NR > 1 { print $1 }'); do
		run_omd $i "config show NSCA_TCP_PORT" 2>/dev/null >> $TMP_NSCA_PORTS
		run_omd $i "config show LIVESTATUS_TCP_PORT" 2>/dev/null >> $TMP_LIVE_PORTS
	done
	sed -i -e '/Last login/d' -e '/^$/d' $TMP_NSCA_PORTS
	sed -i -e '/Last login/d' -e '/^$/d' $TMP_LIVE_PORTS
	
	date >> $LOGFILE

	omd create $OMD_SITE 2>&1 | verbout
	if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
		exit 1
	fi
	export OMD_ROOT=$(getent passwd $OMD_SITE | awk -F: '{ print $6 }')

	# Turn on NSCA
	run_omd $OMD_SITE config set NSCA on
	MYPORT=5667
	while grep -w -q $MYPORT $TMP_NSCA_PORTS ; do
		MYPORT=$(( MYPORT + 1 ))
	done
	out "Setting NSCA port to $MYPORT"
	echo "$MYPORT" >> $TMP_NSCA_PORTS
	run_omd $OMD_SITE config set NSCA_TCP_PORT $MYPORT 2>&1 | verbout

	if type -p firewall-cmd >/dev/null 2>&1 ; then
		out "Adding port to firewall"
		firewall-cmd --permanent --add-port=$MYPORT/tcp | verbout
		firewall-cmd --reload | verbout
	fi

	# Add live status
	run_omd $OMD_SITE config set LIVESTATUS_TCP on
	MYPORT=6557
	while grep -w -q $MYPORT $TMP_LIVE_PORTS ; do
		MYPORT=$(( MYPORT + 1 ))
	done
	out "Setting Livestatus port to $MYPORT"
	echo "$MYPORT" >> $TMP_LIVE_PORTS
	run_omd $OMD_SITE config set LIVESTATUS_TCP_PORT $MYPORT 2>&1 | verbout

	if type -p firewall-cmd >/dev/null 2>&1 ; then
		out "Adding port to firewall"
		firewall-cmd --permanent --add-port=$MYPORT/tcp 2>&1 | verbout
		firewall-cmd --reload 2>&1 | verbout
	fi

	# This next test may not be universal.
	if [[ "$OS_ID_LIKE" == *debian* ]]; then
		DST=/etc/apache2/conf-available/omd-default.site.conf
		if [[ ! -f $DST ]]; then
			out "Setting '$OMD_SITE' as the default site for this server."
			echo "RedirectMatch ^/$ /${OMD_SITE}/" > $DST
			a2enmod rewrite 2>&1 | verbout
			a2ensite omd-default.site 2>&1 | verbout
			systemctl restart apache2 2>&1 | verbout
		fi
	elif [[ "$OS_ID_LIKE" == *rhel* ]]; then
		systemctl status httpd >/dev/null 2>&1
		# A return of 4 means it doesn't exist.  Anything less than
		# that is either OK, it's down, or it's disabled.
		if [[ $? -lt 4 ]]; then
			DST=/etc/httpd/conf.d/omd-default.site.conf
			if [[ ! -f $DST ]]; then
				out "Setting '$OMD_SITE' as the default site for this server."
				echo "RedirectMatch ^/$ /${OMD_SITE}/" > $DEFSITECONF
				systemctl restart httpd 2>&1 | verbout
			fi
		fi
	fi

	out "Generating SSH key for git pulls"
	[[ ! -d $OMD_ROOT/.ssh ]] || mkdir $OMD_ROOT/.ssh
	DST=$OMD_ROOT/.ssh/id_ed25519
	ssh-keygen -t ed25519 -N '' -f $DST 2>&1 | verbout
	chown -R $OMD_SITE.$OMD_SITE $OMD_ROOT/.ssh
	chmod -R go-rwx $OMD_ROOT/.ssh

	echo ""
	out "You will need to paste this as a deploy key for the"
	out "omd-config-$OMD_SITE repo:"
	echo ""
	cat $DST.pub | tee -a $LOGFILE
	echo ""
	read -p "Press ENTER after this is done to continue> " ANS

	# Create a script to do the checkout so we can run it as the
	# omd user.
	out "Checking out the omd-config-$OMD_SITE repo"
	cat > $TMPF1<<EOF
#!/bin/bash
cd ~/local
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
git clone git@github.com:foresightautomation/omd-config-$OMD_SITE.git
EOF
	chmod 755 $TMPF1
	su $OMD_SITE -c "/bin/bash $TMPF1"
	chmod 600 $TMPF1
fi
## END of initial site creation

# Grab the OMD_ROOT
[[ -z "$OMD_ROOT" ]] && OMD_ROOT=$(getent passwd $OMD_SITE | awk -F: '{ print $6 }')

# Verify that USER5 is our nagios plugins
section "Setting up FSA resource paths"
DST=$OMD_ROOT/etc/naemon/resource.cfg
if egrep -q '^$USER5$=' $DST ; then
	out " \$USER5\$ is set"
else
	out "  setting \$USER5\$ to the fas plugins path"
	backup_file $DST
	echo "\$USER5\$=/forsight/lib64/nagios/plugins" >> $DST
fi
	
##
## NRDP
##
## NOTE: as of nrdp-2.0.4, the tar file included in the repo has been patched
##       to fix the file format of the checkresults file so that it works with
##       naemon.
function nrdp_config() {
	typeset _f1
	typeset CUR_VERSION=""
	NRDP_VERSION=2.0.5
	NRDP_TOP=$OMD_ROOT/local/share/nrdp

	out "Checking for NRDP $NRDP_VERSION"

	# Find the current version installed.
	# If the cur version is older than this script's version, back it up.
	# If the cur version is newer than this script's version, return.
	# If the cur version is the same as this script's version, return.
	_F1="$NRDP_TOP/server/includes/constants.inc.php"
	if [[ -f "$_F1" ]]; then
		CUR_VERSION=$(egrep '^define\("PRODUCT_VERSION",' "$_F1" | \
			sed -e 's/.*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/')
		if [[ -n "$CUR_VERSION" ]]; then
			# If the new version is newer than the previous version, 
			# then back it up.
			if version_gt "$NRDP_VERSION" "$CUR_VERSION" ; then
				out "NRDP $CUR_VERSION installed.  Backing up to $NRDP_TOP.$TIMESTAMP"
				
				OLD_NRDP_TOKEN=$($OMD_ROOT/local/bin/get-nrdp-password 2>/dev/null)
				/bin/mv "$NRDP_TOP" "$NRDP_TOP.$TIMESTAMP"
			elif version_gt "$CUR_VERSION" "$NRDP_VERSION" ; then
				out "NRDP $CUR_VERSION installed and is newer.  Skipping."
				return 1
			else
				out "NRDP $NRDP_VERSION installed.  Skipping."
				return 1
			fi
		fi
	fi

	# If we're here and we have a directory, then just return.
	[[ -d "$NRDP_TOP" ]] && return 1

	out "Installing NRDP $NRDP_VERSION"
	su $OMD_SITE -c "mkdir -p '$NRDP_TOP'" || exit 1
	tar --strip-components=1 -C "$NRDP_TOP" -xzf \
		$TOPDIR/src/nrdp-$NRDP_VERSION.tar.gz

	chown -R $OMD_SITE.$OMD_SITE "$NRDP_TOP"

	# because we're running in the global apache as 'apache' instead
	# of the site apache as the site user, we need to make sure that
	# the checkresults directory has the setgid bit set to allow
	# the site user to read and delete the files placed by the
	# apache user.
	out "  updating permissions on checkresults dir"
	chmod g+ws $OMD_ROOT/tmp/naemon/checkresults
	
	# Copy the nrdp.conf file
	out "  installing nrdp.conf apache config"
	sed -e "s|\${OMD_SITE}|$OMD_SITE|g" \
		-e "s|\${OMD_ROOT}|$OMD_ROOT|g" \
		"$TOPDIR"/src/nrdp.conf  > $TMPF1
	copy_site_file $TMPF1 "$OMD_ROOT/etc/apache/system.d/nrdp.conf"
	
	out "  updating nrdp config.inc.php ..."
	DST=$NRDP_TOP/server/config.inc.php

	if [[ -n "$OLD_NRDP_TOKEN" ]];  then
		out "  setting token to old token ..."
		/foresight/bin/omd-get-nrdp-password --set --password "$OLD_NRDP_TOKEN" $OMD_SITE
	else
		/foresight/bin/omd-get-nrdp-password --set $OMD_SITE
	fi
	
	# We're going to:
	#   - set the command group
	#   - set the checkresults dir
	#   - set the command file
	#   - change log file
	sed -i.$TIMESTAMP \
		-e "s/nagcmd/$OMD_SITE/" \
		-e "s|/usr/local/nagios/var/rw/nagios.cmd|$OMD_ROOT/tmp/run/naemon.cmd|" \
		-e "s|/usr/local/nagios/var/spool/checkresults|$OMD_ROOT/tmp/naemon/checkresults|" \
		-e "s|/usr/local/nrdp/server/debug.log|$OMD_ROOT/var/log/nrdp.debug.log|" \
		$DST
	
	out "  restarting httpd"
	case "$OS_ID_LIKE" in
		*rhel* ) systemctl restart httpd ;;
		*debian* ) systemctl restart apache2 ;;
	esac
}
nrdp_config
##
## NSCP
##
function nscp_config() {
	typeset _f1
	NSCP_TOP=$OMD_ROOT/local/share/nscp

	section "Checking NSCP ..."

	if [[ ! -d "$NSCP_TOP" ]]; then
		out "  installing NSCP directory ... "
		su $OMD_SITE -c "mkdir -p '$NSCP_TOP'"
		chown -R $OMD_SITE.$OMD_SITE "$NSCP_TOP"
	fi

	# Copy the Apache nscp.conf file
	_f1="$OMD_ROOT/etc/apache/system.d/nscp.conf"
	if [[ ! -f "$_f1" ]]; then
		out "  installing nscp.conf apache config"
		sed -e "s|\${OMD_SITE}|$OMD_SITE|g" \
			-e "s|\${NSCP_TOP}|$NSCP_TOP|g" \
			"$TOPDIR"/src/nscp-apache.conf  > $TMPF1
		copy_site_file $TMPF1 "$OMD_ROOT/etc/apache/system.d/nscp.conf"
	
		out "  reloading httpd"
		case "$OS_ID_LIKE" in
			*rhel* ) systemctl reload httpd ;;
			*debian* ) systemctl reload apache2 ;;
		esac
	fi
}
nscp_config

#
	
section "Finished."
echo "Logged to $LOGFILE"
echo ""
echo "To complete the site setup, run:"
echo ""
echo "    omd su $OMD_SITE"
echo "    omd start"
echo "    ./local/nagios-config/bin/run-deploy.pl"
echo "    hash -r"
echo "    fsa-init-naemon-server"
