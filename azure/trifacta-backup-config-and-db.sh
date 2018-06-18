#!/bin/bash
##
# Trifacta Inc. Confidential
#
# Copyright 2017 Trifacta Inc.
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
    Trifacta Backup script for configs, job logs & database content

REQUIREMENTS
  - Script must be run as root
  - Trifacta must not be running

OPTIONS:
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

# working directory
DATETIMESTAMP=`date +'%Y%m%d%H%M%S'`
BUILD_VERSION=`cat ${TRIFACTA_HOME}/build_number.txt`
TRIFACTA_BACKUP_BASE_DIR="/opt/trifacta-backups"
BACKUP_DIR_NAME="trifacta-backup-${BUILD_VERSION}-${DATETIMESTAMP}"
WORK_DIR="${TRIFACTA_BACKUP_BASE_DIR}/${BACKUP_DIR_NAME}"
WORK_DIR_FILES="${WORK_DIR}/file-backups"
WORK_DIR_DBS="${WORK_DIR}/db-backups"
BACKUP_ARCHIVE_NAME="${BACKUP_DIR_NAME}.tgz"

# Location of Postgres binaries
export PG_BIN_DIR_CENTOS="/usr/pgsql-9.3/bin"
export PG_BIN_DIR_UBUNTU="/usr/lib/postgresql/9.3/bin"

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

  if [ -e ${TRIFACTA_CONF}/trifacta-conf.json ]; then
    SYSTEMINFO[trifacta_config_found]="true"
  else
    SYSTEMINFO[trifacta_config_found]="false"
  fi

  if [ -e ${LOOKUP_TRICONF_SCRIPT} ]; then
    SYSTEMINFO[trifacta_config_lookup_script_found]="true"
  else
    SYSTEMINFO[trifacta_config_lookup_script_found]="false"
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

  # Check if config available
  if [[ ${SYSTEMINFO[trifacta_config_found]} == "true" ]]; then
    check_pass "check_trifacta_config_found" "trifacta-config.json was found"
  else
    check_fail "check_trifacta_config_found" "trifacta-config.json was not found"
  fi

  # Check if lookup script is available
  if [[ ${SYSTEMINFO[trifacta_config_lookup_script_found]} == "true" ]]; then
    check_pass "check_trifacta_config_lookup_script_found" "trifacta config lookup script was found"
  else
    check_fail "check_trifacta_config_lookup_script_found" "trifacta config lookup script was not found"
  fi

  # Check if Trifacta is Running
  if [[ ${SYSTEMINFO[trifacta_running_status]} == "false" ]]; then
    check_pass "check_trifacta_running_status" "Trifacta is not running"
  else
    check_fail "check_trifacta_running_status" "Trifacta is still running, please stop it and re-run script"
  fi
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

  export PG_DUMP="${PG_BIN_DIR}/pg_dump"
}

