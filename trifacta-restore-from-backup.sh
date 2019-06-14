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

# Where we'll put the db restore logs
DB_RESTORE_LOGS="${TRIFACTA_HOME}/logs/restore-logs"
mkdir -p ${DB_RESTORE_LOGS}


# These variables aren't used yet
# working directory
DATETIMESTAMP=`date +'%Y%m%d-%H%M%S'`
TRIFACTA_BACKUP_BASE_DIR="/opt/trifacta-backups"
BACKUP_DIR_NAME="trifacta-backup-${DATETIMESTAMP}"
WORK_DIR="${TRIFACTA_BACKUP_BASE_DIR}/${BACKUP_DIR_NAME}"
BACKUP_ARCHIVE_NAME="${BACKUP_DIR_NAME}.tgz"

# Location of Postgres binaries
export PG_BIN_DIR_CENTOS="/usr/pgsql-9.6/bin"
export PG_BIN_DIR_UBUNTU="/usr/lib/postgresql/9.6/bin"

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


function set_appropriate_restore_path_variables
{
    # Check for new style of backup folder format
    if [ -d ${RESTORE_PATH}/db-backups ] && [ -d ${RESTORE_PATH}/file-backups ]; then

        RESTORE_CONF_DIR="file-backups/conf"
        RESTORE_LOGS_DIR="file-backups/logs"
        RESTORE_DB_DIR="db-backups"

        artifact_storage_service_db_name=$(${LOOKUP_TRICONF_SCRIPT} "artifact-storage-service.database.name")
        artifact_storage_service_db_username=$(${LOOKUP_TRICONF_SCRIPT} "artifact-storage-service.database.username")
        artifact_storage_service_restore_db_file="${RESTORE_PATH}/${RESTORE_DB_DIR}/postgres-backup-${artifact_storage_service_db_name}.sql"

        batch_job_runner_db_name=$(${LOOKUP_TRICONF_SCRIPT} "batch-job-runner.database.name")
        batch_job_runner_db_username=$(${LOOKUP_TRICONF_SCRIPT} "batch-job-runner.database.username")
        batch_job_runner_restore_db_file="${RESTORE_PATH}/${RESTORE_DB_DIR}/postgres-backup-${batch_job_runner_db_name}.sql"

        configuration_service_db_name=$(${LOOKUP_TRICONF_SCRIPT} "configuration-service.database.name")
        configuration_service_db_username=$(${LOOKUP_TRICONF_SCRIPT} "configuration-service.database.username")
        configuration_service_restore_db_file="${RESTORE_PATH}/${RESTORE_DB_DIR}/postgres-backup-${configuration_service_db_name}.sql"

        scheduling_service_db_name=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.name")
        scheduling_service_db_username=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.username")
        scheduling_service_restore_db_file="${RESTORE_PATH}/${RESTORE_DB_DIR}/postgres-backup-${scheduling_service_db_name}.sql"

        time_based_trigger_service_db_name=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.name")
        time_based_trigger_service_db_username=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.username")
        time_based_trigger_service_restore_db_file="${RESTORE_PATH}/${RESTORE_DB_DIR}/postgres-backup-${time_based_trigger_service_db_name}.sql"

        webapp_db_name=$(${LOOKUP_TRICONF_SCRIPT} "webapp.database.name")
        webapp_db_username=$(${LOOKUP_TRICONF_SCRIPT} "webapp.database.username")
        webapp_restore_db_file="${RESTORE_PATH}/${RESTORE_DB_DIR}/postgres-backup-${webapp_db_name}.sql"
    else
        echo ""
        echo "Unrecognized backup folder structure at ${RESTORE_PATH}. Exiting."
        echo ""
        exit 1
    fi
}


function verify_contents_of_file_restore_path
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
    if [ -f ${RESTORE_PATH}/${RESTORE_CONF_DIR}/.customtokenfile ]; then
        cp ${RESTORE_PATH}/${RESTORE_CONF_DIR}/.customtokenfile ${TRIFACTA_HOME}/conf/
        copy_status_customtoken=$?
    else
        # Assume copy is successful if the file does not exist
        copy_status_customtoken=0
    fi
    cp ${RESTORE_PATH}/${RESTORE_CONF_DIR}/trifacta-conf.json ${TRIFACTA_HOME}/conf/
    copy_status_trifacta_conf=$?

    if [ ${copy_status_key} -eq 0 ] && [ ${copy_status_customtoken} -eq 0 ] && [ ${copy_status_trifacta_conf} -eq 0 ]; then
        check_pass "check_restore_configs" "Configs restore successful : from ${RESTORE_PATH}/${RESTORE_CONF_DIR} to ${TRIFACTA_CONF}"
    else
        check_fail "check_restore_configs" "Configs restore failed"
    fi
}

