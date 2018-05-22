#!/bin/bash
##
# Trifacta Inc. Confidential
#
# Copyright 2018 Trifacta Inc.
# All Rights Reserved.
#
# Any use of this material is subject to the Trifacta Inc., Source License located
# in the file 'SOURCE_LICENSE.txt' which is part of this package.  All rights to
# this material and any derivative works thereof are reserved by Trifacta Inc.
#


# Name of this script
SCRIPT_NAME=`basename "$0"`
# Location of this script
SCRIPT_DIR=`dirname $(readlink -f "$0")`

# Making text bold and colorful for easier reading
bold=$(tput bold)
normal=$(tput sgr0)
red='\e[91m'
green='\e[92m'
yellow='\e[33m'

usage()
{
   cat <<EOF

NAME
    ${SCRIPT_NAME}

SYNOPSIS
    Trifacta restore from backup script for configs, job logs & database content

REQUIREMENTS
	- Script must be run as root
	- Trifacta must not be running

OPTIONS:
   -r                                   Path to directory containing contents of backup tarball
   -h                                   Show this message
   -y                                   Don't prompt for confirmation after checks are completed

RECOMMENDED USAGE
	$ ${bold}${SCRIPT_NAME}${normal}

EOF
}

# Set default value for TRIFACTA_HOME TRIFACTA_CONF variable as it would be in most scenarios
export TRIFACTA_HOME="/opt/trifacta"
export TRIFACTA_CONF="${TRIFACTA_HOME}/conf"

# Locations to get job logs
export TRIFACTA_LOGS_JOBS="${TRIFACTA_HOME}/logs/jobs"
export TRIFACTA_LOGS_JOBGROUPS="${TRIFACTA_HOME}/logs/jobgroups"

# Script we will use to pull configs from trifacta-conf.json file
LOOKUP_TRICONF_SCRIPT="${TRIFACTA_HOME}/bin/lookup-triconf.py"

# Things we need in the ${RESTORE_PATH}
RESTORE_CONF_DIR="file-backups/conf"
RESTORE_LOGS_DIR="file-backups/logs"
RESTORE_DB_DIR="db-backups"
RESTORE_DB_WEBAPP="${RESTORE_DB_DIR}/postgres-backup-trifacta.sql"
RESTORE_DB_SS="${RESTORE_DB_DIR}/postgres-backup-trifactaschedulingservice.sql"
RESTORE_DB_TBTS="${RESTORE_DB_DIR}/postgres-backup-trifactatimebasedtriggerservice.sql"

# Where we'll put the db restore logs
DB_RESTORE_LOGS="${TRIFACTA_HOME}/logs/restore-logs"
mkdir -p ${DB_RESTORE_LOGS}

# working directory
DATETIMESTAMP=`date +'%Y%m%d-%H%M%S'`
TRIFACTA_BACKUP_BASE_DIR="/opt/trifacta-backups"
BACKUP_DIR_NAME="trifacta-backup-${DATETIMESTAMP}"
WORK_DIR="${TRIFACTA_BACKUP_BASE_DIR}/${BACKUP_DIR_NAME}"
BACKUP_ARCHIVE_NAME="${BACKUP_DIR_NAME}.tgz"

# Location of Postgres binaries
export PG_BIN_DIR_CENTOS="/usr/pgsql-9.3/bin"
export PG_BIN_DIR_UBUNTU="/usr/lib/postgresql/9.3/bin"

# Trifacta owner & group
TRIFACTA_OWNER="trifacta"
TRIFACTA_GROUP="trifacta"

DISKSPACE_NEEDED=5000000
PROMPT_FOR_CONFIRMATION=true

declare -A SYSTEMINFO

function check_message_status()
{
	check_done="$1"
	check_status="$2"
	check_message="$3"

	echo "..."
	echo -e "Check : ${check_done} -> ${bold}${check_status}${normal} ( ${check_message} )"
}