function initial_setup_and_confirmation
{

  echo " "
  echo "Workdir Location for this run : ${bold}${WORK_DIR}/${normal}"

  # Create $WORK_DIR
  if [ -e ${WORK_DIR} ]; then
    echo "Removing existing folder, ${WORK_DIR}"
    rm -rf ${WORK_DIR}
  fi

  mkdir -p ${WORK_DIR_FILES}
  mkdir -p ${WORK_DIR_DBS}
  chmod 777 ${WORK_DIR_FILES} ${WORK_DIR_DBS}

  # Unless user chose to not be prompted for confirmation, get their consent before proceeding
  if [[ ${PROMPT_FOR_CONFIRMATION} == "true" ]]; then
    while true
    do
      echo " "
      echo "All prerequisite checks are complete. Next steps are collect & package up Database & Config backups"
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

function backup_version_file
{
  echo "Backup version file"

  cp ${TRIFACTA_HOME}/build_number.txt ${WORK_DIR_FILES}/
  if [ $? -eq 0 ]; then
    check_pass "check_backup_version_file" "Version file backup successful : ${WORK_DIR_FILES}/build_number.txt"
  else
    check_fail "check_backup_version_file" "Version file backup failed"
  fi
}

function backup_dbs
{
  echo "Backup application dbs"

  webapp_db_name=$(${LOOKUP_TRICONF_SCRIPT} "webapp.db.name")
  webapp_db_username=$(${LOOKUP_TRICONF_SCRIPT} "webapp.db.username")
  webapp_db_password=$(${LOOKUP_TRICONF_SCRIPT} "webapp.db.password")
  webapp_db_host=$(${LOOKUP_TRICONF_SCRIPT} "webapp.db.host")
  webapp_db_port=$(${LOOKUP_TRICONF_SCRIPT} "webapp.db.port")
  webapp_db_backup="${WORK_DIR_DBS}/postgres-backup-${webapp_db_name}.sql"

  scheduling_service_db_name=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.name")
  scheduling_service_db_username=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.username")
  scheduling_service_db_password=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.password")
  scheduling_service_db_host=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.host")
  scheduling_service_db_port=$(${LOOKUP_TRICONF_SCRIPT} "scheduling-service.database.port")
  scheduling_service_db_backup="${WORK_DIR_DBS}/postgres-backup-${scheduling_service_db_name}.sql"

  time_based_trigger_service_db_name=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.name")
  time_based_trigger_service_db_username=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.username")
  time_based_trigger_service_db_password=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.password")
  time_based_trigger_service_db_host=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.host")
  time_based_trigger_service_db_port=$(${LOOKUP_TRICONF_SCRIPT} "time-based-trigger-service.database.port")
  time_based_trigger_service_db_backup="${WORK_DIR_DBS}/postgres-backup-${time_based_trigger_service_db_name}.sql"


  PGPASSWORD="${webapp_db_password}" "${PG_DUMP}" --no-password \
    -h ${webapp_db_host} \
    -p ${webapp_db_port} \
    -U ${webapp_db_username} ${webapp_db_name} > ${webapp_db_backup}
  if [ $? -eq 0 ]; then
    check_pass "check_backup_database_webapp" "Database webapp backup successful : ${webapp_db_backup}"
  else
    check_fail "check_backup_database_webapp" "Database webapp backup failed"
  fi

  PGPASSWORD="${scheduling_service_db_password}" "${PG_DUMP}" --no-password \
    -h ${scheduling_service_db_host} \
    -p ${scheduling_service_db_port} \
    -U ${scheduling_service_db_username} ${scheduling_service_db_name} > ${scheduling_service_db_backup}
  if [ $? -eq 0 ]; then
    check_pass "check_backup_database" "Database scheduling_service backup successful : ${scheduling_service_db_backup}"
  else
    check_fail "check_backup_database" "Database scheduling_servicebackup failed"
  fi

  PGPASSWORD="${time_based_trigger_service_db_password}" "${PG_DUMP}" --no-password \
    -h ${time_based_trigger_service_db_host} \
    -p ${time_based_trigger_service_db_port} \
    -U ${time_based_trigger_service_db_username} ${time_based_trigger_service_db_name} > ${time_based_trigger_service_db_backup}
  if [ $? -eq 0 ]; then
    check_pass "check_backup_database" "Database time_based_trigger_service backup successful : ${time_based_trigger_service_db_backup}"
  else
    check_fail "check_backup_database" "Database time_based_trigger_service backup failed"
  fi

}

function backup_configs
{
  echo "Backup trifacta configs"

  cp -R ${TRIFACTA_CONF} ${WORK_DIR_FILES}/
  if [ $? -eq 0 ]; then
    check_pass "check_backup_configs" "Configs backup successful : ${WORK_DIR_FILES}/conf"
  else
    check_fail "check_backup_configs" "Configs backup failed"
  fi
}

function backup_job_logs
{
  echo "Backup trifacta job logs"

  mkdir -p ${WORK_DIR_FILES}/logs

  if [ -d "${TRIFACTA_LOGS_JOBS}" ]; then
    echo "Backing up ${TRIFACTA_LOGS_JOBS}"
    cp -R ${TRIFACTA_LOGS_JOBS} ${WORK_DIR_FILES}/logs/
  else
    echo "No ${TRIFACTA_LOGS_JOBS} found"
    mkdir -p ${WORK_DIR_FILES}/logs/jobs
  fi

  if [ $? -eq 0 ]; then
    check_pass "check_backup_job_logs" "Job Logs backup successful : ${WORK_DIR_FILES}/logs/jobs"
  else
    check_fail "check_backup_job_logs" "Job Logs backup failed"
  fi
}

function backup_jobgroup_logs
{
  echo "Backup trifacta jobgroup logs"

  mkdir -p ${WORK_DIR_FILES}/logs

  if [ -d "${TRIFACTA_LOGS_JOBGROUPS}" ]; then
    echo "Backing up ${TRIFACTA_LOGS_JOBGROUPS}"
    cp -R ${TRIFACTA_LOGS_JOBGROUPS} ${WORK_DIR_FILES}/logs/
  else
    echo "No ${TRIFACTA_LOGS_JOBGROUPS} found"
    mkdir -p ${WORK_DIR_FILES}/logs/jobgroups
  fi

  if [ $? -eq 0 ]; then
    check_pass "check_backup_job_logs" "Jobgroup logs backup successful : ${WORK_DIR_FILES}/logs/jobgroups"
  else
    check_fail "check_backup_job_logs" "Jobgroup logs backup failed"
  fi
}

function archive_backup
{
  echo "Archive backups into tarball"

  pushd ${TRIFACTA_BACKUP_BASE_DIR}
      chown -R trifacta ${BACKUP_DIR_NAME}
    tar czf ${BACKUP_ARCHIVE_NAME} ${BACKUP_DIR_NAME}
  popd
  if [ $? -eq 0 ]; then
    check_pass "check_backup_archive_create" "Backup archive creation successful : ${TRIFACTA_BACKUP_BASE_DIR}/${BACKUP_ARCHIVE_NAME}"
  else
    check_fail "check_backup_archive_create" "Backup archive creation failed"
  fi
}

while getopts "hy" OPTION
do
  case $OPTION in
    h)
      usage
      exit 1
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

echo " "
echo "${bold}======================== Collecting System Info ========================${normal}"
collect_system_info
print_system_info
echo " "
echo "${bold}======================== Performing Requirement Checks ========================${normal}"
check_system_prerequisites
set_platform_specific_postgres_values
echo " "
echo "${bold}======================== Setup ========================${normal}"
initial_setup_and_confirmation
echo " "
echo "${bold}======================== Backup ========================${normal}"
backup_version_file
backup_dbs
backup_configs
backup_job_logs
backup_jobgroup_logs
archive_backup
echo ""
echo "Backup directory : ${TRIFACTA_BACKUP_BASE_DIR}/${BACKUP_DIR_NAME}"
echo "Backup tarball container contents of directory : ${TRIFACTA_BACKUP_BASE_DIR}/${BACKUP_ARCHIVE_NAME}"
echo ""

