# omd-build

This repo has a couple of scripts for performing the setup of a
monitoring server based on the Lab Consol OMD package using naemon for
the core monitoring system.

Grab the files in this repo:

```bash
wget -O - https://github.com/foresightautomation/omd-build/archive/master.tar.gz | tar xvzf -
```

```bash
cd omd-build-master
./bin/00-prep.sh
```

This will download and install the needed repos and packages.

```bash
./bin/new-site.sh [-s sitename]
```

Creates a new site, enables NCPA, LiveStatus, and NRDP, and creates an ssh
key that can be used to deploy the omd-config-common repo.
