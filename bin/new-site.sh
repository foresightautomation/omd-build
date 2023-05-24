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
	[[ $# -gt 0 ]] && echo "$@"
	echo "usage: OPTIONS [sitename]

Create a new OMD naemon site, configure NSCA, LiveStatus, and NRPD.

Options:
--------
    --site | -s sitename
        Use the site name specified.  Otherwise, it's determined based
        on the hostname.  This can be specified using the OMD_SITE envar.

    --branch {branch_name}
        The branch name for the omd-config-{site} repo.  Default is master.

    --help | -h
	    Show this help.

    --verbose | -v
        Show a bit more information.

"
    exit $xval
}

# If the envars are set, make sure they are numbers.
test "$VERBOSE" -eq "$VERBOSE" >/dev/null 2>&1 || VERBOSE=0
newtempfile TMPF1

BRANCH=
while [[ $# -gt 0 ]]; do
	case "$1" in
		--help | -h ) usage 0 ;;
		--site | -s ) OMD_SITE="$2" ; shift ;;
		--branch ) BRANCH="$2" ; shift ;;
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

##
## Helper functions
##
# Run an omd command for the site
# run_omd site command ...
function run_omd() {
    typeset _site=$1
	shift
	echo "$@" | omd su $_site
	return ${PIPESTATUS[1]}
}
# Run command as the $OMD_SITE user
function run_site() {
	runuser -u $OMD_SITE -- "$@"
}
##
## END Helper functions
##


# See if it exists
# We exit 1 from awk if we DO find it.
if ! omd sites | awk '$1 == "'$OMD_SITE'" { exit(1); }' ; then
	out "Site exists.  Skipping creation step."