function check_pass()
{
	check_done="$1"

	if [ -n "$2" ]; then
		check_message="$2"
	else
		check_message=""
	fi

	check_message_status "${check_done}" "${green}pass" "${check_message}"
}

function check_fail()
{
	check_done="$1"

	if [ -n "$2" ]; then
		check_message="$2"
	else
		check_message=""
	fi

	check_message_status "${check_done}" "${red}fail" "${check_message}"

	exit 1
}

function get_diskspace
{
	diskspace_available=`df -k /opt | awk '{print $4}' | grep -v Avail`
	echo ${diskspace_available}
}

function get_installed_trifacta_version_number
{
	if [ -e "${TRIFACTA_HOME}/build_number.txt" ]; then
		version_number=`cat ${TRIFACTA_HOME}/build_number.txt`
	else
		version_number="NO_TRIFACTA_FOUND"
	fi
	echo ${version_number}
}

function set_platform_specific_postgres_values
{
    if [ $(grep -ioc ubuntu /etc/issue) -gt 0 ]; then
        export PG_BIN_DIR=${PG_BIN_DIR_UBUNTU}
    elif [ -e /etc/redhat-release ]; then
        export PG_BIN_DIR=${PG_BIN_DIR_CENTOS}
    else
        echo "Unsupported platform. Needs Ubuntu or Centos/Redhat"
        exit 1
    fi

	export PSQL="${PG_BIN_DIR}/psql"
}

# Collects some basic system setup/tools info we need
function collect_system_info
{
	if [[ $(id -u) -ne 0 ]] ; then
		SYSTEMINFO[user_is_root]="false"
	else
		SYSTEMINFO[user_is_root]="true"
	fi

	eval tar --version >& /dev/null
	if [ $? -eq 0 ]; then
		SYSTEMINFO[has_tar]="true"
	else
		SYSTEMINFO[has_tar]="false"
	fi

	eval service trifacta status >& /dev/null
	if [ $? -eq 3 ]; then
		SYSTEMINFO[trifacta_running_status]="false"
	else
		SYSTEMINFO[trifacta_running_status]="true"
	fi

	if [ -e ${LOOKUP_TRICONF_SCRIPT} ]; then
		SYSTEMINFO[trifacta_config_lookup_script_found]="true"	
	else
		SYSTEMINFO[trifacta_config_lookup_script_found]="false"
	fi

	if [ -d ${RESTORE_PATH} ]; then
		SYSTEMINFO[restore_path_is_valid]="true"	
	else
		SYSTEMINFO[restore_path_is_valid]="false"
	fi

	if [ -e ${PSQL} ]; then
		SYSTEMINFO[has_psql]="true"
	else
		SYSTEMINFO[has_psql]="false"
	fi

	SYSTEMINFO[diskspace_available]=$(get_diskspace)
	SYSTEMINFO[trifacta_version_number]=$(get_installed_trifacta_version_number)
}

function print_system_info
{
    for key in "${!SYSTEMINFO[@]}"; do
            echo "${key} : ${SYSTEMINFO[${key}]}"
    done
}

