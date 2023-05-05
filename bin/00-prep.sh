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

section "System Settings"
pause 3
if type -p getenforce >/dev/null 2>&1 ; then
	if [[ $(getenforce) = "Disabled" ]]; then
		out "SELinux already disabled"
	else
		out "Disabling SELINUX"
		sed -i -e 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
		setenforce 0
	fi
else
	out "SELINUX not installed."
fi
# First, set the timezone
DOSET=1
TIMEZONE="$TZ"
if [[ -z "$TIMEZONE" ]]; then
	TIMEZONE=$(timedatectl | grep 'Time zone' | awk '{ print $3 }')
fi
if [[ -z "$TIMEZONE" ]]; then
	TIMEZONE=$(readlink /etc/localtime 2>/dev/null | sed -e 's,^.zoneinfo/,,')
fi
if [[ -n "$TIMEZONE" && "$TIMEZONE" =~ ^America ]]; then
	DOSET=0
fi
if [[ -z "$TIMEZONE" ]]; then
	TIMEZONE=America/Los_Angeles
fi
if [[ $DOSET -eq 1 ]]; then
	read -i $TIMEZONE -p "Enter timezone [$TIMEZONE]> " ANS
	[[ -n "$ANS" ]] && TIMEZONE="$ANS"
	out "setting system timezone to $TIMEZONE"
	timedatectl set-timezone $TIMEZONE || exit 1
else
	out "system timezone already set to $TIMEZONE"
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
			* ) installpkgs epel-release || exit 1 ;;
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
elif [[ "$OS_PKGTYPE" = "apt" ]] ; then
	LSBRELEASE=$(lsb_release -cs)
	DISTRIBUTOR_ID=$(lsb_release -is | tr '[A-Z]' '[a-z]')
	newtempfile LCSKEY
	DO_APT_UPDATE=0

	# Install the FSA repo.
	out "installing fsautomation.com repo"
	if add_apt_repo http://apt.fsautomation.com/$DISTRIBUTOR_ID \
				 http://apt.fsautomation.com/$DISTRIBUTOR_ID/APT-GPG-KEY ; then
		DO_APT_UPDATE=1
	fi

	# Install the Consol Labs repo
	out "installing labs.consol.de repo"
	if add_apt_repo https://labs.consol.de/repo/stable/$DISTRIBUTOR_ID \
					https://labs.consol.de/repo/stable/RPM-GPG-KEY ; then
		DO_APT_UPDATE=1
	fi
	out "Running apt update.  This can take awhile..."
	apt update | verbout
fi

# Now install the rest of the packages
PKGSFILE=$TOPDIR/etc/${OS_PKGTYPE}-pkgs.list
newtempfile DEPPKGS
egrep -v '#' $PKGSFILE > $DEPPKGS 2>/dev/null
if [[ -s $DEPPKGS ]]; then
	XVAL=0
	section "Checking dependency packages"
	# Doing this in a loop takes longer, but it will output more
	# more info.  Also, when an install fails, we can see it.
	exec 3<$DEPPKGS
	newtempfile DEPPKGS2
	while read -u 3 pkg ; do
		if check4pkg $pkg ; then
			out "package $pkg already installed"
		else
			echo "$pkg" >> $DEPPKGS2
		fi
	done
	if [[ ! -s $DEPPKGS2 ]]; then
		out "no packages need to be installed"
	else
		exec 3<$DEPPKGS2
		out "installing" $(wc -l < $DEPPKGS2) "package(s)"
		while read -u 3 pkg ; do
			installpkgs $pkg || XVAL=1
		done
	fi
	if [[ $XVAL -eq 1 ]]; then
		out "Error installing some packages."
		exit 1
	fi
fi

# If we're on amazon linux, python36 is not available.  So, do this 
# hack to allow omd to work
DST=/usr/lib64/libpython3.6m.so.1.0
if [[ "$OS_ID" = "amzn" && ! -f $DST ]]; then
	PYVERS=$(python3 --version | awk '{ print $2 }')
	# break up x.y.z
	IFS=. read x y z <<< "$PYVERS"
	PYVERS="$x.$y"
	
	out "HACK - linking python $PYVERS library to libpython3.6m"
	ln -s "$PYVERS" $DST
fi

# If we're not on amzn linux, add web protocols to the firewall.
if [[ "$OS_ID" != "amzn" ]]; then
	#checkandinstall haveged || exit 1
	#checkandinstall haveged || exit 1
	#systemctl enable haveged 2>&1 | verbout
	#systemctl start haveged 2>&1 | verbout
	
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


out "Checking timezone in php init file(s)"
if [[ -f /etc/php.ini ]]; then
	PHPINIFILES=(/etc/php.ini)
else
	PHPINIFILES=( $(find /etc/php -name php.ini) )
