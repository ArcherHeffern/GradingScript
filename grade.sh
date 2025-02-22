#!/usr/bin/env bash

set -euo pipefail 

# TODO
# - Check if fd is installed
# - Support expected output
# - Cd doesn't check for errors

# Process arguments

INPUT_ZIPFILE="${1-}"
if [[ -z "${INPUT_ZIPFILE}" ]];
then
	echo "Usage: ${0} submissions_zipfile dest_dir"
	exit 1
fi 

if [[ ! -f "${INPUT_ZIPFILE}" ]];
then 
	echo "Error: ${INPUT_ZIPFILE} does not exist"
	exit 1
fi

# Globals: All paths should be relative to this executable
ZIPPED="zipped/"
UNZIPPED="unzipped/"
RESULTS="results/"
TEST_CLASS="Test.java"
PROJECT_CLASSES=("PCB.java ProcessManager.java Queue.java")
EXPECTED_OUTPUT="expected.txt" # Not used
MOODLE_SUBMISSION_EXTENSION="_assignsubmission_file"

if [[ ! -f "${TEST_CLASS}" ]]; 
then
	echo "Error: Test Class does not exist at ${TEST_CLASS}."
	exit 1
fi

# Reset: Remove $ZIPPED, $UNZIPPED, and $RESULTS
rm -rf "${ZIPPED}" "${UNZIPPED}" "${RESULTS}"
mkdir -p "${ZIPPED}" "${UNZIPPED}" "${RESULTS}"

# Post processing of variables - Don't touch!
RESULTS="$(realpath "${RESULTS}")/"
TEST_CLASS_ABS_PATH="$(realpath "${TEST_CLASS}")"

# Unzip all moodle zipfile
unzip "${INPUT_ZIPFILE}" -d "${ZIPPED}" > /dev/null

# Process all submissions
mapfile -t projects < <(fd --full-path -I -e=zip "${MOODLE_SUBMISSION_EXTENSION}" "${ZIPPED}")

for project in "${projects[@]}"; do
	# Unzip submission and place in $ZIPPED
	student="$(basename "${project::-4}")"
	echo "=== Running ${student}'s submission ==="
	dest="${UNZIPPED}${student}"
	if ! unzip -q "${project}" -d "${dest}";
	then
		echo "Failed to unzip ${project}"
		continue
	fi

	# Run submission and write output to $OUTPUT
	cd "${dest}"
	cp "${TEST_CLASS_ABS_PATH}" .
	result_dest="${RESULTS}${student}"
	if ! java "${TEST_CLASS}" "${PROJECT_CLASSES[@]}" &> "${result_dest}";
	then
		echo "Failed to run ${student}'s submission"
	fi
	cd - > /dev/null
done

# Clean up
rm -rf "${ZIPPED}" "${UNZIPPED}" 
