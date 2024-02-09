#!/bin/bash

set -e -x -o pipefail

DUB_ARGS="--compiler $DC -a $ARCH"
# default to run all parts
: ${TESTS:=unittests,vibe-d}

if [[ $TESTS =~ (^|,)unittests(,|$) ]]; then
    dub test $DUB_ARGS
fi

if [[ $TESTS =~ (^|,)vibe-d(,|$) ]]; then
    PATH_ESCAPED=$(echo `pwd` | sed 's_/_\\/_g')
    SED_EXPR='s/"vibe-container": [^,]*(,?)/"vibe-container": \{"path": "'$PATH_ESCAPED'"\}\1/g'

    git clone https://github.com/vibe-d/vibe-core.git --depth 1
    cd vibe-core
    dub upgrade -s
    sed -i -E "$SED_EXPR" dub.selections.json
    dub test
    cd ..

    git clone https://github.com/vibe-d/vibe.d.git --depth 1
    cd vibe.d
    dub upgrade -s
    for i in `find | grep dub.selections.json`; do
        sed -i -E "$SED_EXPR" $i
    done
    dub test :data $DUB_ARGS
    dub test :mongodb $DUB_ARGS
    dub test :redis $DUB_ARGS
    dub test :web $DUB_ARGS
    dub test :utils $DUB_ARGS
    dub test :http $DUB_ARGS
    dub test :mail $DUB_ARGS
    dub test :stream $DUB_ARGS
    dub test :crypto $DUB_ARGS
    dub test :tls $DUB_ARGS
    dub test :textfilter $DUB_ARGS
    dub test :inet $DUB_ARGS
    cd ..
fi
