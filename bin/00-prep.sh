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
  --branch {name}
    The branch of the omd-config-common package.

  --awsami
    AWS AMI mode.  This is used by the special AWS instance that will
    be used to generate an AMI.  Host-specific things will NOT be
    performed here.

  --fsaami
    This is a monitoring server for an FSA AMI client.  Extra packages
    or configuration may be performed.

  --site-name {name}
    Run the new-site script with the site name specified.

  --site-branch {branch}
    If running the new-site script, set this as the branch for the
    omd-config-{site} repo.

  --verbose
    Print more of what's going on.
"
	exit $xval
}
VERBOSE=0
AMIMODE=0
FSAAMI=0
BRANCH=""
SITE_NAME=
SITE_BRANCH=
while [[ $# -gt 0 ]]; do
	case "$1" in
		--branch | -b ) BRANCH="$2" ; shift ;;
		--awsami ) AMIMODE=1 ;;
		--fsaami ) FSAAMI=1 ;;
		--site-name ) SITE_NAME="$2" ; shift ;;
		--site-branch ) SITE_BRANCH="$2" ; shift ;;
		--verbose | -v ) VERBOSE=1 ;;
		--help | -h  ) usage 0 ;;
		* ) usage 2 "${1}: unknown argument" ;;
	esac
	shift
done
shift $(( OPTIND - 1 ))

# This is the ssh key for pulling the git repo
SSH_IDFILE=/root/.ssh/omd-config-common_git_ed25519

section "System Settings"
# Grab all of the host information up top to let the rest of the
# script run without interruption.
if [[ $AMIMODE -eq 0 ]]; then
	# Set the timezone
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
	
	# Check the hostname.  We eventually want {cust}-nagios.fsautomation.com
	CURHN=$(hostname)
	NEWHN=
	if [[ $CURHN != *.fsautomation.com ]]; then
		out "checking hostname."
		# Set ANS to be the suggested name
		if [[ $CURHN == *.compute.internal ]]; then
			# This is an aws name.  See if there's a CNAME set up
			# for it in the foresightautomation.biz domain.
			ANS=$(dig +short CNAME $(hostname -s))
			if [[ -n "$ANS" && "$ANS" != *.* ]]; then
				ANS=$ANS.fsautomation.com
			fi
		elif [[ $CURNH == *.* ]]; then
			# It's a FQHN.  Use that for our suggestion
			ANS=$CURHN
		else
			# Otherwise, put it into the fsautomation.com domain
			ANS=$CURHN.fsautomation.com
		fi
		read -e -i "$ANS" -p "Enter FQHN for this server: " NEWHN
	fi
	if [[ -n "$NEWHN" ]]; then
		out "  updating hostname"
		hostnamectl set-hostname $NEWHN || exit 1
	fi
	DST=$SSH_IDFILE
	if [[ -f $DST ]]; then
		out "SSH key for omd-config-common git pull exists."
	else
		out "Generating SSH key for omd-config-common git pulls"
		if [[ ! -d /root/.ssh ]] ; then
			mkdir /root/.ssh || exit 1
			chmod 700 /root/.ssh | exit 1
		fi
		ssh-keygen -t ed25519 -N '' -f $DST 2>&1 | verbout
		if [[ ${PIPESTATUS[0}} -eq 0 ]] ; then
			echo "error generating ssh key"
			exit 1
		fi
		chmod 644 $DST || exit 1
		
		echo ""
		out "You will need to paste this as a deploy key for the"
		out "omd-config-common repo:"
		echo ""
		cat $DST.pub | tee -a $LOGFILE
		echo ""
		pause "Press ENTER after this is done to continue"
	fi
fi

if type -p getenforce >/dev/null 2>&1 ; then
	if [[ $(getenforce) = "Disabled" ]]; then
		out "SELinux already disabled"
	else
		out "Disabling SELINUX"
		sed -i -e 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
		setenforce 0 || exit 1
	fi
else
	out "SELINUX not installed."
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
#	if check4pkg labs-consol-stable ; then
#		out "labs-consol-stable already installed"
#	else
#		out "installing labs-consol-stable repo"
#		pause 3
#		yum -y install https://labs.consol.de/repo/stable/rhel7/i386/labs-consol-stable.rhel7.noarch.rpm | verbout
#		[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
#	fi

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
#	out "installing labs.consol.de repo"
#	if add_apt_repo https://labs.consol.de/repo/stable/$DISTRIBUTOR_ID \
#					https://labs.consol.de/repo/stable/RPM-GPG-KEY ; then
#		DO_APT_UPDATE=1
#	fi
	out "Running apt update.  This can take awhile..."
	apt update | verbout
