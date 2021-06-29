#!/usr/bin/env bash
# Script informed by the collectd monitoring script for smartmontools (using smartctl)
# by Samuel B. <samuel_._behan_(at)_dob_._sk> (c) 2012
# source at: http://devel.dob.sk/collectd-scripts/

# TODO: This probably needs to be a little more complex.  The raw numbers can have more
#       data in them than you'd think.
#       http://arstechnica.com/civis/viewtopic.php?p=22062211

# Formatting done via shfmt -i 2
# https://github.com/mvdan/sh
set -euo pipefail
IFS=$'\n\t'

parse_smartctl_attributes_awk="$(
  cat <<'SMARTCTLAWK'
$1 ~ /^ *[0-9]+$/ && $2 ~ /^[a-zA-Z0-9_-]+$/ {
  gsub(/-/, "_");
  printf "%s_value{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $4
  printf "%s_worst{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $5
  printf "%s_threshold{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $6
  printf "%s_raw_value{%s,smart_id=\"%s\"} %e\n", tolower($2), labels, $1, $10
}
SMARTCTLAWK
)"

parse_smartctl_attributes_awk_nvme="$(
  cat <<'SMARTCTLAWK'
  NF == 2 && $0 ~ /^[A-Za-z ]+:/ {
    print $0
    gsub(/^[ \t]+/, "", $2);
    gsub(/[ \.]+/, "_", $1);
    printf "%s_value{%s} %d\n", tolower($1), labels, $2
  }
SMARTCTLAWK
)"

smartmon_attrs="$(
  cat <<'SMARTMONATTRS'
airflow_temperature_cel
command_timeout
current_pending_sector
end_to_end_error
erase_fail_count
g_sense_error_rate
hardware_ecc_recovered
host_reads_mib
host_reads_32mib
host_writes_mib
host_writes_32mib
load_cycle_count
media_wearout_indicator
wear_leveling_count
nand_writes_1gib
offline_uncorrectable
power_cycle_count
power_cycles
power_on_hours
data_units_read
data_units_written
power_on_hours_and_msec
unsafe_shutdowns
program_fail_count
raw_read_error_rate
reallocated_event_count
reallocated_sector_ct
reported_uncorrect
sata_downshift_count
seek_error_rate
spin_retry_count
spin_up_time
start_stop_count
temperature_case
temperature_celsius
temperature_internal
temperature
total_lbas_read
total_lbas_written
udma_crc_error_count
unsafe_shutdown_count
unsafe_shutdowns
workld_host_reads_perc
workld_media_wear_indic
workload_minutes
SMARTMONATTRS
)"
smartmon_attrs="$(echo ${smartmon_attrs} | xargs | tr ' ' '|')"

parse_smartctl_attributes() {
  local labels="$1" result="$2"
  local vars="$(echo "${smartmon_attrs}" | xargs | tr ' ' '|')"

  if [[ $result == *"NVMe Log"* ]]; then
    echo "$result" |
      awk -F: -v labels="${labels}" "${parse_smartctl_attributes_awk_nvme}" 2>/dev/null |
      grep -E "(${smartmon_attrs})"
  else
    echo "$result" | sed 's/^ \+//g' |
      awk -v labels="${labels}" "${parse_smartctl_attributes_awk}" 2>/dev/null |
      grep -iE "(${smartmon_attrs})"
  fi
}

parse_smartctl_scsi_attributes() {
  local labels="$1"
  while read line; do
    attr_type="$(echo "${line}" | tr '=' ':' | cut -f1 -d: | awk '{$1=$1};1' | tr ' ' '_')"
    attr_value="$(echo "${line}" | tr '=' ':' | cut -f2 -d: | awk '{$1=$1};1')"
    case "${attr_type}" in
    number_of_hours_powered_up_) power_on="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Current_Drive_Temperature | Temperature) temp_cel="$(echo ${attr_value} | cut -f1 -d' ' | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_sent_to_initiator_) lbas_read="$(echo ${attr_value} | awk '{ printf "%e\n", $1 }')" ;;
    Data_Units_Read) lbas_read="$(echo ${attr_value} | cut -d ' ' -f1 | sed 's/,//g' | awk '{$1=$1};1')" ;;
    Blocks_received_from_initiator_) lbas_written="$(echo ${attr_value} | awk '{ printf "%e\n", $1 }')" ;;
    Data_Units_Written) lbas_written="$(echo ${attr_value} | cut -d ' ' -f1 | sed 's/,//g' | awk '{$1=$1};1')" ;;
    Accumulated_start-stop_cycles) power_cycle="$(echo ${attr_value} | awk '{ printf "%e\n", $1 }')" ;;
    Elements_in_grown_defect_list) grown_defects="$(echo ${attr_value} | awk '{ printf "%e\n", $1 }')" ;;
    # For disk life
    Percentage_Used) percentage_used="$(echo ${attr_value} | cut -d ' ' -f1 | sed 's/\%//g')" ;;

    esac
  done
  [ ! -z "$power_on" ] && echo "power_on_hours_raw_value{${labels},smart_id=\"9\"} ${power_on}"
  [ ! -z "$temp_cel" ] && echo "temperature_celsius_raw_value{${labels},smart_id=\"194\"} ${temp_cel}"
  [ ! -z "$lbas_read" ] && echo "total_lbas_read_raw_value{${labels},smart_id=\"242\"} ${lbas_read}"
  [ ! -z "$lbas_written" ] && echo "total_lbas_written_raw_value{${labels},smart_id=\"242\"} ${lbas_written}"
  [ ! -z "$power_cycle" ] && echo "power_cycle_count_raw_value{${labels},smart_id=\"12\"} ${power_cycle}"
  [ ! -z "$grown_defects" ] && echo "grown_defects_count_raw_value{${labels},smart_id=\"12\"} ${grown_defects}"
  [ ! -z "$percentage_used" ] && echo "percentage_used_raw_value{${labels},smart_id=\"9\"} ${percentage_used}"
}