# Verified that the requirements are met
function check_system_prerequisites
{
	# Check if root
	if [[ ${SYSTEMINFO[user_is_root]} == "false" ]]; then
		check_fail "check_user_is_root" "Please run as root"
	else
		check_pass "check_user_is_root" "User is root"
	fi

	# Check if tar available
	if [[ ${SYSTEMINFO[has_tar]} == "true" ]]; then
		check_pass "check_has_tar" "tar was found"
	else
		check_fail "check_has_tar" "tar was not found"
	fi

	# Diskspace check
	if [ "${SYSTEMINFO[diskspace_available]}" -le "${DISKSPACE_NEEDED}" ]; then
	    check_fail "check_diskspace_available" "Diskspace available, ${SYSTEMINFO[diskspace_available]} is less than required ${DISKSPACE_NEEDED}"
	else
	    check_pass "check_diskspace_available" "Diskspace check passed (${SYSTEMINFO[diskspace_available]} available)"
	fi

	# Check if lookup script is available
	if [[ ${SYSTEMINFO[trifacta_config_lookup_script_found]} == "true" ]]; then
		check_pass "check_trifacta_config_lookup_script_found" "trifacta config lookup script was found"
	else
		check_fail "check_trifacta_config_lookup_script_found" "trifacta config lookup script was not found"
	fi

	# Check if psql is available
	if [[ ${SYSTEMINFO[has_psql]} == "true" ]]; then
		check_pass "check_psql_found" "psql binary was found"
	else
		check_fail "check_psql_found" "psql binary was not found"
	fi

	# Check if Trifacta is Running
	if [[ ${SYSTEMINFO[trifacta_running_status]} == "false" ]]; then
		check_pass "check_trifacta_running_status" "Trifacta is not running"
	else
		check_fail "check_trifacta_running_status" "Trifacta is still running, please stop it and re-run script"
	fi

	# Check if restore path available
	if [[ ${SYSTEMINFO[restore_path_is_valid]} == "true" ]]; then
		check_pass "restore_path_is_valid" "restore path found : ${RESTORE_PATH}"
	else
		check_fail  "restore_path_is_valid" "restore path not found : ${RESTORE_PATH}"
	fi	
}

# Identify the backup we're working with so we know the proper folder/file locations
#
# Older backup scripts (5.0.0 and older) had a flatter structure like so
# base-dir/conf-backup
# base-dir/logs-backup/jobs
# base-dir/logs-backup/jobgroups
# base-dir/postgres-backup-*.sql
#
# Newer backup scripts (5.0.1 and newer) have a more hierarchical structure
# base-dir/file-backups/conf
# base-dir/file-backups/logs/jobs
# base-dir/file-backups/logs/jobgroups
# base-dir/db-backups/postgres-backup-*.sql
function set_appropriate_restore_path_variables
{
	# Check for new style of backup folder format
	if [ -d ${RESTORE_PATH}/db-backups ] && [ -d ${RESTORE_PATH}/file-backups ]; then
		echo ""
		echo "Identified a backup from 5.0.x or later"
		echo ""
		export RESTORE_CONF_DIR="file-backups/conf"
		export RESTORE_LOGS_DIR="file-backups/logs"
		export RESTORE_DB_DIR="db-backups"
		export RESTORE_DB_WEBAPP="${RESTORE_DB_DIR}/postgres-backup-trifacta.sql"
		export RESTORE_DB_SS="${RESTORE_DB_DIR}/postgres-backup-trifactaschedulingservice.sql"
		export RESTORE_DB_TBTS="${RESTORE_DB_DIR}/postgres-backup-trifactatimebasedtriggerservice.sql"

	# Check for older (5.0.0 and older) flatter style of backup folder format
	elif [ -d ${RESTORE_PATH}/conf-backup ] && [ -d ${RESTORE_PATH}/logs-backup ]; then
		echo ""
		echo "Identified a backup from 5.0.0 or older"
		echo ""
		export RESTORE_CONF_DIR="conf-backup"
		export RESTORE_LOGS_DIR="logs-backup"
		export RESTORE_DB_WEBAPP="postgres-backup-trifacta.sql"
		export RESTORE_DB_SS="postgres-backup-trifactaschedulingservice.sql"
		export RESTORE_DB_TBTS="postgres-backup-trifactatimebasedtriggerservice.sql"
	else
		echo ""
		echo "Unrecognized backup folder structure at ${RESTORE_PATH}. Exiting."
		echo ""
		exit 1
	fi
}


