#!/bin/bash
# the stupid build tool.
# see: https://zxq.co/f4/tool

# provides documentation for the sub-commands.
DOCUMENTATION=(
	'help [COMMAND]'
	"returns help for the specified command, or for all commands if none is specified.
		$ ./tool help
		$ ./tool help build"

	'build [FLAGS]'
	"build project
		$ ./tool build
		$ ./tool build -o fofo"

	'run [FLAGS]'
	"compile to ./cutcsv and run
		$ ./tool run
		$ ./tool run -v"
)

# absolute path to script
tool_root="$(dirname "$(realpath "$0")")"

tool() {
	cmd="$1"
	shift
	case "$cmd" in
		build)
			# set up flags
			cflags="-std=c89 -pedantic"
			cflags="$cflags -O3"
			cflags="$cflags -fno-strict-aliasing"
			cflags="$cflags -Wno-variadic-macros -Wno-long-long -Wall"
			cflags="$cflags -ffunction-sections -fdata-sections"
			cflags="$cflags -g0 -fno-unwind-tables -s"
			cflags="$cflags -fno-asynchronous-unwind-tables"

			ldflags="-lm"

			cflags="$cflags $CFLAGS"
			ldflags="$ldflags $LDFLAGS"

			cc="$CC"

			if [ $(uname) = "Darwin" ]; then
				cc=${cc:-clang}
			else
				cc=${cc:-gcc}
			fi

			uname -a > flags.log
			echo $cc >> flags.log
			echo $cflags >> flags.log
			echo $ldflags >> flags.log
			$cc --version >> flags.log
			$cc -dumpmachine >> flags.log

			export cflags="$cflags"
			export ldflags="$ldflags"
			export cc="$cc"

			# build
			$cc $cflags -o cutcsv "$@" cutcsv.c $ldflags
			;;

		# ----------------------------------------------------------------------
		run)
			tool build && ./cutcsv "$@"
			;;

		# ----------------------------------------------------------------------
		*)
			BOLD='\033[1m'
			NC='\033[0m'
			# command called with no args
			if [ "$cmd" == 'help' ]; then
				printf "${BOLD}tool${NC} - the stupid build tool\n"
				echo
			fi
			printf "Usage: ${BOLD}./tool <SUBCOMMAND> [<ARGUMENT>...]${NC}\n"
			if [ -z "$1" ]; then
				echo 'Subcommands:'
			fi

			idx=0
			found=false
			while [ "${DOCUMENTATION[idx]}" ]; do
				stringarr=(${DOCUMENTATION[idx]})
				# if $1 is set and this is the wrong command, then skip it
				if [ -n "$1" -a "${stringarr[0]}" != "$1" ]; then
					((idx+=2))
					continue
				fi

				found=true

				echo
				printf "\t${BOLD}${DOCUMENTATION[idx]}${NC}\n"
				printf "\t\t${DOCUMENTATION[idx+1]}\n"

				((idx+=2))
			done
			if [ "$found" = false ]; then
				echo
				echo "The specified subcommand $1 could not be found."
			fi
			;;
	esac
}

tool "$@"