fi

# Now install the rest of the packages
PKGSFILE=$TOPDIR/etc/${OS_PKGTYPE}-pkgs.list
newtempfile DEPPKGS
egrep -v '#' $PKGSFILE > $DEPPKGS 2>/dev/null
if [[ -s $DEPPKGS ]]; then
	XVAL=0
	section "Checking and installing dependency packages"
	pause 3
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
			out "  installing $pkg"
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
	newtempfile FIREWALLSVCS
	if firewalcmd --list-services > $FIREWALLSVCS 2>&1 ; then
		_reload=0
		for i in http https ; do
			grep -qw $i $FIREWALLSVCS && continue
			out "Adding $i to firewall rules"
			firewall-cmd --permanent --add-service=$i | verbout
			[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
			_reload=1
		done
		if [[ $_reload -eq 1 ]]; then
			out "Reloading firewall"
			firewall-cmd --reload | verbout
			[[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
		fi
	fi
fi

# The /foresight/etc dir will have been created by the packages.
DST=/foresight/etc/omd-build.env
if [[ ! -f $DST ]]; then
	out "Creating $DST ..."
	cp $TOPDIR/etc/omd-build.env $DST || exit 1
else
	out "Possibly updating $DST ..."
	diff_replace $DST $TOPDIR/etc/omd-build.env
fi
chmod 644 $DST || exit 1

#######################################################################
#######################################################################
if [[ $AMIMODE -eq 1 ]]; then
	out "Finished with basic configuration.  You will need to run this
script again when a new AMI has been provisioned in order to do 
host-specific setup."
	exit 0
fi
#######################################################################
#######################################################################
# Do the host-specific updates.

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
	sed -i -e "/;date.timezone/a date.timezone = \"$TIMEZONE\"" $DST || exit 1
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
				pause "then press ENTER to continue"
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
		exit 1
	else
		if ! grep -q "SSLCertificateFile $SSLCRTFILE" $SSLCONFFILE || \
			! grep -q "SSLCertificateKeyFile $SSLKEYFILE" $SSLCONFFILE ; then
			out "Setting global SSL cert to wildcard cert in $SSLCONFFILE"
			backup_file $SSLCONFFILE
			sed -E -i -e "s,^([[:blank:]]*)SSLCertificateFile[[:blank:]].*,\\1SSLCertificateFile $SSLCRTFILE," \
				-e "s,^([[:blank:]]*)SSLCertificateKeyFile[[:blank:]].*,\\1SSLCertificateKeyFile $SSLKEYFILE," \
				$SSLCONFFILE || exit 1
		else
			out "Apache SSL config already using FSA cert."
		fi
	fi
fi

section "Checking the omd-config-common repo."
DST=/root/omd-config-common
if [[ -d $DST/.git ]]; then
	out "  omd-config-common repo exists"
else
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
EOF
	if [[ -n "$BRANCH" ]]; then
		cat >> $CLONESCRIPT <<EOF
git checkout $BRANCH
git pull
EOF
	fi
	/bin/bash $CLONESCRIPT || exit 1
	out "  running omd-config-common-initialize"
	/foresight/sbin/omd-config-common-initialize || exit 1
	out "  running omd-config-run-deploy"
	/foresight/sbin/omd-config-run-deploy --repo omd-config-common || exit 1
	out "  running omd-safe-deploy-ncfg.sh"
	/foresight/sbin/omd-safe-deploy-ncfg.sh \
		--no-omd-site --no-reload \
		/foresight/repo-deploy/omd-config-common/common.d \
		/foresight/etc/naemon/conf.d/common.d || exit 1
fi
section "Finished with prep."
out "The log file is $LOGFILE"
if [[ -n "$SITE_NAME" ]]; then
	section "Running new-site script for the $SITE_NAME site."
	pause 5
	ARGS=(-s $SITE_NAME --verbose )
	[[ -n "$SITE_BRANCH" ]] && ARGS+=(--branch $SITE_BRANCH)
	$TOPDIR/bin/new-site.sh "${ARGS[@]}" || exit 1
else
	out "To create a new site, you can run:"
	out ""
	out "    $TOPDIR/bin/new-site.sh {sitename}"
fi