function verify_contents_of_restore_path
{
	if [ -d "${RESTORE_PATH}/${RESTORE_CONF_DIR}" ]; then
		check_pass "restore_path_conf_is_valid" "restore path conf found : ${RESTORE_PATH}/${RESTORE_CONF_DIR}"
	else
		check_fail  "restore_path_conf_is_valid" "restore path conf not found : ${RESTORE_PATH}/${RESTORE_CONF_DIR}"
	fi

	if [ -d "${RESTORE_PATH}/${RESTORE_LOGS_DIR}" ]; then
		check_pass "restore_path_logs_is_valid" "restore path logs found : ${RESTORE_PATH}/${RESTORE_LOGS_DIR}"
	else
		check_fail  "restore_path_logs_is_valid" "restore path logs not found : ${RESTORE_PATH}/${RESTORE_LOGS_DIR}"
	fi

	if [ -f "${RESTORE_PATH}/${RESTORE_DB_WEBAPP}" ]; then
		check_pass "restore_db_webapp_is_valid" "restore db webapp found : ${RESTORE_PATH}/${RESTORE_DB_WEBAPP}"
	else
		check_fail  "restore_db_webapp_is_valid" "restore db webapp not found : ${RESTORE_PATH}/${RESTORE_DB_WEBAPP}"
	fi	

	if [ -f "${RESTORE_PATH}/${RESTORE_DB_SS}" ]; then
		check_pass "restore_db_ss_is_valid" "restore db ss found : ${RESTORE_PATH}/${RESTORE_DB_SS}"
	else
		check_fail  "restore_db_ss_is_valid" "restore db ss not found : ${RESTORE_PATH}/${RESTORE_DB_SS}"
	fi	

	if [ -f "${RESTORE_PATH}/${RESTORE_DB_TBTS}" ]; then
		check_pass "restore_db_tbts_is_valid" "restore db tbts found : ${RESTORE_PATH}/${RESTORE_DB_TBTS}"
	else
		check_fail  "restore_db_tbts_is_valid" "restore db tbts not found : ${RESTORE_PATH}/${RESTORE_DB_TBTS}"
	fi	
}

function get_confirmation
{

	echo " "
	echo "Going to restore from contents of : ${bold}${RESTORE_PATH}/${normal}"


	# Unless user chose to not be prompted for confirmation, get their consent before proceeding
	if [[ ${PROMPT_FOR_CONFIRMATION} == "true" ]]; then
		while true
		do
			echo " "
			echo "All prerequisite checks are complete. The restore will remove existing content (configs, database, logs) from the installation at ${TRIFACTA_HOME} "
			echo -n -e "${yellow}Would you like to continue? ${normal}(${bold}y${normal}es / ${bold}n${normal}o) : "
			read continue_response
			echo " "

		  # (2) handle the input we were given
		  case $continue_response in
		   [yY]* ) echo "Proceeding"
		           break;;

		   [nN]* ) echo "Quiting"
				   exit 1;;

		   * )     echo "Not a valid response. Enter yes or no";;
		  esac
		done
	fi
}

function get_build_number
{
	version_string="$1"

	build_number=`echo ${version_string} | sed "s/[0-9]\..*-//"`
	echo ${build_number}
}

function restore_configs
{
	cp -R ${RESTORE_PATH}/${RESTORE_CONF_DIR}/.key ${TRIFACTA_HOME}/conf/
	copy_status_key=$?
	cp ${RESTORE_PATH}/${RESTORE_CONF_DIR}/.customtokenfile ${TRIFACTA_HOME}/conf/
	copy_status_customtoken=$?
	cp ${RESTORE_PATH}/${RESTORE_CONF_DIR}/trifacta-conf.json ${TRIFACTA_HOME}/conf/
	copy_status_trifacta_conf=$?

	if [ ${copy_status_key} -eq 0 ] && [ ${copy_status_customtoken} -eq 0 ] && [ ${copy_status_trifacta_conf} -eq 0 ]; then
		check_pass "check_restore_configs" "Configs restore successful : from ${RESTORE_PATH}/${RESTORE_CONF_DIR} to ${TRIFACTA_CONF}"
	else
		check_fail "check_restore_configs" "Configs restore failed"
	fi
}

