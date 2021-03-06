#!/bin/bash
APPDIR="."

function pre_clean {
	rm -f $APPDIR/include/commit_ver.hrl
}

function pre_compile {
	if [ ! -d $APPDIR/ebin ]; then
		mkdir $APPDIR/ebin
	fi

	if [ ! -d $APPDIR/priv ]; then
		mkdir $APPDIR/priv
	fi

	if [ ! -d $APPDIR/include ]; then
		mkdir $APPDIR/include
	fi

	# record what commit/version the rep is at
	COMMIT=""
	if [ -d ".git" ]
	then
		COMMIT=`git log -1 --pretty=format:%H`
	fi
	if [ -e "$APPDIR/include/commit_ver.hrl" ] && [ ! $COMMIT ]
	then
		exit 0
	else
		if [ ! COMMIT ]
		then
			COMMIT="undefined"
		else
			COMMIT="\"$COMMIT\""
		fi
	fi
	echo "%% automatically generated by precompile script.  Editing means this
%% will just be overwritten.

-define(COMMIT, $COMMIT)." > $APPDIR/include/commit_ver.hrl

}

function post_compile {
	cat success_message
}

case $1 in
	"pre_compile")
		pre_compile;;
	"post_compile")
		post_compile;;
	"pre_clean")
		pre_clean;;
esac