fi
for DST in "${PHPINIFILES[@]}" ; do
	if egrep -q '^date.timezone' "$DST" ; then
		out "  $DST has timezone set"
		continue
	fi
	out "  updating timezone in $DST"
	backup_file $DST
	sed -i -e "/;date.timezone/a date.timezone = \"$TIMEZONE\"" $DST
done

section "Checking SSL configuration"
# Check to see if the standard SSL site is configured.
SSLKEYFILE=/etc/pki/wildcard.fsautomation.com/private/wildcard.fsautomation.com.key
SSLCRTFILE=/etc/pki/wildcard.fsautomation.com/certs/wildcard-combined.crt
COPYFSA=1
if [[ ! -f $SSLKEYFILE || ! -f $SSLCRTFILE ]] ; then
	echo "FSA SSL key file or crt file not found."
	PS3="Choose option:"
	select o in "Use current SSL cert" "Copy FSA Cert then continue" ; do
		case $REPLY in
			1 ) COPYFSA=0 ; break ;;
			2 )
				out "Copy over the wildcart certs to /etc/pki/wildcard.fsautomation.com now,"
				read -p "then press ENTER to continue> " ANS
				COPYFSA=1
				break
				;;
		esac
	done
fi
if [[ $COPYFSA -eq 0 ]]; then
	out "Skipping setting FSA SSL cert in apache."
elif [[ ! -f $SSLKEYFILE || ! -f $SSLCRTFILE ]] ; then
	out "SSL key and crt file still not found.  Skipping."
else
	# Find the file
	SSLCONFFILE=
	for i in /etc/httpd/conf.d/ssl.conf /etc/apache2/sites-available/default-ssl.conf ; do
		[[ -f $i ]] || continue
		SSLCONFFILE=$i
		break
	done
	if [[ -z "$SSLCONFFILE" ]]; then
		out "ERROR: could not find ssl.conf file"
	else
		if ! grep -q "SSLCertificateFile $SSLCRTFILE" $SSLCONFFILE || \
				! grep -q "SSLCertificateKeyFile $SSLKEYFILE" $SSLCONFFILE ; then
			out "Setting global SSL cert to wildcard cert in $SSLCONFFILE"
			backup_file $SSLCONFFILE
			sed -E -i -e "s,^([[:blank:]]*)SSLCertificateFile[[:blank:]].*,\\1SSLCertificateFile $SSLCRTFILE," \
				-e "s,^([[:blank:]]*)SSLCertificateKeyFile[[:blank:]].*,\\1SSLCertificateKeyFile $SSLKEYFILE," \
				$SSLCONFFILE
		else
			out "Apache SSL config already using FSA cert."
		fi
	fi
fi

DST=/foresight/etc/omd-build.env
out "Creating $DST ..."
# The /foresight/etc dir will have been created by the packages.
cp $TOPDIR/etc/omd-build.env $DST || exit 1
chmod 644 $DST || exit 1

section "Pulling the omd-config-common repo."
DST=/root/.ssh/omd-config-common_git_ed25519
out "Generating SSH key for git pulls"
if [[ ! -d /root/.ssh ]] ; then
	mkdir /root/.ssh || exit 1
	chmod 700 /root/.ssh | exit 1
fi
if [[ ! -f $DST ]]; then
	out "generating ssh key ..."
	ssh-keygen -t ed25519 -N '' -f $DST 2>&1 | verbout
	chmod 644 $DST || exit 1

	echo ""
	out "You will need to paste this as a deploy key for the"
	out "omd-config-common repo:"
	echo ""
	cat $DST.pub | tee -a $LOGFILE
	echo ""
	read -p "Press ENTER after this is done to continue> " ANS
fi

out "checking out omd-config-common repo ..."
# Create a script to do the checkout so we don't mess with our
# envars.  This is taken from the README.md file of the repo.
newtempfile CLONESCRIPT
chmod 700 $CLONESCRIPT
cat > $CLONESCRIPT<<EOF
#!/bin/bash
cd /root
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
export GIT_SSH_COMMAND='ssh -i /root/.ssh/omd-config-common_git_ed25519 -o IdentitiesOnly=yes'
git clone --no-checkout git@github.com:foresightautomation/omd-config-common.git
cd omd-config-common
git config core.worktree /
git reset --hard origin/master
git pull
unset GIT_SSH_COMMAND
EOF
/bin/bash $CLONESCRIPT
if false ; then
	/usr/local/sbin/omd-config-common-initialize
	/usr/local/sbin/omd-config-common-run-deploy
fi
section "Finished."
out "The log file is $LOGFILE"
out "To create a new site, you can run:"
out ""
out "    $TOPDIR/bin/new-site.sh {sitename}"