function restore_job_logs
{
	echo "Remove existing contents of job logs directory before copying over Restored content"
	rm -rf ${TRIFACTA_LOGS_JOBS}
	mkdir -p ${TRIFACTA_LOGS_JOBS}

	cp -R ${RESTORE_PATH}/${RESTORE_LOGS_DIR}/jobs/. ${TRIFACTA_LOGS_JOBS}
	if [ $? -eq 0 ]; then
		check_pass "check_restore_job_logs" "Job logs restore successful : from ${RESTORE_PATH}/${RESTORE_LOGS_DIR}/jobs to ${TRIFACTA_LOGS_JOBS}"
	else
		check_fail "check_restore_job_logs" "Job logs restore failed"
	fi
}

function restore_jobgroup_logs
{
	echo "Remove existing contents of jobgroup logs directory before copying over Restored content"
	rm -rf ${TRIFACTA_LOGS_JOBGROUPS}
	mkdir -p ${TRIFACTA_LOGS_JOBGROUPS}

	cp -R ${RESTORE_PATH}/${RESTORE_LOGS_DIR}/jobgroups/. ${TRIFACTA_LOGS_JOBGROUPS}
	if [ $? -eq 0 ]; then
		check_pass "check_restore_job_logs" "Jobgroup logs restore successful : from ${RESTORE_PATH}/${RESTORE_LOGS_DIR}/jobgroups to ${TRIFACTA_LOGS_JOBGROUPS}"
	else
		check_fail "check_restore_job_logs" "Jobgroup logs restore failed"
	fi
}

function restore_dbs
{
	webapp_db_name=$(${LOOKUP_TRICONF_SCRIPT} "webapp.db.name")
	webapp_db_username=$(${LOOKUP_TRICONF_SCRIPT} "webapp.db.username")

    scheduling_service_db_name=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.name")
    scheduling_service_db_username=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.username")

    time_based_trigger_service_db_name=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.name")
    time_based_trigger_service_db_username=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.username")

    batch_job_runner_db_name=$(${LOOKUP_TRICONF_SCRIPT} "batch-job-runner.db.name")
    batch_job_runner_db_username=$(${LOOKUP_TRICONF_SCRIPT} "batch-job-runner.db.username")

	echo " "
    echo "Delete existing databases & roles : "
	echo " "

	# Ensure the db/role names aren't empty strings, then run the psql commands to delete them
    [[ ! -z $webapp_db_name ]] && su -l postgres -c "${PSQL} --dbname=postgres --command='DROP database \"${webapp_db_name}\";'"
    [[ ! -z $scheduling_service_db_name ]] && su -l postgres -c "${PSQL} --dbname=postgres --command='DROP database \"${scheduling_service_db_name}\";'"
    [[ ! -z $time_based_trigger_service_db_name ]] && su -l postgres -c "${PSQL} --dbname=postgres --command='DROP database \"${time_based_trigger_service_db_name}\";'"
    [[ ! -z $batch_job_runner_db_name ]] && su -l postgres -c "${PSQL} --dbname=postgres --command='DROP database \"${batch_job_runner_db_name}\";'"

    [[ ! -z $webapp_db_username ]] && su -l postgres -c "${PSQL} --dbname=postgres --command='DROP role \"${webapp_db_username}\";'"
    [[ ! -z $scheduling_service_db_username ]] && su -l postgres -c "${PSQL} --dbname=postgres --command='DROP role \"${scheduling_service_db_username}\";'"
    [[ ! -z $time_based_trigger_service_db_username ]] && su -l postgres -c "${PSQL} --dbname=postgres --command='DROP role \"${time_based_trigger_service_db_username}\";'"
    [[ ! -z $batch_job_runner_db_username ]] && su -l postgres -c "${PSQL} --dbname=postgres --command='DROP role \"${batch_job_runner_db_username}\";'"

	echo " "
    echo "Recreate roles & databased based on restored config values by running ${TRIFACTA_HOME}/bin/setup-utils/db/trifacta-create-postgres-roles-dbs.sh"
	echo " "

    ${TRIFACTA_HOME}/bin/setup-utils/db/trifacta-create-postgres-roles-dbs.sh

	echo " "
    echo "Restore webapp db, ${webapp_db_name}, from dump file, ${RESTORE_PATH}/${RESTORE_DB_WEBAPP}"
    echo "Output sent to ${DB_RESTORE_LOGS}/restore-db-${webapp_db_name}.log "
	echo " "
    rm -f ${DB_RESTORE_LOGS}/restore-db-${webapp_db_name}.log
	su -l postgres -c "${PSQL} --dbname=${webapp_db_name}" < ${RESTORE_PATH}/${RESTORE_DB_WEBAPP} > ${DB_RESTORE_LOGS}/restore-db-${webapp_db_name}.log

	echo " "
    echo "Restore time_based_trigger_service_db_name db, ${time_based_trigger_service_db_name}, from dump file, ${RESTORE_PATH}/${RESTORE_DB_TBTS}"
    echo "Output sent to ${DB_RESTORE_LOGS}/restore-db-${time_based_trigger_service_db_name}.log "
	echo " "
	rm -f ${DB_RESTORE_LOGS}/restore-db-${time_based_trigger_service_db_name}.log
	su -l postgres -c "${PSQL} --dbname=${time_based_trigger_service_db_name}" < ${RESTORE_PATH}/${RESTORE_DB_TBTS} > ${DB_RESTORE_LOGS}/restore-db-${time_based_trigger_service_db_name}.log

	echo " "
    echo "Restore scheduling-service db, ${scheduling_service_db_name}, from dump file, ${RESTORE_PATH}/${RESTORE_DB_SS}"
    echo "Output sent to ${DB_RESTORE_LOGS}/restore-db-${scheduling_service_db_name}.log "
	echo " "
	rm -f ${DB_RESTORE_LOGS}/restore-db-${scheduling_service_db_name}.log
	su -l postgres -c "${PSQL} --dbname=${scheduling_service_db_name}" < ${RESTORE_PATH}/${RESTORE_DB_SS} > ${DB_RESTORE_LOGS}/restore-db-${scheduling_service_db_name}.log

}