extract_labels_from_smartctl_info() {
  local disk="$1" disk_type="$2"
  local model_family='<None>' device_model='<None>' serial_number='<None>' fw_version='<None>' vendor='<None>' product='<None>' revision='<None>' lun_id='<None>' rotation_rate='<None>'
  while read line; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_' | tr '/' '_')"
    # @see https://unix.stackexchange.com/questions/102008/how-do-i-trim-leading-and-trailing-whitespace-from-each-line-of-some-output
    #info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/\\"/')"
    info_value="$(echo "${line}" | cut -f2- -d: | awk '{$1=$1};1' | tr '\"' ' ')"
    case "${info_type}" in
    Model_Family) model_family="${info_value}" ;;
    Model_Number)
      model_family="${info_value}"
      device_model="${info_value}"
      product="${info_value}"
      ;;
    Device_Model) device_model="${info_value}" ;;
    Serial_Number) serial_number="${info_value}" ;;
    Firmware_Version) fw_version="${info_value}" ;;
    Vendor) vendor="${info_value}" ;;
    PCI_Vendor_Subsystem_ID) vendor="${info_value}" ;;
    Product) product="${info_value}" ;;
    Revision) revision="${info_value}" ;;
    Logical_Unit_id) lun_id="${info_value}" ;;
    Rotation_Rate) rotation_rate="${info_value}" ;;
    esac
  done
  echo "disk=\"${disk}\",type=\"${disk_type}\",vendor=\"${vendor}\",product=\"${product}\",revision=\"${revision}\",lun_id=\"${lun_id}\",model_family=\"${model_family}\",device_model=\"${device_model}\",serial_number=\"${serial_number}\",firmware_version=\"${fw_version}\",rotation_rate=\"${rotation_rate}\""
}

parse_smartctl_info() {
  local -i smart_available=0 smart_enabled=0 smart_healthy=0
  local -i sector_size_log=512 sector_size_phy=512 user_capacity=0
  local labels="$1"
  while read line; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_' | tr '/' '_')"
    # @see https://unix.stackexchange.com/questions/102008/how-do-i-trim-leading-and-trailing-whitespace-from-each-line-of-some-output
    #info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/\\"/')"
    info_value="$(echo "${line}" | cut -f2- -d: | awk '{$1=$1};1')"
    if [[ "${info_type}" == 'SMART_support_is' ]]; then
      case "${info_value:0:7}" in
      Enabled) smart_enabled=1 ;;
      Availab) smart_available=1 ;;
      Unavail) smart_available=0 ;;
      esac
    fi
    if [[ "${info_type}" == 'SMART_overall-health_self-assessment_test_result' ]]; then
      case "${info_value:0:6}" in
      PASSED)
        smart_available=1
        smart_enabled=1
        smart_healthy=1
        ;;
      esac
    elif [[ "${info_type}" == 'SMART_Health_Status' ]]; then
      case "${info_value:0:2}" in
      OK) smart_healthy=1 ;;
      esac
    elif [[ "${info_type}" == 'Sector_Size' ]]; then
      sector_size_log=$(echo "$info_value" | cut -d' ' -f1)
      sector_size_phy=$(echo "$info_value" | cut -d' ' -f1)
    elif [[ "${info_type}" == 'Sector_Sizes' || "${info_type}" == 'Namespace_1_Formatted_LBA_Size' ]]; then
      sector_size_log="$(echo "$info_value" | cut -d' ' -f1)"
      sector_size_phy="$(echo "$info_value" | cut -d' ' -f4)"
    elif [[ "${info_type}" == 'User_Capacity' || "${info_type}" == 'Namespace_1_Size_Capacity' ]]; then
      user_capacity="$(echo "$info_value" | cut -d ' ' -f1 | sed 's/,//g' | awk '{$1=$1};1')"
    fi
  done
  echo "device_smart_available{${labels}} ${smart_available}"
  echo "device_smart_enabled{${labels}} ${smart_enabled}"
  echo "device_smart_healthy{${labels}} ${smart_healthy}"
  echo "device_sector_size_logical{${labels}} ${sector_size_log}"
  echo "device_sector_size_physical{${labels}} ${sector_size_phy}"
  echo "device_user_capacity{${labels}} ${user_capacity}"
}