else 
	out "Creating new site: $OMD_SITE"
	omd create $OMD_SITE 2>&1 | verbout
	[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
fi

out "Retrieving OMD_ROOT"
OMD_ROOT=$(getent passwd $OMD_SITE | awk -F: '{ print $6 }')
if [[ -z "$OMD_ROOT" ]] ; then
	echo "Cannot find $OMD_SITE password entry."
	exit 1
fi

CFGREPO="omd-config-$OMD_SITE"
CFGREPOTOP=$OMD_ROOT/local/$CFGREPO

section "Checking network services"
newtempfile TMPPORTS
VAL=$(run_omd $OMD_SITE omd config show NSCA)
if [[ "$VAL" = "on" ]]; then
	VAL=$(run_omd $OMD_SITE omd config show NSCA_TCP_PORT)
	out "  NSCA is already configured and is using port $VAL"
else
	out "  finding NSCA ports."
	> $TMPPORTS
	for i in $(omd sites | awk '$NR > 1 { print $1 }') ; do
		run_omd $i omd config show NSCA_TCP_PORT >> $TMPPORTS
	done
	sort -u -o $TMPPORTS $TMPPORTS
	MYPORT=$(( $(tail -1 $TMPPORTS) + 1 ))
	out "  turning on NSCA"
	run_omd $OMD_SITE omd config set NSCA on 2>&1 | verbout
	[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	out "  setting NSCA port to $MYPORT"
	run_omd $OMD_SITE omd config set NSCA_TCP_PORT $MYPORT 2>&1 | verbout
	[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	if type -p firewall-cmd >/dev/null 2>&1 ; then
		out "  adding NSCA port to firewall"
		firewall-cmd --permanent --add-port=$MYPORT/tcp | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
		firewall-cmd --reload | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	fi
fi

VAL=$(run_omd $OMD_SITE omd config show LIVESTATUS_TCP)
if [[ "$VAL" = "on" ]]; then
	VAL=$(run_omd $OMD_SITE omd config show LIVESTATUS_TCP_PORT)
	out "  LIVESTATUS is already configured and is using port $VAL"
else
	out "  finding LIVESTATUS ports."
	> $TMPPORTS
	for i in $(omd sites | awk '$NR > 1 { print $1 }') ; do
		run_omd $i omd config show LIVESTATUS_TCP_PORT >> $TMPPORTS
	done
	sort -u -o $TMPPORTS $TMPPORTS
	MYPORT=$(( $(tail -1 $TMPPORTS) + 1 ))
	out "  turning on LIVESTATUS"
	run_omd $OMD_SITE omd config set LIVESTATUS_TCP on 2>&1 | verbout
	[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	out "  setting LIVESTATUS port to $MYPORT"
	run_omd $OMD_SITE omd config set LIVESTATUS_TCP_PORT $MYPORT 2>&1 | verbout
	[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	if type -p firewall-cmd >/dev/null 2>&1 ; then
		out "  adding LIVESTATUS port to firewall"
		firewall-cmd --permanent --add-port=$MYPORT/tcp | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
		firewall-cmd --reload | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	fi
fi

section "Checking httpd configuration."
# This next test may not be universal.
if [[ -d /etc/apache2/conf-available ]]; then
	if a2query -c | egrep -q "^omd-default" ; then
		out "  omd-default already configured"
	else
	DST=/etc/apache2/conf-available/omd-default.conf
		out "  setting '$OMD_SITE' as the default site for this server."
		echo "RedirectMatch ^/$ /${OMD_SITE}/" > $DST
		a2enmod rewrite 2>&1 | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
		a2enconf omd-default 2>&1 | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
		systemctl reload apache2 2>&1 | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	fi
elif [[ "$OS_ID_LIKE" == *rhel* ]]; then
	systemctl status httpd >/dev/null 2>&1
	# A return of 4 means it doesn't exist.  Anything less than
	# that is either OK, it's down, or it's disabled.
	if [[ $? -lt 4 ]]; then
		DST=/etc/httpd/conf.d/omd-default.conf
		if [[ -f $DST ]]; then
			out "  omd-default already configured"
		else
			out "  setting '$OMD_SITE' as the default site for this server."
			pause 3
			echo "RedirectMatch ^/$ /${OMD_SITE}/" > $DEFSITECONF
			systemctl restart httpd 2>&1 | verbout
			[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
		fi
	else
		out "  httpd status bad."
		exit 1
	fi
fi

section "Configuring $CFGREPO repo."

DST=$OMD_ROOT/.ssh/${CFGREPO}_git_ed25519
if [[ -f $DST ]]; then
	out "  SSH key for git pulls exists."
else
	out "  generating SSH key for git pulls"
	pause 3
	# After creating the key, chown/chmod the entire directory
	[[ -d $OMD_ROOT/.ssh ]] || mkdir $OMD_ROOT/.ssh
	ssh-keygen -t ed25519 -N '' -f $DST 2>&1 | verbout
	[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	chown -R $OMD_SITE.$OMD_SITE $OMD_ROOT/.ssh
	chmod -R go-rwx $OMD_ROOT/.ssh
	
	echo ""
	out "You will need to paste this as a deploy key for the"
	out "$CFGREPO repo:"
	echo ""
	cat $DST.pub | tee -a $LOGFILE
	echo ""
	pause "Press ENTER after this is done to continue"
fi

# Create a script to do the checkout so we can run it as the
# omd user.
section "Checking out the omd-config-$OMD_SITE repo"
if [[ -d "$OMD_ROOT/local/$CFGREPO/.git" ]]; then
	out "  $CFGREPO exists."
else
	cat > $TMPF1<<EOF
#!/bin/bash
cd ~/local || exit 1
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || exit 1
export GIT_SSH_COMMAND="ssh -i $DST -o IdentitiesOnly=yes"
git clone --no-checkout git@github.com:foresightautomation/omd-config-$OMD_SITE.git || exit 1
cd omd-config-$OMD_SITE || exit 1
git config core.worktree $OMD_ROOT || exit 1
git reset --hard origin/master || exit 1
git pull || exit 1
EOF
	if [[ -n "$BRANCH" ]]; then
		cat >> $TMPF1 <<EOF
git checkout $BRANCH || exit 1
git pull || exit 1
EOF
	fi
	chmod 755 $TMPF1
	su $OMD_SITE -c "/bin/bash $TMPF1" || exit 1
	chmod 600 $TMPF1
fi


# Verify that USER5 is our nagios plugins
section "Checking FSA resource paths"
pause 3
DST=$OMD_ROOT/etc/naemon/resource.cfg
if egrep -q '^\$USER5\$=' $DST ; then
	out " \$USER5\$ is set"
else
	out "  setting \$USER5\$ to the fsa plugins path"
	backup_file $DST
	echo "\$USER5\$=/forsight/lib64/nagios/plugins" >> $DST || exit 1
	chown $OMD_SITE.$OMD_SITE $DST
	chmod 664 $DST
fi

# Make sure our common config dir is set
section "Checking FSA config paths"
DDIR=/foresight/etc/naemon/conf.d/common.d
DST=$OMD_ROOT/etc/naemon/naemon.d/$CFGREPO.cfg
if egrep -q "^cfg_dir=$DDIR" $DST 2>/dev/null ; then
	out "  $DDIR set as config dir."
else
	out "  adding 'cfg_dir=$DDIR'"
	test -d $DDIR || mkdir -p $DDIR || exit 1
	backup_file $DST
	echo "cfg_dir=$DDIR" >> $DST || exit 1
	chown $OMD_SITE.$OMD_SITE $DST
	chmod 664 $DST
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

	section "Checking NRDP ..."
	pause 3
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

			if (( $(bc -l <<< "$NRDP_VERSION > $CUR_VERSION") )) ; then
				out "NRDP $CUR_VERSION installed.  Backing up to $NRDP_TOP.$TIMESTAMP"
				
				OLD_NRDP_TOKEN=$($OMD_ROOT/local/bin/get-nrdp-password 2>/dev/null)
				/bin/mv "$NRDP_TOP" "$NRDP_TOP.$TIMESTAMP"
			elif (( $(bc -l <<< "$CUR_VERSION > $NRDP_VERSION") )) ; then
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

	out "  installing NRDP $NRDP_VERSION"
	pause 3
	run_site mkdir -p "$NRDP_TOP" || exit 1
	# We can't run this as the OMD_SITE user, as the tar file and
	# apache config files are in root's home directory.
	tar --strip-components=1 -C "$NRDP_TOP" -xzf \
			 $TOPDIR/src/nrdp-$NRDP_VERSION.tar.gz

	chown -R $OMD_SITE.$OMD_SITE "$NRDP_TOP"

	# because we're running in the global apache as 'apache' instead
	# of the site apache as the site user, we need to make sure that
	# the checkresults directory has the setgid bit set to allow
	# the site user to read and delete the files placed by the
	# apache user.
	out "  updating permissions on checkresults dir"
	pause 3
	chmod g+ws $OMD_ROOT/tmp/naemon/checkresults
	
	# Copy the nrdp.conf apache file
	out "  installing nrdp.conf apache config"
	pause 3
	sed -e "s|\${OMD_SITE}|$OMD_SITE|g" \
		-e "s|\${OMD_ROOT}|$OMD_ROOT|g" \
		"$TOPDIR"/src/nrdp-apache.conf  > $TMPF1 || exit 1
	copy_site_file $TMPF1 "$OMD_ROOT/etc/apache/system.d/nrdp.conf"
	
	out "  updating nrdp config.inc.php ..."
	pause 3
	DST=$NRDP_TOP/server/config.inc.php

	if [[ -n "$OLD_NRDP_TOKEN" ]];  then
		out "  setting token to old token ..."
		/foresight/sbin/omd-get-nrdp-password --set --password "$OLD_NRDP_TOKEN" $OMD_SITE
	else
		out "  creating new token"
		/foresight/sbin/omd-get-nrdp-password --set $OMD_SITE
	fi
	
	# We're going to:
	#   - set the command group
	#   - set the checkresults dir
	#   - set the command file
	#   - change log file
	backup_file $DST
	sed -i \
		-e "s/nagcmd/$OMD_SITE/" \
		-e "s|/usr/local/nagios/var/rw/nagios.cmd|$OMD_ROOT/tmp/run/naemon.cmd|" \
		-e "s|/usr/local/nagios/var/spool/checkresults|$OMD_ROOT/tmp/naemon/checkresults|" \
		-e "s|/usr/local/nrdp/server/debug.log|$OMD_ROOT/var/log/nrdp.debug.log|" \
		$DST
	
	out "  restarting httpd"
	pause 3
	case "$OS_ID_LIKE" in
		*rhel* ) systemctl restart httpd ;;
		*debian* ) systemctl restart apache2 ;;
	esac
}
nrdp_config
##
## NSCP
##
# The NSCP configuration is a directory that will contain content that
# is downloadable by the clients.  Management of those files needs to
# be done elsewhere.  Common files can be hard linked between sites to
# save space, and customer/site specific files can simply be there.
NSCP_TOP=$OMD_ROOT/local/share/nscp

section "Checking NSCP ..."
pause 3

if [[ -d "$NSCP_TOP" ]]; then
	out "  NSCP directory exits"
else
	out "  creating NSCP directory ... "
	mkdir -p "$NSCP_TOP"
	chown -R $OMD_SITE.$OMD_SITE "$NSCP_TOP"
fi

# Copy the Apache nscp.conf file.
DST="$OMD_ROOT/etc/apache/system.d/nscp.conf"
if [[ -f "$DST" ]]; then
	out "  nscp.conf apache config already installed."
else
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

section "Updating htpasswd file"
DST=$OMD_ROOT/etc/htpasswd
if ! egrep -q "^dchang:" $DST ; then
	add_htpasswd_entry "$DST" "dchang" '$apr1$JmfsY5Fo$nt5mLa853LxVHmX86K7Ax.'
fi
if ! egrep -q "^erickson:" $DST ; then
	add_htpasswd_entry "$DST" "erickson" '$apr1$heLauRBm$j6o9EBPDDm5bCYMOiUrrH0'
fi
if ! egrep -q "^dgood:" $DST ; then
	add_htpasswd_entry "$DST" "dgood" '$apr1$h3TsjY2Z$.De2TpyAHfI0zw9O8ldGS0'
fi
if ! egrep -q "^fsareports:" $DST ; then
	add_htpasswd_entry "$DST" "fsareports" '$apr1$OH7Qx5bW$1/4AAcmVLgw/MDjFAShY/1'
fi
chown $OMD_SITE.$OMD_SITE $DST
chmod 664 $DST
#

# Run the deploy scripts.  As we've already checked out the files, we will
# want to do the initialize, post-deploy, and safe-deploy scripts.
# We want to run these through 'omd su' so the entire environment gets set
# up.
section "Running the deploy scripts as $OMD_SITE"
out "  ${CFGREPO}-initialize"
DST=$OMD_ROOT/local/sbin/${CFGREPO}-initialize
run_omd $OMD_SITE $DST
out "  ${CFGREPO}-post-deploy"
DST=$OMD_ROOT/local/sbin/${CFGREPO}-post-deploy
run_omd $OMD_SITE $DST
out "  safe-deploy"
DST=$OMD_ROOT/local/$CFGREPO/${OMD_SITE}.d
run_omd $OMD_SITE /foresight/sbin/omd-safe-deploy-ncfg.sh $DST
	
section "Finished."
echo "Logged to $LOGFILE"
echo ""
echo "To complete the site setup, run:"
echo ""
echo "    omd restart $OMD_SITE"
