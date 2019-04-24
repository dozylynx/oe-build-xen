#!/bin/bash
#
# Copyright (c) 2019 BAE Systems
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

OE_RELEASE="thud"
SPEEDUP="--single-branch"
REPOHOST_YOCTO="git.yoctoproject.org"
REPOHOST_OE="git.openembedded.org"
REPOHOST_XEN="xenbits.xen.org"

#---
# Validate input

if [ $# != 2 ] ; then
    echo >&2 "Error: $0 <target arch> <xen branch>"
    exit 1
fi

case $1 in
    "x86-64") MACHINE="genericx86-64";;
    "arm64")  MACHINE="qemuarm64";;
    "arm32")  MACHINE="qemuarm";;
    *) echo >&2 "Error: invalid arch, requires one of: [x86-64 | arm64 | arm32]" ; exit 2 ;;
esac

XEN_BRANCH="$2"

#---
# Determine Xen version information

# Obtain the git reference for the current tip of the branch to be built:
XEN_SRCREV=$(git ls-remote --heads "git://${REPOHOST_XEN}/xen.git" "refs/heads/${XEN_BRANCH}" | cut -f1 -d'	')

if [ -z "${XEN_SRCREV}" ] ; then
    echo >&2 "Error: failed to find specified branch \"${XEN_BRANCH}\" in the Xen repository."
    echo >&2 "Available branches are:"
    git ls-remote --heads git://${REPOHOST_XEN}/xen.git | sed -ne 's/^.*refs\/heads\/\([^/]*\)$/\1/p' >&2
    exit 3
fi

XEN_REL=$(echo "${XEN_BRANCH}" | sed -ne 's/^.*-//p')
if [ -z "${XEN_REL}" ] ; then
    # Since the branch name didn't contain version information, determine the next major release:
    LAST_STABLE_RELEASE=$(git ls-remote --heads git://${REPOHOST_XEN}/xen.git | cut -f2 -d'	' | sort -V | tail -1 | sed 's/^.*-//')
    MAJOR_VERSION=$(echo $LAST_STABLE_RELEASE | cut -f1 -d.)
    MINOR_VERSION=$(echo $LAST_STABLE_RELEASE | cut -f2 -d.)
    NEXT_MINOR_VERSION=$(( $(echo "${MINOR_VERSION}" | cut -f2 -d.) + 1 ))
    XEN_REL="${MAJOR_VERSION}.${NEXT_MINOR_VERSION}"
fi

#---
# Obtain general build environment
git clone --branch "${OE_RELEASE}" "${SPEEDUP}" "git://${REPOHOST_YOCTO}/poky"
cd poky
git clone --branch "${OE_RELEASE}" "${SPEEDUP}" "git://${REPOHOST_YOCTO}/meta-virtualization"
git clone --branch "${OE_RELEASE}" "${SPEEDUP}" "git://${REPOHOST_OE}/meta-openembedded"

# Initialize state and conf directory
source ./oe-init-build-env build

#---
# bblayers.conf: add the necessary layers
LAYER_ROOT="$(sed -ne 's/^  \(\/.*\/\)meta \\$/\1/p' <conf/bblayers.conf)"
ESCAPED_LAYER_ROOT="$(echo $LAYER_ROOT | sed 's/\//\\\//g')"
for LAYER in meta-virtualization \
             meta-openembedded/meta-python \
             meta-openembedded/meta-networking \
             meta-openembedded/meta-filesystems \
             meta-openembedded/meta-oe
do
    ESCAPED_LAYER="$(echo "${LAYER}" | sed 's/\//\\\//g')"
    # Match on the meta-yocto-bsp layer line for the insertion point
    sed "/^  ${ESCAPED_LAYER_ROOT}meta-yocto-bsp \\\\$/a\\ \\ ${ESCAPED_LAYER_ROOT}${ESCAPED_LAYER} \\\\" \
        -i conf/bblayers.conf
done

#---
# Since we're specifying the exact version of Xen that is to be built,
# write a custom Xen recipe to do so.

XEN_RECIPE_DIR="../meta-virtualization/recipes-extended/xen"
rm -rf "${XEN_RECIPE_DIR}"
mkdir "${XEN_RECIPE_DIR}"
cd "${XEN_RECIPE_DIR}"

cat >xen_git.bb <<EOF
require xen.inc

SRCREV ?= "${XEN_SRCREV}"

XEN_REL = "${XEN_REL}"
XEN_BRANCH = "${XEN_BRANCH}"
FLASK_POLICY_FILE = "xenpolicy-\${XEN_REL}-unstable"

PV = "\${XEN_REL}+git\${SRCPV}"

S = "\${WORKDIR}/git"

SRC_URI = "git://${REPOHOST_XEN}/xen.git;branch=\${XEN_BRANCH}"
EOF

# Obtain the dependent Xen recipes files from the tip of master:
# they are maintained as backwards compatible.
git checkout master -- xen.inc xen-arch.inc

cd -

#---
# local.conf: add the necessary variable definitions

[ -f "conf/local.conf.template" ] || mv conf/local.conf conf/local.conf.template
cat conf/local.conf.template - >conf/local.conf <<EOF

MACHINE = "${MACHINE}"
DISTRO_FEATURES_append = " virtualization xen"

PREFERRED_VERSION_xen = "${XEN_REL_VALUE}+git%"

# Enable parallelism in the build. These values should be tuned
# to appropriate values for the build host.
BB_NUMBER_THREADS ?= "8"
PARALLEL_MAKE ?= "-j 4"
EOF

#---
# TODO: enable shared sstate cache and the download binary mirror here

#---
# Run the build

bitbake xen && bitbake xen-image-minimal && bitbake xen-guest-image-minimal