function run_config_upgrader
{

    echo ""
    echo "------------------"
    echo "Run config upgrader"
    echo "------------------"
    echo ""

    pushd ${TRIFACTA_HOME}/node_modules/triconf/upgrade/

        node bin/upgrade-conf.js

    popd
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

function drop_role_and_database
{
    db_name=$1
    db_username=$2

    [[ ! -z ${db_name} ]] && [[ ! -z ${db_username} ]]

    echo "Drop database ${db_name} and role ${db_username}"

    su -l postgres -c "${PSQL} --dbname=postgres --command='DROP database \"${db_name}\";'"
    su -l postgres -c "${PSQL} --dbname=postgres --command='DROP role \"${db_username}\";'"
}

function delete_and_restore_database_for_service
{
    db_name=$1
    db_username=$2
    db_restore_file=$3

    [[ ! -z ${db_name} ]] && [[ ! -z ${db_username} ]] && [[ ! -z ${db_restore_file} ]]

    echo ""
    echo "------------------"
    echo "Restore ${db_name}"
    echo "------------------"
    echo ""
    if [ -f "${db_restore_file}" ]; then
        echo "Restore file for ${db_name} exists : ${db_restore_file}"
        echo "Dropping database ${db_name}"
        su -l postgres -c "${PSQL} --dbname=postgres --command='DROP database \"${db_name}\";'"
        echo "Creating database ${db_name}"
        su -l postgres -c "${PSQL} --dbname=postgres --command='CREATE DATABASE \"${db_name}\" WITH OWNER \"${db_username}\";'"

        echo " "
        echo "Restore ${db_name} from dump file, ${db_restore_file}"
        echo "Output sent to ${DB_RESTORE_LOGS}/restore-db-${db_name}.log "
        echo " "
        rm -f ${DB_RESTORE_LOGS}/restore-db-${db_name}.log
        su -l postgres -c "${PSQL} --dbname=${db_name}" < ${db_restore_file} > ${DB_RESTORE_LOGS}/restore-db-${db_name}.log
    else
        echo "Restore file for ${db_name} does NOT exist, skipping restore"
    fi
}

function restore_dbs
{


    echo ""
    echo "------------------"
    echo "Drop roles and databases"
    echo "------------------"
    echo ""

    drop_role_and_database ${artifact_storage_service_db_name} ${artifact_storage_service_db_username}
    drop_role_and_database ${batch_job_runner_db_name} ${batch_job_runner_db_username}
    drop_role_and_database ${configuration_service_db_name} ${configuration_service_db_username}
    drop_role_and_database ${scheduling_service_db_name} ${scheduling_service_db_username}
    drop_role_and_database ${time_based_trigger_service_db_name} ${time_based_trigger_service_db_username}
    drop_role_and_database ${webapp_db_name} ${webapp_db_username}

    echo " "
    echo "Ensure all users and databases we need are created by running ${TRIFACTA_HOME}/bin/setup-utils/db/trifacta-create-postgres-roles-dbs.sh"
    echo "Uses values from trifacta-conf.json file"
    echo " "

    ${TRIFACTA_HOME}/bin/setup-utils/db/trifacta-create-postgres-roles-dbs.sh

    echo " "
    echo "Now we can drop & restore the databases"
    echo ""
    delete_and_restore_database_for_service ${artifact_storage_service_db_name} ${artifact_storage_service_db_username} ${artifact_storage_service_restore_db_file}
    delete_and_restore_database_for_service ${batch_job_runner_db_name} ${batch_job_runner_db_username} ${batch_job_runner_restore_db_file}
    delete_and_restore_database_for_service ${configuration_service_db_name} ${configuration_service_db_username} ${configuration_service_restore_db_file}
    delete_and_restore_database_for_service ${scheduling_service_db_name} ${scheduling_service_db_username} ${scheduling_service_restore_db_file}
    delete_and_restore_database_for_service ${time_based_trigger_service_db_name} ${time_based_trigger_service_db_username} ${time_based_trigger_service_restore_db_file}
    delete_and_restore_database_for_service ${webapp_db_name} ${webapp_db_username} ${webapp_restore_db_file}

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
verify_contents_of_file_restore_path
get_confirmation
echo " "
echo "${bold}======================== Restore configs ========================${normal}"
restore_configs
echo " "
echo "${bold}======================== Upgrade configs ========================${normal}"
run_config_upgrader
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