parse_smartctl_returnvalue() {
  local returnvalue=$1
  local labels=$2

  for ((i = 0; i < 8; i++)); do
    case $i in
    0) echo -n "smartctl_statusbit_commandline_not_parsed{${labels}} " ;;
    1) echo -n "smartctl_statusbit_device_open_failed{${labels}} " ;;
    2) echo -n "smartctl_statusbit_device_command_failed{${labels}} " ;;
    3) echo -n "smartctl_statusbit_disk_failing{${labels}} " ;;
    4) echo -n "smartctl_statusbit_prefail_attributes_below_thresh{${labels}} " ;;
    5) echo -n "smartctl_statusbit_disk_ok_previous_prefail_attributes{${labels}} " ;;
    6) echo -n "smartctl_statusbit_device_error_log_has_errors{${labels}} " ;;
    7) echo -n "smartctl_statusbit_device_selftest_log_has_errors{${labels}} " ;;
    esac
    echo "$((status & 2 ** i && 1))"
  done
}

output_format_awk="$(
  cat <<'OUTPUTAWK'
BEGIN { v = "" }
v != $1 {
  print "# HELP smartmon_" $1 " SMART metric " $1;
  print "# TYPE smartmon_" $1 " gauge";
  v = $1
}
{print "smartmon_" $0}
OUTPUTAWK
)"

format_output() {
  sort |
    awk -F'{' "${output_format_awk}"
}

smartctl_version="$(smartctl -V | head -n1 | awk '$1 == "smartctl" {print $2}')"

echo "smartctl_version{version=\"${smartctl_version}\"} 1" | format_output
if [[ "$(expr "${smartctl_version}" : '\([0-9]*\)\..*')" -lt 6 ]]; then
  exit
fi

## Start to scaning and checking devices
device_list="$(smartctl --scan-open | awk '/^\/dev/{print $1 "|" $3}')"

## Merge extra devices
merge_devices() {
  for device in $@; do
    local exists=0
    for d in ${device_list}; do
      d="$(echo ${d} | cut -f1 -d'|')"
      if [ ${device} = ${d} ]; then
        exists=1
      fi
    done

    # add none exists disk
    if [ $exists -eq 0 ]; then
      device_list+=("${device}|auto")
    fi
  done
}

case $(uname -s | tr '[:upper:]' '[:lower:]') in
'darwin')
  merge_devices $(diskutil list | grep 'internal, physical' | awk '{print $1}')
  ;;
'linux')
  merge_devices $(lsblk -p | grep disk | awk '{print $1}')
  ;;
'freebsd')
  merge_devices $(geom disk list | grep 'Name: ' | awk '{print $3}' | sed 's/^/\/dev\//')
  ;;
esac

for device in ${device_list[@]}; do
  disk="$(echo ${device} | cut -f1 -d'|')"
  type="$(echo ${device} | cut -f2 -d'|')"

  active=1
  echo "smartctl_run{disk=\"${disk}\",type=\"${type}\"}" "$(TZ=UTC date '+%s')"

  # Check if the device is in a low-power mode
  smartctl -n standby -d "${type}" "${disk}" >/dev/null || active=0
  echo "device_active{disk=\"${disk}\",type=\"${type}\"}" "${active}"

  # Skip further metrics to prevent the disk from spinning up
  test ${active} -eq 0 && continue

  # Get the SMART information and health,
  # Allow non-zero exit code and store it
  set +e
  smart_info="$(smartctl -i -H -d "${type}" "${disk}")"
  status=$?
  set -e

  disk_labels="$(echo "$smart_info" | extract_labels_from_smartctl_info "${disk}" "${type}")"
  echo "$smart_info" | parse_smartctl_info "${disk_labels}"

  # Parse out smartctl's exit code into separate metrics
  parse_smartctl_returnvalue $status "${disk_labels}"

  # Get the SMART attributes
  case ${type} in
  atacam | usbjmicron | sat | auto | nvme)
    parse_smartctl_attributes "${disk_labels}" "$(smartctl -A -d ${type} ${disk})"
    ;;
  sat+megaraid*)
    parse_smartctl_attributes "${disk_labels}" "$(smartctl -A -d ${type} ${disk})"
    ;;
  scsi) smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk_labels}" || true ;;
  megaraid*) smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk_labels}" || true ;;
  *)
    echo "disk type is not sat, scsi or megaraid but ${type}"
    exit
    ;;
  esac
done | format_output