function final_fixes
{
	# Make sure trifacta:trifacta owns everything in /opt/trifacta
	chown -R ${TRIFACTA_OWNER}:${TRIFACTA_GROUP} ${TRIFACTA_HOME}
	if [ $? -eq 0 ]; then
		check_pass "check_ownership_restore" "File ownership successful"
	else
		check_fail "check_ownership_restore" "File ownership failed"
	fi
}

while getopts "hr:y" OPTION
do
	case $OPTION in
		h)
			usage
			exit 1
			;;
		r)
			RESTORE_PATH=$OPTARG
			;;
		y)
			PROMPT_FOR_CONFIRMATION="false"
			;;
		*)
			echo "Unknown option $OPTION"
			usage
			exit 1
			;;
	esac
done

if [ ! -z ${RESTORE_PATH} ]; then
	echo "Going to use RESTORE_PATH=${RESTORE_PATH}"
else
	usage
	exit 1
fi

echo " "
echo "${bold}======================== Collecting System Info ========================${normal}"
set_platform_specific_postgres_values
collect_system_info
print_system_info
echo " "
echo "${bold}======================== Performing Requirement Checks ========================${normal}"
check_system_prerequisites
echo " "
echo "${bold}======================== Performing Restore Folder Content Checks ========================${normal}"
set_appropriate_restore_path_variables
verify_contents_of_restore_path
get_confirmation
echo " "
echo "${bold}======================== Restore configs ========================${normal}"
restore_configs
echo " "
echo "${bold}======================== Restore job logs ========================${normal}"
restore_job_logs
echo " "
echo "${bold}======================== Restore jobgroup logs ========================${normal}"
restore_jobgroup_logs
echo " "
echo "${bold}======================== Restore database ========================${normal}"
restore_dbs
echo " "
echo "${bold}======================== Final fixes ========================${normal}"
final_fixes
echo " "
echo "${bold}======================== Restore completed ========================${normal}"
