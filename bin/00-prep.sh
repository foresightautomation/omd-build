#!/bin/bash
#
# Prep the system.
TOPDIR=$(realpath $(dirname $0)/..)
. $TOPDIR/etc/omd-build.env || exit 1
STARTDIR=$(pwd)

usage() {
	xval=$1
	shift
	[[ $# -gt 0 ]] && echo "$@"
	echo "usage: $PROG [-v]

Prepare the server as an OMD server by installing software and
updating various configurations of the system.

Options:
--------
    -v    verbose.  Print more of what's going on.
"
	exit $xval
}
VERBOSE=0
while getopts vh c ; do
	case "$c" in
		v ) VERBOSE=1 ;;
		h ) usage 0 ;;
		* ) usage 2 "unknown argument" ;;
	esac
done
shift $(( OPTIND - 1 ))

if [[ $(getenforce) = "Disabled" ]]; then
	out "SELinux already disabled"
else
	out "Disabling SELINUX"
	sed -i -e 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
	setenforce 0
fi

section "Installing base repos and updates"
pause 3
if [[ "$OS_PKGTYPE" = "yum" ]] ; then
	checkandinstall yum-utils || exit 1
	checkandinstall deltarpm || exit 1

	# Install the epel release.  Only needed for yum.
	if check4pkg epel-release ; then
		out "epel-release already installed."
	else
		case "$OS_ID" in
			amzn )
				out "Installing epel"
				amazon-linux-extras install epel -y | verbout
				[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
				;;
			* ) installpkg epel-release || exit 1 ;;
		esac
	fi

	# Install Foresight Automation repo
	if check4pkg fsatools-release ; then
		out "fsatools-release already installed."
	else
		out "installing fsatools-release"
		yum -y install http://yum.fsautomation.com/fsatools-release-centos7.noarch.rpm | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	fi

	# Install the Consol Labs repo
	if check4pkg labs-consol-stable ; then
		out "labs-consol-stable already installed"
	else
		out "installing labs-consol-stable repo"
		pause 3
		yum -y install https://labs.consol.de/repo/stable/rhel7/i386/labs-consol-stable.rhel7.noarch.rpm | verbout
		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
	fi

	out "Running yum update.  This can take awhile..."
	yum -y update | verbout
	[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
else
	# Install the Consol Labs repo
	DST=/etc/apt/sources.list.d/labs-consol-stable.list
	if [[ -f $DST ]]; then
		out "labs-console-stable package source already installed"
	else
		out "Installing labs-console-stable package source"
		LSBRELEASE=$(lsb_release -cs)
		newtempfile LCSKEY
		curl -s "https://labs.consol.de/repo/stable/RPM-GPG-KEY" > $LCSKEY
		# 20.04 was the last time apt-key was valid
		if version_gt 20.04 $OS_VERS ; then
			mv $LCSKEY /etc/apt/trusted.gpg.d/labs.console.de.asc
		else
			cat $LCSKEY | apt-key add -
		fi
		echo "deb http://labs.consol.de/repo/stable/ubuntu $(lsb_release -cs) main" > $DST
		out "Running apt update."
		apt update | verbout
	fi
fi

# Now install the rest of the packages
PKGSFILE=$TOPDIR/etc/${OS_PKGTYPE}-pkgs.list
newtempfile DEPPKGS
egrep -v '#' $PKGSFILE > $DEPPKGS 2>/dev/null
if [[ -s $DEPPKGS ]]; then
	section "Installing dependency packages"
	# Doing this in a loop takes longer, but it will output more
	# more info.
	exec 3<$DEPPKGS
	while read -u 3 pkg ; do
		checkandinstall $pkg || exit 1
	done
fi

# If we're not on amzn linux, install haveged, which provides
# entropy.  We also want to add web protocols to the firewall.
if [[ "$OS_ID" != "amzn" ]]; then
	checkandinstall haveged || exit 1
	checkandinstall haveged || exit 1
	systemctl enable haveged 2>&1 | verbout
	systemctl start haveged 2>&1 | verbout
	
	newtempfile FIREWALLSVCS
	if firewalcmd --list-services > $FIREWALLSVCS 2>&1 ; then
		_reload=0
		for i in http https ; do
			grep -qw $i $FIREWALLSVCS && continue
			out "Adding $i to firewall rules"
			firewall-cmd --permanent --add-service=$i | verbout
			_reload=1
		done
		if [[ $_reload -eq 1 ]]; then
			out "Reloading firewall"
			firewall-cmd --reload | verbout
		fi
	fi
fi

# Update the php.ini file
DST=/etc/php.ini
BKUP=$DST.$TIMESTAMP
if ! egrep -q '^date.timezone' $DST ; then
	out "Updating timezone in $DST"
	set_timezone() {
		TIMEZONE="$TZ"
		[[ -n "$TIMEZONE" ]] && return 0
		TIMEZONE=$(timedatectl | grep 'Time zone' | awk '{ print $3 }')
		[[ -n "$TIMEZONE" && "$TIMEZONE" =~ ^America ]] && return 0
		TIMEZONE=$(readlink /etc/localtime 2>/dev/null | sed -e 's,^.zoneinfo/,,')
		[[ -n "$TIMEZONE" ]] && return 0
		return 1
	}

	if ! set_timezone ; then
		out "  could not determine timezone"
		read -p "Enter Timezone: " TIMEZONE
	fi
	if [[ -n "$TIMEZONE" ]]; then
		backup_file $DST
		sed -i -e "/;date.timezone/a date.timezone = \"$TIMEZONE\"" $DST
	else
		out "  skipping timezone."
	fi
fi

section "Finished."
out "The log file is $LOGFILE"
out "To create a new site, you can run:"
out ""
out "    $TOPDIR/bin/new-site.sh {sitename}"
