#!/bin/bash
#
#Copyright (c) 2016 Jelle Derksen jelle@epsilix.nl
#
#Permission is hereby granted, free of charge, to any person obtaining a copy
#of this software and associated documentation files (the "Software"), to deal
#in the Software without restriction, including without limitation the rights
#to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#copies of the Software, and to permit persons to whom the Software is
#furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in
#all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#SOFTWARE.
#
#qualys_ssl_scan.sh

#Variables
qualys_api_addr='https://api.ssllabs.com/api/v2'
max_retry='5'
dn='/dev/null'
publish_results='no'
me="${0##*/}"
fqdn_regex='^(([a-zA-Z]|[a-zA-Z][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z]|[A-Za-z][A-Za-z0-9\-]*[A-Za-z0-9])$'
max_errors='5'

#functions
usage() {
	echo "usage: ${me} [ -h ] [ -H ] [ fqdn ] [ -e ] [ error grade ] [ -w ] [ warning grade ]
	-H: Get Qualys ssl scan grade
	-w: Nagios warning level grade lexicographically after given
	-e: Nagios critical level grade lexicographically after given
	-h: show usage" >&2
}

get_pars() {
	if [[ -z ${1} ]]; then
		usage
		exit 2
	else
		while getopts c:H:hw: n
		do
			case "${n}" in
			H)
				check_host+=("$OPTARG")
				;;
			h)
				usage
				exit 1
				;;
			c)
				crit_level="${OPTARG}"
				;;
			w)
				warn_level="${OPTARG}"
				;;
			*)
				usage
				exit 1
			esac
		done
	fi
}

check_fqdn() {
        if [[ ${1} =~ ${fqdn_regex} ]]; then
                return 0
        else
                echo "${me}: ${1} not a valid fqdn"
                return 1
        fi
}

check_http_status() {
	if [[ ${1} == 200 ]]; then
		return 0
	elif [[ ${1} == 400 ]]; then
		echo "${me}: invocation error invalid parameters"
		return 1
	elif [[ ${1} == 429 ]]; then
		echo "${me}: client request rate too high or to fast"
		return 2
	elif [[ ${1} == 500 ]]; then
		echo "${me}: internal error"
		return 3
	elif [[ ${1} == 503 ]]; then
		echo "${me}: the service is not available down for maintenance"
		return 4
	elif [[ ${1} == 529 ]]; then
		echo "${me}: the service is overloaded"
		return 5
	else
		echo "${me}: an unknown error has occurred"
		return 6
	fi
}

start_new_ssl_scan() {
	#We start the counter at 1 so we don't confuse the user with
	#an off by one error when setting the variable $max_retry.
	for ((counter=1; counter <= max_retry; counter++)); do
		sleep "$((counter **2))"
		while IFS=',' read http_status scan_status; do
			if ! check_http_status "${http_status}"; then
				return 1
			fi
			if [[ $scan_status =~ DNS|IN_PROGRESS ]]; then
				return 0
			else
				echo "${me}: error starting a new ssl scan"
				return 1
			fi
		done <<<"$(curl -s -w '%{http_code},' "${qualys_api_addr}/analyze?host=${1}&publish=${publish_results}&startNew=on" \
		2> "${dn}" -o >(jq -r '.status' 2> "${dn}" | tr -d '"'))"
	done
}

check_status_ssl_scan() {
	for ((counter=1; counter <= max_retry; counter++)); do
		while IFS=',' read http_status scan_status eta; do
			if ! check_http_status "${http_status}"; then
				return 1
			fi
			if [[ $scan_status =~ DNS|IN_PROGRESS ]]; then
				sleep "$(($eta + 30))"
			elif [[ $scan_status == READY ]]; then
				return 0
			else
				echo "${me}: error checking ssl scan status"
				return 1
			fi
		done <<<"$(curl -s -w '%{http_code},' "${qualys_api_addr}/analyze?host=${1}&publish=${publish_results}" \
		2> "${dn}" -o >(jq -r '[ .status, .endpoints[].eta ] | @csv' 2> "${dn}" | tr -d '"'))"
	done
}

get_ssl_scan_grade() {
	while IFS=',' read http_status host grade; do
		if ! check_http_status "${http_status}"; then
			return 1
		fi
		if [[ -z $host || -z $grade ]]; then
			return 1
		else
			echo "host: $host grade: $grade"
			return 0
		fi
	done<<<"$(curl -s -w '%{http_code},' "${qualys_api_addr}/analyze?host=${1}&publish=${publish_results}" \
	2> "${dn}" -o >(jq -r '[ .host, .endpoints[].grade ] | @csv' 2> "${dn}" | tr -d '"'))"
}

nagios_ssl_scan_plugin() {
	while IFS=',' read http_status host grade; do
		if ! check_http_status "${http_status}"; then
			return 1
		fi
		if [[ ${grade} > ${crit_level} ]]; then
			echo "Critical: ${host} ${grade} after ${crit_level}"
			exit 2
		elif [[ ${grade} > ${warn_level} ]]; then
			echo "Warning: ${host} ${grade} after ${warn_level}"
			exit 1
		else
			echo "OK: ${host} grade ${grade}" 
			exit 0
		fi
	done<<<"$(curl -s -w '%{http_code},' "${qualys_api_addr}/analyze?host=${1}&publish=${publish_results}" \
	2> "${dn}" -o >(jq -r '[ .host, .endpoints[].grade ] | @csv' 2> "${dn}" | tr -d '"'))"
}

main() {
	get_pars "${@}"
	for i in "${check_host[@]}"; do
		if [[ ${error_counter} -ge ${max_errors} ]]; then
			echo "${me}: to many errors cannot continue"
			exit 99
		fi
		if ! check_fqdn "${i}"; then
			echo "${me}: ${i} invalid fqdn"
			((error_counter++))
			continue
		fi
		if ! start_new_ssl_scan "${i}"; then
			echo "${me}: failed to start ssl scan for ${i}"
			((error_counter++))
			continue
		fi
		if ! check_status_ssl_scan "${i}"; then
			echo "${me} failed to check ssl scan status for ${i}"
			((error_counter++))
			continue
		fi
		if [[ $crit_level && $warn_level ]]; then
			if ! nagios_ssl_scan_plugin "${i}"; then
				echo "Unknown: ${me} plugin failed for ${i}"
				exit 3
			fi
		fi
		if ! get_ssl_scan_grade "${i}"; then
			echo "${me} failed to get ssl scan grade for ${i}"
			((error_counter++))
			continue
		fi
	done
	exit 0
}

main "${@}"
